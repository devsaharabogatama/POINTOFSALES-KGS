-- Per-Company immutable Invoice date display policy.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260820120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260820120000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827150000';
  END IF;
END
$guard$;

ALTER TABLE public.company_branding_profiles
  ADD COLUMN invoice_date_display_mode TEXT NOT NULL DEFAULT 'ORDER_DATE',
  ADD CONSTRAINT company_branding_invoice_date_display_mode_check
    CHECK(invoice_date_display_mode IN('ORDER_DATE','POSTED_DATE'));

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
    'invoiceDateDisplayMode','ORDER_DATE','logoVersion',0,'masterVersion',NULL
  ); END IF;
  RETURN jsonb_build_object(
    'companyId',v_company,'hasLogo',v_profile.logo_object_path IS NOT NULL,
    'showLogoOnDocuments',v_profile.show_logo_on_documents,
    'showStampOnDocuments',v_profile.show_stamp_on_documents,
    'showBankAccountOnInvoice',v_profile.show_bank_account_on_invoice,
    'invoiceDateDisplayMode',v_profile.invoice_date_display_mode,
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
  p_invoice_date_display_mode TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_existing public.company_branding_profiles%ROWTYPE;v_before JSONB;v_after JSONB;
  v_date_mode TEXT:=upper(btrim(COALESCE(p_invoice_date_display_mode,'')));
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
      updated_by,updated_at)
    VALUES(v_company,p_show_logo_on_documents,p_show_stamp_on_documents,
      p_show_bank_account_on_invoice,v_date_mode,v_actor,clock_timestamp());
  ELSE
    IF v_existing.show_logo_on_documents=p_show_logo_on_documents
      AND v_existing.show_stamp_on_documents=p_show_stamp_on_documents
      AND v_existing.show_bank_account_on_invoice=p_show_bank_account_on_invoice
      AND v_existing.invoice_date_display_mode=v_date_mode THEN
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
  p_show_stamp_on_documents BOOLEAN,p_show_bank_account_on_invoice BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_mode TEXT;
BEGIN
  SELECT profile.invoice_date_display_mode INTO v_mode
  FROM public.company_branding_profiles profile WHERE profile.company_id=v_company;
  RETURN public.save_company_document_visibility(
    p_expected_master_version,p_show_logo_on_documents,p_show_stamp_on_documents,
    p_show_bank_account_on_invoice,COALESCE(v_mode,'ORDER_DATE'));
END
$$;

CREATE OR REPLACE FUNCTION private.build_sales_invoice_snapshot(
  p_company_id UUID,p_sales_id UUID,p_provenance TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_snapshot JSONB;v_company public.companies%ROWTYPE;
  v_branding public.company_branding_profiles%ROWTYPE;
  v_fee NUMERIC(20,4);v_mode TEXT;
BEGIN
  v_snapshot:=private.build_sales_invoice_snapshot_sld_r2_core(
    p_company_id,p_sales_id,p_provenance);
  IF v_snapshot IS NULL THEN RETURN NULL; END IF;
  SELECT company.* INTO STRICT v_company FROM public.companies company
  WHERE company.id=p_company_id;
  SELECT sale.delivery_fee_amount,sale.delivery_fee_invoice_display_mode
  INTO v_fee,v_mode FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
  SELECT branding.* INTO v_branding FROM public.company_branding_profiles branding
  WHERE branding.company_id=p_company_id;
  v_snapshot:=jsonb_set(v_snapshot,'{totals}',COALESCE(v_snapshot->'totals','{}'::JSONB)
    ||jsonb_build_object('deliveryFee',COALESCE(v_fee,0),
      'deliveryFeeInvoiceDisplayMode',COALESCE(v_mode,'SHOW_SEPARATE')),TRUE);
  v_snapshot:=jsonb_set(v_snapshot,'{company}',COALESCE(v_snapshot->'company','{}'::JSONB)
    ||jsonb_build_object('bankName',v_company.bank_name,
      'bankAccountNumber',v_company.bank_account_number,
      'bankAccountHolder',v_company.bank_account_holder),TRUE);
  v_snapshot:=jsonb_set(v_snapshot,'{branding}',COALESCE(v_snapshot->'branding','{}'::JSONB)
    ||jsonb_build_object('showBankAccountOnInvoice',
      COALESCE(v_branding.show_bank_account_on_invoice,FALSE),
      'invoiceDateDisplayMode',COALESCE(v_branding.invoice_date_display_mode,'ORDER_DATE')),TRUE);
  RETURN v_snapshot;
END
$$;

REVOKE ALL ON FUNCTION public.save_company_document_visibility(
  BIGINT,BOOLEAN,BOOLEAN,BOOLEAN,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_company_document_visibility(
  BIGINT,BOOLEAN,BOOLEAN,BOOLEAN,TEXT) TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.build_sales_invoice_snapshot(UUID,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.build_sales_invoice_snapshot(UUID,UUID,TEXT)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827150000','invoice_date_display_policy',
  'Adds audited Company Invoice date choice, defaults to order date for compatibility, and snapshots the choice into every new immutable Invoice');
NOTIFY pgrst,'reload schema';
COMMIT;
