-- Optional Company policy to create a Surat Jalan for every newly posted Sale.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827152000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260827152000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827153000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827153000';
  END IF;
  IF to_regprocedure('private.ensure_sales_documents(uuid,uuid,text)') IS NULL
    OR to_regprocedure('private.acp5e_update_sales_delivery_status_core(uuid,bigint,text,text)') IS NULL
    OR to_regprocedure('public.get_inventory_delivery_documents(date,date)') IS NULL
    OR to_regprocedure('public.save_company_document_visibility(bigint,boolean,boolean,boolean,text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Sales Document runtime missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
    JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
      AND sale.id=delivery.sales_id
    WHERE sale.fulfillment_mode<>'DELIVERY') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected Pickup delivery history';
  END IF;
END
$guard$;

ALTER TABLE public.company_branding_profiles
  ADD COLUMN delivery_document_creation_policy TEXT NOT NULL
    DEFAULT 'DELIVERY_ONLY',
  ADD CONSTRAINT company_branding_delivery_document_policy_check
    CHECK(delivery_document_creation_policy IN('DELIVERY_ONLY','ALL_POSTED_SALES'));

ALTER TABLE public.sales_delivery_documents
  ADD COLUMN fulfillment_mode TEXT NOT NULL DEFAULT 'DELIVERY',
  ADD CONSTRAINT sales_delivery_document_fulfillment_mode_check
    CHECK(fulfillment_mode IN('PICKUP','DELIVERY')),
  DROP CONSTRAINT sales_delivery_document_lifecycle_check,
  ADD CONSTRAINT sales_delivery_document_lifecycle_check CHECK(
    (status='READY' AND dispatched_at IS NULL AND dispatched_by IS NULL
      AND delivered_at IS NULL AND delivered_by IS NULL
      AND canceled_at IS NULL AND canceled_by IS NULL)
    OR (status='DISPATCHED' AND fulfillment_mode='DELIVERY'
      AND dispatched_at IS NOT NULL AND dispatched_by IS NOT NULL
      AND delivered_at IS NULL AND delivered_by IS NULL
      AND canceled_at IS NULL AND canceled_by IS NULL)
    OR (status='DELIVERED' AND delivered_at IS NOT NULL
      AND delivered_by IS NOT NULL AND canceled_at IS NULL AND canceled_by IS NULL
      AND ((fulfillment_mode='DELIVERY' AND dispatched_at IS NOT NULL
          AND dispatched_by IS NOT NULL)
        OR (fulfillment_mode='PICKUP' AND dispatched_at IS NULL
          AND dispatched_by IS NULL)))
    OR (status='CANCELED' AND dispatched_at IS NULL AND dispatched_by IS NULL
      AND delivered_at IS NULL AND delivered_by IS NULL
      AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
      AND COALESCE(btrim(cancel_reason),'')<>'')
  );

ALTER TABLE public.sales_headers
  DROP CONSTRAINT sales_headers_fulfillment_shape_check,
  ADD CONSTRAINT sales_headers_fulfillment_shape_check CHECK(
    (fulfillment_mode='PICKUP'
      AND delivery_recipient_name IS NULL
      AND delivery_recipient_phone IS NULL
      AND delivery_address IS NULL
      AND delivery_scheduled_at IS NULL
      AND delivery_notes IS NULL
      AND (NOT sj_required OR document_status='POSTED'))
    OR (fulfillment_mode='DELIVERY' AND sj_required
      AND (document_status<>'POSTED'
        OR COALESCE(btrim(delivery_recipient_name),'')<>''))
  );

CREATE FUNCTION private.sales_delivery_document_required(
  p_fulfillment_mode TEXT,p_creation_policy TEXT
) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE
SET search_path=public,pg_temp AS $$
  SELECT upper(btrim(COALESCE(p_fulfillment_mode,'')))='DELIVERY'
    OR upper(btrim(COALESCE(p_creation_policy,'DELIVERY_ONLY')))='ALL_POSTED_SALES'
$$;

CREATE FUNCTION private.sales_delivery_transition_target(
  p_current_status TEXT,p_fulfillment_mode TEXT,p_action TEXT,p_reason TEXT
) RETURNS TEXT LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE v_current TEXT:=upper(btrim(COALESCE(p_current_status,'')));
  v_mode TEXT:=upper(btrim(COALESCE(p_fulfillment_mode,'')));
  v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
