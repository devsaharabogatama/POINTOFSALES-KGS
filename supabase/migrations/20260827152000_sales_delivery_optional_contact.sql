-- Require only recipient name for Delivery; phone and address remain immutable optional snapshots.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827151000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260827151000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827152000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827152000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_delivery_documents
    WHERE COALESCE(btrim(recipient_name),'')='') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: blank Delivery recipient name';
  END IF;
END
$guard$;

ALTER TABLE public.sales_headers
  DROP CONSTRAINT sales_headers_fulfillment_shape_check,
  ADD CONSTRAINT sales_headers_fulfillment_shape_check CHECK(
    (fulfillment_mode='PICKUP' AND NOT sj_required
      AND delivery_recipient_name IS NULL
      AND delivery_recipient_phone IS NULL
      AND delivery_address IS NULL
      AND delivery_scheduled_at IS NULL
      AND delivery_notes IS NULL)
    OR
    (fulfillment_mode='DELIVERY' AND sj_required
      AND (document_status<>'POSTED'
        OR COALESCE(btrim(delivery_recipient_name),'')<>''))
  );

ALTER TABLE public.sales_delivery_documents
  DROP CONSTRAINT sales_delivery_document_identity_check,
  ALTER COLUMN recipient_phone DROP NOT NULL,
  ALTER COLUMN delivery_address DROP NOT NULL,
  ADD CONSTRAINT sales_delivery_document_identity_check CHECK(
    btrim(delivery_no)<>''
    AND btrim(recipient_name)<>''
    AND jsonb_typeof(snapshot_payload)='object'
  );

