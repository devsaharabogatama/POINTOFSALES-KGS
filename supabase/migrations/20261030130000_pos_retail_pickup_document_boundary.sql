BEGIN;

DO $guard$
DECLARE v_definition text;v_company uuid;v_sale public.sales_headers%rowtype;
  v_policy text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261030130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261030130000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260827153000','20260910153000','20261030120000'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger';
  END IF;
  IF to_regprocedure('private.ensure_sales_documents(uuid,uuid,text)') IS NULL
    OR to_regprocedure('private.sales_delivery_document_required(text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Document runtime';
  END IF;
  SELECT pg_get_functiondef(
    'private.ensure_sales_documents(uuid,uuid,text)'::regprocedure)
    INTO v_definition;
  IF v_definition NOT LIKE '%delivery_document_creation_policy%'
    OR v_definition NOT LIKE '%private.sales_delivery_document_required(%'
    OR v_definition NOT LIKE '%v_delivery_id IS NOT NULL%'
    OR v_definition !~ 'v_sale[.]fulfillment_mode[[:space:]]*=[[:space:]]*''DELIVERY'''
    OR v_definition LIKE '%POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Document definition drift';
  END IF;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE company.company_code='KGS' AND company.status='ACTIVE'
    AND setting.active_mode='RETAIL_CONFIRM_INVOICE';
  SELECT COALESCE(branding.delivery_document_creation_policy,'DELIVERY_ONLY')
    INTO v_policy FROM public.company_branding_profiles branding
    WHERE branding.company_id=v_company;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.draft_no='DRF-20261030-000455';
  IF v_policy<>'ALL_POSTED_SALES' OR v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED')
    OR v_sale.sales_origin<>'POS'
    OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
    OR v_sale.fulfillment_mode<>'PICKUP' OR v_sale.sj_required THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact conflict changed';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.ensure_sales_documents(
  p_company_id uuid,p_sales_id uuid,p_provenance text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_sale public.sales_headers%rowtype;v_invoice_id uuid;v_delivery_id uuid;
  v_delivery_no text;v_delivery_status text;v_payload jsonb;
  v_branding public.company_branding_profiles%rowtype;
  v_creation_policy text;v_create_delivery boolean;v_recipient_name text;
  v_recipient_phone text;v_delivery_address text;v_scheduled_at timestamptz;
  v_delivery_notes text;v_header_sj_status public.sj_status;
  v_pos_retail_pickup boolean;
  v_boundary_marker constant text:='POS_RETAIL_PICKUP_DOCUMENT_BOUNDARY';
BEGIN
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
  IF NOT FOUND OR v_sale.document_status<>'POSTED' THEN RETURN; END IF;
  IF p_provenance NOT IN('LIVE_POST','LEGACY_CUTOVER') THEN
    RAISE EXCEPTION 'INVALID_SALES_DOCUMENT_PROVENANCE';
  END IF;
  v_payload:=private.build_sales_invoice_snapshot(p_company_id,p_sales_id,p_provenance);
  IF v_payload IS NULL THEN RAISE EXCEPTION 'SALES_INVOICE_SNAPSHOT_SOURCE_INCOMPLETE'; END IF;
  SELECT branding.* INTO v_branding FROM public.company_branding_profiles branding
  WHERE branding.company_id=p_company_id;
  v_creation_policy:=COALESCE(v_branding.delivery_document_creation_policy,'DELIVERY_ONLY');
  v_pos_retail_pickup:=v_sale.sales_origin='POS'
    AND v_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND v_sale.fulfillment_mode='PICKUP';
  INSERT INTO public.sales_invoice_snapshots(company_id,sales_id,invoice_no,
    snapshot_version,snapshot_provenance,snapshot_payload,branding_logo_object_path,
    branding_logo_version,branding_logo_checksum_sha256,created_by,created_at)
  VALUES(p_company_id,p_sales_id,v_sale.invoice_no,1,p_provenance,v_payload,
    v_branding.logo_object_path,v_branding.logo_version,
    v_branding.logo_checksum_sha256,v_sale.posted_by,
    COALESCE(v_sale.posted_at,clock_timestamp()))
  ON CONFLICT(company_id,sales_id) DO NOTHING RETURNING id INTO v_invoice_id;
  IF v_invoice_id IS NOT NULL THEN
    INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
      sales_id,action,actor_id,before_state,after_state,created_at)
    VALUES(p_company_id,'SALES_INVOICE',v_invoice_id,p_sales_id,'CREATE',
      v_sale.posted_by,NULL,jsonb_build_object('invoiceNo',v_sale.invoice_no,
        'provenance',p_provenance),COALESCE(v_sale.posted_at,clock_timestamp()));
  ELSE
    SELECT invoice.id INTO STRICT v_invoice_id FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=p_company_id AND invoice.sales_id=p_sales_id;
  END IF;
  SELECT delivery.id,delivery.delivery_no,delivery.status
  INTO v_delivery_id,v_delivery_no,v_delivery_status
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=p_company_id AND delivery.sales_id=p_sales_id;
  v_create_delivery:=v_delivery_id IS NOT NULL OR v_sale.fulfillment_mode='DELIVERY'
    OR (p_provenance='LIVE_POST' AND NOT v_pos_retail_pickup
      AND private.sales_delivery_document_required(
        v_sale.fulfillment_mode,v_creation_policy));
  IF NOT v_create_delivery THEN RETURN; END IF;
  IF v_sale.fulfillment_mode='DELIVERY' THEN
    v_recipient_name:=private.require_delivery_recipient_name(v_sale.delivery_recipient_name);
    v_recipient_phone:=NULLIF(btrim(v_sale.delivery_recipient_phone),'');
    v_delivery_address:=NULLIF(btrim(v_sale.delivery_address),'');
    v_scheduled_at:=v_sale.delivery_scheduled_at;
    v_delivery_notes:=NULLIF(btrim(v_sale.delivery_notes),'');
  ELSE
    v_recipient_name:=COALESCE(NULLIF(btrim(v_payload#>>'{customer,name}'),''),'Pelanggan Umum');
    v_recipient_phone:=NULLIF(btrim(v_payload#>>'{customer,phone}'),'');
    v_delivery_address:=NULLIF(btrim(v_payload#>>'{customer,address}'),'');
  END IF;
  IF v_delivery_id IS NULL THEN
    v_delivery_no:=private.next_sales_delivery_no(
      p_company_id,COALESCE(v_sale.posted_at,clock_timestamp()));
    INSERT INTO public.sales_delivery_documents(company_id,delivery_no,sales_id,
      invoice_snapshot_id,store_id,warehouse_id,customer_id,recipient_name,
      recipient_phone,delivery_address,scheduled_at,delivery_notes,status,
      snapshot_payload,branding_logo_object_path,created_by,created_at,fulfillment_mode)
    VALUES(p_company_id,v_delivery_no,p_sales_id,v_invoice_id,v_sale.store_id,
      v_sale.sales_warehouse_id,v_sale.customer_id,v_recipient_name,
      v_recipient_phone,v_delivery_address,v_scheduled_at,v_delivery_notes,'READY',
      jsonb_build_object('snapshotVersion',1,'deliveryNo',v_delivery_no,
        'invoiceNo',v_sale.invoice_no,'saleId',p_sales_id,
        'fulfillmentMode',v_sale.fulfillment_mode,
        'deliveryDocumentCreationPolicy',v_creation_policy,
        'company',v_payload->'company','branding',v_payload->'branding',
        'store',v_payload->'store','warehouse',v_payload->'warehouse',
        'customer',v_payload->'customer','recipient',jsonb_build_object(
          'name',v_recipient_name,'phone',v_recipient_phone,'address',v_delivery_address),
        'scheduledAt',v_scheduled_at,'notes',v_delivery_notes,'lines',(
          SELECT jsonb_agg(jsonb_build_object('sku',line.product_sku_snapshot,
            'productName',line.product_name_snapshot,
            'uomName',line.sale_uom_name_snapshot,'quantity',line.qty)
            ORDER BY line.id) FROM public.sales_details line
          WHERE line.company_id=p_company_id AND line.sales_id=p_sales_id)),
      v_branding.logo_object_path,v_sale.posted_by,
      COALESCE(v_sale.posted_at,clock_timestamp()),v_sale.fulfillment_mode)
    RETURNING id,status INTO v_delivery_id,v_delivery_status;
    INSERT INTO public.sales_delivery_lines(company_id,delivery_document_id,
      sales_detail_id,line_no,product_id,product_sku_snapshot,product_name_snapshot,
      sale_uom_id,sale_uom_name_snapshot,quantity_uom,factor_to_base_snapshot,
      quantity_base)
    SELECT line.company_id,v_delivery_id,line.id,
      (row_number() OVER(ORDER BY line.id))::integer,line.product_id,
      line.product_sku_snapshot,line.product_name_snapshot,line.sale_uom_id,
      line.sale_uom_name_snapshot,line.qty,line.uom_factor_to_base_snapshot,
      line.quantity_base FROM public.sales_details line
    WHERE line.company_id=p_company_id AND line.sales_id=p_sales_id;
    INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
      sales_id,action,actor_id,before_state,after_state,created_at)
    VALUES(p_company_id,'SALES_DELIVERY',v_delivery_id,p_sales_id,'CREATE',
      v_sale.posted_by,NULL,jsonb_build_object('deliveryNo',v_delivery_no,
        'status','READY','fulfillmentMode',v_sale.fulfillment_mode),
      COALESCE(v_sale.posted_at,clock_timestamp()));
  END IF;
  v_header_sj_status:=CASE
    WHEN v_delivery_status IN('DISPATCHED','DELIVERED')
      THEN 'SHIPPED'::public.sj_status
    WHEN v_delivery_status='CANCELED' THEN 'NONE'::public.sj_status
    ELSE 'PENDING'::public.sj_status
  END;
  IF v_sale.sj_no IS DISTINCT FROM v_delivery_no OR NOT v_sale.sj_required
    OR v_sale.sj_status IS DISTINCT FROM v_header_sj_status THEN
    UPDATE public.sales_headers SET sj_required=TRUE,sj_no=v_delivery_no,
      sj_status=v_header_sj_status
    WHERE company_id=p_company_id AND id=p_sales_id;
  END IF;
END
$$;

COMMENT ON FUNCTION private.ensure_sales_documents(uuid,uuid,text) IS
  'Creates immutable Invoice documents for Posted Sales. Automatic Delivery Document policy excludes new direct POS Retail Pickup, while Delivery, Backoffice, adopted cutover and existing Delivery Documents retain their prior behavior.';

REVOKE ALL ON FUNCTION private.ensure_sales_documents(uuid,uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.ensure_sales_documents(uuid,uuid,text)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261030130000','pos_retail_pickup_document_boundary',
  'Exclude new direct POS Retail Pickup from automatic Delivery Document creation while preserving Invoice, Delivery, Backoffice, adopted cutover and existing document behavior');

COMMIT;