BEGIN
  IF v_action='DISPATCH' AND v_current='READY' AND v_mode='DELIVERY' THEN
    RETURN 'DISPATCHED';
  ELSIF v_action='DELIVER' AND v_current='DISPATCHED' AND v_mode='DELIVERY' THEN
    RETURN 'DELIVERED';
  ELSIF v_action='DELIVER' AND v_current='READY' AND v_mode='PICKUP' THEN
    RETURN 'DELIVERED';
  ELSIF v_action='CANCEL' AND v_current='READY'
    AND COALESCE(btrim(p_reason),'')<>'' THEN
    RETURN 'CANCELED';
  END IF;
  RAISE EXCEPTION 'INVALID_SALES_DELIVERY_TRANSITION';
END
$$;

CREATE FUNCTION private.trg_sld_validate_delivery_fulfillment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_source_mode TEXT;
BEGIN
  SELECT sale.fulfillment_mode INTO v_source_mode FROM public.sales_headers sale
  WHERE sale.company_id=NEW.company_id AND sale.id=NEW.sales_id;
  IF v_source_mode IS NULL OR NEW.fulfillment_mode<>v_source_mode
    OR COALESCE(NEW.snapshot_payload->>'fulfillmentMode','')<>v_source_mode THEN
    RAISE EXCEPTION 'SALES_DELIVERY_FULFILLMENT_SNAPSHOT_MISMATCH';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_sld_validate_delivery_fulfillment
BEFORE INSERT ON public.sales_delivery_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_validate_delivery_fulfillment();

CREATE OR REPLACE FUNCTION public.get_company_branding()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_profile public.company_branding_profiles%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT public.private_user_has_company_access(v_company) THEN
    RAISE EXCEPTION 'COMPANY_ACCESS_DENIED';
  END IF;
  SELECT profile.* INTO v_profile FROM public.company_branding_profiles profile
  WHERE profile.company_id=v_company;
  IF NOT FOUND THEN RETURN jsonb_build_object(
    'companyId',v_company,'hasLogo',FALSE,'showLogoOnDocuments',TRUE,
    'showStampOnDocuments',FALSE,'showBankAccountOnInvoice',FALSE,
    'invoiceDateDisplayMode','ORDER_DATE','deliverySignatureTemplate','WAREHOUSE',
    'deliveryDocumentCreationPolicy','DELIVERY_ONLY',
    'logoVersion',0,'masterVersion',NULL
  ); END IF;
  RETURN jsonb_build_object(
    'companyId',v_company,'hasLogo',v_profile.logo_object_path IS NOT NULL,
    'showLogoOnDocuments',v_profile.show_logo_on_documents,
    'showStampOnDocuments',v_profile.show_stamp_on_documents,
    'showBankAccountOnInvoice',v_profile.show_bank_account_on_invoice,
    'invoiceDateDisplayMode',v_profile.invoice_date_display_mode,
    'deliverySignatureTemplate',v_profile.delivery_signature_template,
    'deliveryDocumentCreationPolicy',v_profile.delivery_document_creation_policy,
    'logoObjectPath',v_profile.logo_object_path,'logoPublicUrl',v_profile.logo_public_url,
    'logoMimeType',v_profile.logo_mime_type,'logoSizeBytes',v_profile.logo_size_bytes,
    'logoChecksumSha256',v_profile.logo_checksum_sha256,
    'logoVersion',v_profile.logo_version,'masterVersion',v_profile.master_version,
    'uploadedAt',v_profile.uploaded_at,'updatedAt',v_profile.updated_at
  );
END
$$;