CREATE OR REPLACE FUNCTION private.require_delivery_recipient_name(p_name TEXT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE v_name TEXT:=NULLIF(btrim(p_name),'');
BEGIN
  IF v_name IS NULL THEN RAISE EXCEPTION 'DELIVERY_RECIPIENT_REQUIRED'; END IF;
  RETURN v_name;
END
$$;

CREATE OR REPLACE FUNCTION private.ensure_sales_documents(
  p_company_id UUID,p_sales_id UUID,p_provenance TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_sale public.sales_headers%ROWTYPE;v_invoice_id UUID;v_delivery_id UUID;
  v_delivery_no TEXT;v_payload JSONB;v_branding public.company_branding_profiles%ROWTYPE;
  v_recipient_name TEXT;
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
  IF v_sale.fulfillment_mode='PICKUP' THEN
    IF EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=p_company_id AND delivery.sales_id=p_sales_id) THEN
      RAISE EXCEPTION 'PICKUP_SALE_HAS_DELIVERY_DOCUMENT';
    END IF;
    RETURN;
  END IF;
  v_recipient_name:=private.require_delivery_recipient_name(
    v_sale.delivery_recipient_name);
  SELECT delivery.id,delivery.delivery_no INTO v_delivery_id,v_delivery_no
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=p_company_id AND delivery.sales_id=p_sales_id;
  IF v_delivery_id IS NULL THEN
    v_delivery_no:=private.next_sales_delivery_no(
      p_company_id,COALESCE(v_sale.posted_at,clock_timestamp()));
    INSERT INTO public.sales_delivery_documents(company_id,delivery_no,sales_id,
      invoice_snapshot_id,store_id,warehouse_id,customer_id,recipient_name,
      recipient_phone,delivery_address,scheduled_at,delivery_notes,status,
      snapshot_payload,branding_logo_object_path,created_by,created_at)
    VALUES(p_company_id,v_delivery_no,p_sales_id,v_invoice_id,v_sale.store_id,
      v_sale.sales_warehouse_id,v_sale.customer_id,v_recipient_name,
      NULLIF(btrim(v_sale.delivery_recipient_phone),''),
      NULLIF(btrim(v_sale.delivery_address),''),v_sale.delivery_scheduled_at,
      NULLIF(btrim(v_sale.delivery_notes),''),'READY',jsonb_build_object(
        'snapshotVersion',1,'deliveryNo',v_delivery_no,'invoiceNo',v_sale.invoice_no,
        'saleId',p_sales_id,'company',v_payload->'company',
        'branding',v_payload->'branding','store',v_payload->'store',
        'warehouse',v_payload->'warehouse','customer',v_payload->'customer',
        'recipient',jsonb_build_object('name',v_recipient_name,
          'phone',NULLIF(btrim(v_sale.delivery_recipient_phone),''),
          'address',NULLIF(btrim(v_sale.delivery_address),'')),
        'scheduledAt',v_sale.delivery_scheduled_at,
        'notes',NULLIF(btrim(v_sale.delivery_notes),''),'lines',(
          SELECT jsonb_agg(jsonb_build_object('sku',line.product_sku_snapshot,
            'productName',line.product_name_snapshot,
            'uomName',line.sale_uom_name_snapshot,'quantity',line.qty)
            ORDER BY line.id) FROM public.sales_details line
          WHERE line.company_id=p_company_id AND line.sales_id=p_sales_id)),
      v_branding.logo_object_path,v_sale.posted_by,
      COALESCE(v_sale.posted_at,clock_timestamp())) RETURNING id INTO v_delivery_id;
    INSERT INTO public.sales_delivery_lines(company_id,delivery_document_id,
      sales_detail_id,line_no,product_id,product_sku_snapshot,product_name_snapshot,
      sale_uom_id,sale_uom_name_snapshot,quantity_uom,factor_to_base_snapshot,
      quantity_base)
    SELECT line.company_id,v_delivery_id,line.id,
      (row_number() OVER(ORDER BY line.id))::INTEGER,line.product_id,
      line.product_sku_snapshot,line.product_name_snapshot,line.sale_uom_id,
      line.sale_uom_name_snapshot,line.qty,line.uom_factor_to_base_snapshot,
      line.quantity_base FROM public.sales_details line
    WHERE line.company_id=p_company_id AND line.sales_id=p_sales_id;
    INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
      sales_id,action,actor_id,before_state,after_state,created_at)
    VALUES(p_company_id,'SALES_DELIVERY',v_delivery_id,p_sales_id,'CREATE',
      v_sale.posted_by,NULL,jsonb_build_object('deliveryNo',v_delivery_no,
        'status','READY'),COALESCE(v_sale.posted_at,clock_timestamp()));
  END IF;
  IF v_sale.sj_no IS DISTINCT FROM v_delivery_no
     OR v_sale.sj_status<>'PENDING'::public.sj_status THEN
    UPDATE public.sales_headers SET sj_required=TRUE,sj_no=v_delivery_no,
      sj_status='PENDING'::public.sj_status
    WHERE company_id=p_company_id AND id=p_sales_id;
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.configure_pos_sale_fulfillment(
  p_sales_id UUID,p_master_version BIGINT,p_fulfillment_mode TEXT,
  p_recipient_name TEXT,p_recipient_phone TEXT,p_delivery_address TEXT,
  p_scheduled_at TIMESTAMPTZ,p_notes TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_sale public.sales_headers%ROWTYPE;
  v_mode TEXT:=upper(btrim(COALESCE(p_fulfillment_mode,'')));
  v_name TEXT;v_phone TEXT;v_address TEXT;v_new_version BIGINT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
  IF v_sale.document_status<>'DRAFT' THEN RAISE EXCEPTION 'SALE_DRAFT_REQUIRED'; END IF;
  IF v_sale.master_version<>p_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
    OR v_sale.edit_lock_session_id IS DISTINCT FROM v_sale.session_id
    OR v_sale.edit_lock_heartbeat_at IS NULL
    OR v_sale.edit_lock_heartbeat_at<clock_timestamp()-interval '5 minutes' THEN
    RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
  END IF;
  IF v_mode NOT IN('PICKUP','DELIVERY') THEN RAISE EXCEPTION 'INVALID_FULFILLMENT_MODE'; END IF;
  IF v_mode='DELIVERY' THEN
    v_name:=private.require_delivery_recipient_name(p_recipient_name);
    v_phone:=NULLIF(btrim(p_recipient_phone),'');
    v_address:=NULLIF(btrim(p_delivery_address),'');
  END IF;
  v_new_version:=v_sale.master_version+1;
  UPDATE public.sales_headers SET fulfillment_mode=v_mode,
    sj_required=v_mode='DELIVERY',delivery_recipient_name=v_name,
    delivery_recipient_phone=v_phone,delivery_address=v_address,
    delivery_scheduled_at=CASE WHEN v_mode='DELIVERY' THEN p_scheduled_at END,
    delivery_notes=CASE WHEN v_mode='DELIVERY' THEN NULLIF(btrim(p_notes),'') END,
    payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)||jsonb_build_object(
      'fulfillmentMode',v_mode,'deliveryRecipientName',v_name,
      'deliveryRecipientPhone',v_phone,'deliveryAddress',v_address,
      'deliveryScheduledAt',CASE WHEN v_mode='DELIVERY' THEN p_scheduled_at END,
      'deliveryNotes',CASE WHEN v_mode='DELIVERY' THEN NULLIF(btrim(p_notes),'') END),
    master_version=v_new_version,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=p_sales_id;
  INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
    sales_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'SALE',p_sales_id,p_sales_id,'CONFIGURE_FULFILLMENT',v_actor,
    jsonb_build_object('fulfillmentMode',v_sale.fulfillment_mode,
      'masterVersion',v_sale.master_version),jsonb_build_object(
      'fulfillmentMode',v_mode,'masterVersion',v_new_version));
  RETURN jsonb_build_object('salesId',p_sales_id,'fulfillmentMode',v_mode,
    'masterVersion',v_new_version);
END
$$;

REVOKE ALL ON FUNCTION private.require_delivery_recipient_name(TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.require_delivery_recipient_name(TEXT)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827152000','sales_delivery_optional_contact',
  'Requires only recipient name for Delivery while preserving optional phone and address as immutable transaction and Surat Jalan snapshots');
NOTIFY pgrst,'reload schema';
COMMIT;