CREATE FUNCTION public.save_company_document_visibility(
  p_expected_master_version BIGINT,p_show_logo_on_documents BOOLEAN,
  p_show_stamp_on_documents BOOLEAN,p_show_bank_account_on_invoice BOOLEAN,
  p_invoice_date_display_mode TEXT,p_delivery_signature_template TEXT,
  p_delivery_document_creation_policy TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_existing public.company_branding_profiles%ROWTYPE;v_before JSONB;v_after JSONB;
  v_date_mode TEXT:=upper(btrim(COALESCE(p_invoice_date_display_mode,'')));
  v_delivery_template TEXT:=upper(btrim(COALESCE(p_delivery_signature_template,'')));
  v_creation_policy TEXT:=upper(btrim(COALESCE(p_delivery_document_creation_policy,'')));
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_show_logo_on_documents IS NULL OR p_show_stamp_on_documents IS NULL
     OR p_show_bank_account_on_invoice IS NULL THEN
    RAISE EXCEPTION 'COMPANY_DOCUMENT_VISIBILITY_REQUIRED';
  END IF;
  IF v_date_mode NOT IN('ORDER_DATE','POSTED_DATE') THEN
    RAISE EXCEPTION 'INVOICE_DATE_DISPLAY_MODE_INVALID';
  END IF;
  IF v_delivery_template NOT IN('WAREHOUSE','STORE') THEN
    RAISE EXCEPTION 'DELIVERY_SIGNATURE_TEMPLATE_INVALID';
  END IF;
  IF v_creation_policy NOT IN('DELIVERY_ONLY','ALL_POSTED_SALES') THEN
    RAISE EXCEPTION 'DELIVERY_DOCUMENT_CREATION_POLICY_INVALID';
  END IF;
  IF NOT public.private_user_has_any_company_or_store_role(
    v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
  ) THEN RAISE EXCEPTION 'COMPANY_BRANDING_MANAGER_REQUIRED'; END IF;
  IF p_show_bank_account_on_invoice AND NOT EXISTS(SELECT 1 FROM public.companies company
    WHERE company.id=v_company AND NULLIF(btrim(company.bank_name),'') IS NOT NULL
      AND NULLIF(btrim(company.bank_account_number),'') IS NOT NULL
      AND NULLIF(btrim(company.bank_account_holder),'') IS NOT NULL) THEN
    RAISE EXCEPTION 'COMPANY_BANK_ACCOUNT_REQUIRED';
  END IF;
  SELECT profile.* INTO v_existing FROM public.company_branding_profiles profile
  WHERE profile.company_id=v_company FOR UPDATE;
  IF NOT FOUND THEN
    IF p_expected_master_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    INSERT INTO public.company_branding_profiles(company_id,show_logo_on_documents,
      show_stamp_on_documents,show_bank_account_on_invoice,invoice_date_display_mode,
      delivery_signature_template,delivery_document_creation_policy,updated_by,updated_at)
    VALUES(v_company,p_show_logo_on_documents,p_show_stamp_on_documents,
      p_show_bank_account_on_invoice,v_date_mode,v_delivery_template,
      v_creation_policy,v_actor,clock_timestamp());
  ELSE
    IF v_existing.show_logo_on_documents=p_show_logo_on_documents
      AND v_existing.show_stamp_on_documents=p_show_stamp_on_documents
      AND v_existing.show_bank_account_on_invoice=p_show_bank_account_on_invoice
      AND v_existing.invoice_date_display_mode=v_date_mode
      AND v_existing.delivery_signature_template=v_delivery_template
      AND v_existing.delivery_document_creation_policy=v_creation_policy THEN
      RETURN public.get_company_branding();
    END IF;
    IF p_expected_master_version IS NULL
      OR p_expected_master_version<>v_existing.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_existing);
    UPDATE public.company_branding_profiles SET
      show_logo_on_documents=p_show_logo_on_documents,
      show_stamp_on_documents=p_show_stamp_on_documents,
      show_bank_account_on_invoice=p_show_bank_account_on_invoice,
      invoice_date_display_mode=v_date_mode,
      delivery_signature_template=v_delivery_template,
      delivery_document_creation_policy=v_creation_policy,
      master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company;
  END IF;
  SELECT to_jsonb(profile) INTO v_after FROM public.company_branding_profiles profile
  WHERE profile.company_id=v_company;
  INSERT INTO public.company_branding_audit(company_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'VISIBILITY_UPDATE',v_actor,v_before,v_after);
  RETURN public.get_company_branding();
END
$$;

CREATE OR REPLACE FUNCTION public.save_company_document_visibility(
  p_expected_master_version BIGINT,p_show_logo_on_documents BOOLEAN,
  p_show_stamp_on_documents BOOLEAN,p_show_bank_account_on_invoice BOOLEAN,
  p_invoice_date_display_mode TEXT,p_delivery_signature_template TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_policy TEXT;
BEGIN
  SELECT profile.delivery_document_creation_policy INTO v_policy
  FROM public.company_branding_profiles profile WHERE profile.company_id=v_company;
  RETURN public.save_company_document_visibility(
    p_expected_master_version,p_show_logo_on_documents,p_show_stamp_on_documents,
    p_show_bank_account_on_invoice,p_invoice_date_display_mode,
    p_delivery_signature_template,COALESCE(v_policy,'DELIVERY_ONLY'));
END
$$;

CREATE OR REPLACE FUNCTION private.ensure_sales_documents(
  p_company_id UUID,p_sales_id UUID,p_provenance TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_sale public.sales_headers%ROWTYPE;v_invoice_id UUID;v_delivery_id UUID;
  v_delivery_no TEXT;v_delivery_status TEXT;v_payload JSONB;
  v_branding public.company_branding_profiles%ROWTYPE;
  v_creation_policy TEXT;v_create_delivery BOOLEAN;v_recipient_name TEXT;
  v_recipient_phone TEXT;v_delivery_address TEXT;v_scheduled_at TIMESTAMPTZ;
  v_delivery_notes TEXT;v_header_sj_status public.sj_status;
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
    OR (p_provenance='LIVE_POST' AND private.sales_delivery_document_required(
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
      (row_number() OVER(ORDER BY line.id))::INTEGER,line.product_id,
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

CREATE OR REPLACE FUNCTION private.trg_sld_guard_delivery_update()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'FINAL_SALES_DOCUMENT_HISTORY_IMMUTABLE'; END IF;
  IF COALESCE(current_setting('kgs.sld_delivery_status_mutation',TRUE),'')<>'1' THEN
    RAISE EXCEPTION 'GUARDED_SALES_DELIVERY_MUTATION_REQUIRED';
  END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.delivery_no IS DISTINCT FROM OLD.delivery_no
    OR NEW.sales_id IS DISTINCT FROM OLD.sales_id
    OR NEW.invoice_snapshot_id IS DISTINCT FROM OLD.invoice_snapshot_id
    OR NEW.store_id IS DISTINCT FROM OLD.store_id
    OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
    OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
    OR NEW.recipient_name IS DISTINCT FROM OLD.recipient_name
    OR NEW.recipient_phone IS DISTINCT FROM OLD.recipient_phone
    OR NEW.delivery_address IS DISTINCT FROM OLD.delivery_address
    OR NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at
    OR NEW.delivery_notes IS DISTINCT FROM OLD.delivery_notes
    OR NEW.snapshot_payload IS DISTINCT FROM OLD.snapshot_payload
    OR NEW.branding_logo_object_path IS DISTINCT FROM OLD.branding_logo_object_path
    OR NEW.fulfillment_mode IS DISTINCT FROM OLD.fulfillment_mode
    OR NEW.created_by IS DISTINCT FROM OLD.created_by
    OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'SALES_DELIVERY_SOURCE_SNAPSHOT_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION private.acp5e_update_sales_delivery_status_core(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_action TEXT,p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_delivery public.sales_delivery_documents%ROWTYPE;
  v_action TEXT:=upper(btrim(COALESCE(p_action,'')));v_status TEXT;
  v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT delivery.* INTO v_delivery FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND'; END IF;
  IF v_delivery.master_version<>p_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  v_status:=private.sales_delivery_transition_target(
    v_delivery.status,v_delivery.fulfillment_mode,v_action,p_reason);
  PERFORM set_config('kgs.sld_delivery_status_mutation','1',TRUE);
  UPDATE public.sales_delivery_documents SET status=v_status,
    master_version=master_version+1,
    dispatched_by=CASE WHEN v_status='DISPATCHED' THEN v_actor ELSE dispatched_by END,
    dispatched_at=CASE WHEN v_status='DISPATCHED' THEN v_now ELSE dispatched_at END,
    delivered_by=CASE WHEN v_status='DELIVERED' THEN v_actor ELSE delivered_by END,
    delivered_at=CASE WHEN v_status='DELIVERED' THEN v_now ELSE delivered_at END,
    canceled_by=CASE WHEN v_status='CANCELED' THEN v_actor ELSE canceled_by END,
    canceled_at=CASE WHEN v_status='CANCELED' THEN v_now ELSE canceled_at END,
    cancel_reason=CASE WHEN v_status='CANCELED' THEN btrim(p_reason) ELSE cancel_reason END
  WHERE company_id=v_company AND id=p_delivery_document_id;
  PERFORM set_config('kgs.sld_delivery_status_mutation','',TRUE);
  UPDATE public.sales_headers SET sj_status=CASE
    WHEN v_status IN('DISPATCHED','DELIVERED') THEN 'SHIPPED'::public.sj_status
    WHEN v_status='CANCELED' THEN 'NONE'::public.sj_status ELSE sj_status END
  WHERE company_id=v_company AND id=v_delivery.sales_id;
  INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
    sales_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'SALES_DELIVERY',p_delivery_document_id,v_delivery.sales_id,
    v_action,v_actor,jsonb_build_object('status',v_delivery.status,
      'masterVersion',v_delivery.master_version),jsonb_build_object(
      'status',v_status,'masterVersion',v_delivery.master_version+1,
      'fulfillmentMode',v_delivery.fulfillment_mode,
      'reason',CASE WHEN v_status='CANCELED' THEN btrim(p_reason) END));
  RETURN jsonb_build_object('deliveryDocumentId',p_delivery_document_id,
    'deliveryNo',v_delivery.delivery_no,'status',v_status,
    'fulfillmentMode',v_delivery.fulfillment_mode,
    'masterVersion',v_delivery.master_version+1);
END
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_delivery_documents(
  p_date_from DATE,p_date_to DATE
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_timezone TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  IF p_date_from IS NOT NULL AND p_date_to IS NOT NULL AND p_date_from>p_date_to THEN
    RAISE EXCEPTION 'INVALID_DELIVERY_DATE_RANGE';
  END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company;
  v_timezone:=COALESCE(v_timezone,'Asia/Jakarta');
  RETURN jsonb_build_object('companyId',v_company,'dateFrom',p_date_from,
    'dateTo',p_date_to,'timezone',v_timezone,'data',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'salesId',delivery.sales_id,'deliveryDocumentId',delivery.id,
      'deliveryNo',delivery.delivery_no,'status',delivery.status,
      'fulfillmentMode',delivery.fulfillment_mode,
      'masterVersion',delivery.master_version,'invoiceNo',invoice.invoice_no,
      'createdAt',delivery.created_at,'scheduledAt',delivery.scheduled_at,
      'recipientName',delivery.recipient_name,'recipientPhone',delivery.recipient_phone,
      'deliveryAddress',delivery.delivery_address,
      'customerName',COALESCE(customer.name,'Walk-In Customer'),
      'storeName',COALESCE(store.store_name,'Store'),
      'warehouseName',COALESCE(warehouse.name,'Gudang'))
      ORDER BY delivery.created_at DESC,delivery.id)
    FROM (SELECT candidate.* FROM public.sales_delivery_documents candidate
      WHERE candidate.company_id=v_company
        AND (p_date_from IS NULL OR (COALESCE(candidate.scheduled_at,candidate.created_at)
          AT TIME ZONE v_timezone)::DATE>=p_date_from)
        AND (p_date_to IS NULL OR (COALESCE(candidate.scheduled_at,candidate.created_at)
          AT TIME ZONE v_timezone)::DATE<=p_date_to)
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) delivery
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=delivery.company_id
      AND invoice.sales_id=delivery.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=delivery.company_id
      AND customer.id=delivery.customer_id
    LEFT JOIN public.stores store ON store.company_id=delivery.company_id
      AND store.id=delivery.store_id
    LEFT JOIN public.warehouses warehouse ON warehouse.company_id=delivery.company_id
      AND warehouse.id=delivery.warehouse_id),'[]'::JSONB));
END
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_delivery_documents()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT public.get_inventory_delivery_documents(NULL::DATE,NULL::DATE)
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_delivery_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_result JSONB;v_mode TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  v_result:=private.acp5e_get_sales_delivery_document_core(p_sales_id);
  SELECT delivery.fulfillment_mode INTO v_mode FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.sales_id=p_sales_id;
  RETURN v_result||jsonb_build_object('fulfillmentMode',v_mode);
END
$$;

REVOKE ALL ON FUNCTION private.sales_delivery_document_required(TEXT,TEXT),
  private.sales_delivery_transition_target(TEXT,TEXT,TEXT,TEXT),
  private.trg_sld_validate_delivery_fulfillment()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.sales_delivery_document_required(TEXT,TEXT),
  private.sales_delivery_transition_target(TEXT,TEXT,TEXT,TEXT),
  private.trg_sld_validate_delivery_fulfillment() TO service_role;
REVOKE ALL ON FUNCTION public.save_company_document_visibility(
  BIGINT,BOOLEAN,BOOLEAN,BOOLEAN,TEXT,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_company_document_visibility(
  BIGINT,BOOLEAN,BOOLEAN,BOOLEAN,TEXT,TEXT,TEXT) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827153000','company_automatic_delivery_document_policy',
  'Adds an opt-in Company policy for immutable Surat Jalan creation on every new posted Sale; Pickup uses direct handover while Delivery retains dispatch then deliver');
NOTIFY pgrst,'reload schema';
COMMIT;
