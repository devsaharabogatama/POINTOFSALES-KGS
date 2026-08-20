-- Company profile, optional bank identity, Invoice bank visibility, and
-- Supplier Payment bank-reference convenience.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260820110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260820110000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260820120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260820120000';
  END IF;
END
$guard$;

ALTER TABLE public.companies
  ADD COLUMN address TEXT,
  ADD COLUMN city TEXT,
  ADD COLUMN province TEXT,
  ADD COLUMN postal_code TEXT,
  ADD COLUMN country TEXT,
  ADD COLUMN phone TEXT,
  ADD COLUMN email TEXT,
  ADD COLUMN website TEXT,
  ADD COLUMN registration_no TEXT,
  ADD COLUMN bank_name TEXT,
  ADD COLUMN bank_account_number TEXT,
  ADD COLUMN bank_account_holder TEXT,
  ADD COLUMN profile_master_version BIGINT NOT NULL DEFAULT 1,
  ADD CONSTRAINT companies_profile_master_version_positive
    CHECK(profile_master_version>0),
  ADD CONSTRAINT companies_bank_identity_complete CHECK(
    (bank_name IS NULL AND bank_account_number IS NULL
      AND bank_account_holder IS NULL)
    OR (NULLIF(btrim(bank_name),'') IS NOT NULL
      AND NULLIF(btrim(bank_account_number),'') IS NOT NULL
      AND NULLIF(btrim(bank_account_holder),'') IS NOT NULL)
  );

ALTER TABLE public.company_branding_profiles
  ADD COLUMN show_bank_account_on_invoice BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.company_branding_audit
  DROP CONSTRAINT company_branding_audit_action_check,
  DROP CONSTRAINT company_branding_audit_state_check,
  ADD CONSTRAINT company_branding_audit_action_check CHECK(
    action IN('UPLOAD','REPLACE','REMOVE','VISIBILITY_UPDATE','PROFILE_UPDATE')
  ),
  ADD CONSTRAINT company_branding_audit_state_check CHECK(
    (action='UPLOAD' AND before_state IS NULL AND after_state IS NOT NULL)
    OR (action='REPLACE' AND before_state IS NOT NULL AND after_state IS NOT NULL)
    OR (action='REMOVE' AND before_state IS NOT NULL AND after_state IS NOT NULL)
    OR (action IN('VISIBILITY_UPDATE','PROFILE_UPDATE')
      AND after_state IS NOT NULL)
  );

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
    'logoVersion',0,'masterVersion',NULL
  ); END IF;
  RETURN jsonb_build_object(
    'companyId',v_company,'hasLogo',v_profile.logo_object_path IS NOT NULL,
    'showLogoOnDocuments',v_profile.show_logo_on_documents,
    'showStampOnDocuments',v_profile.show_stamp_on_documents,
    'showBankAccountOnInvoice',v_profile.show_bank_account_on_invoice,
    'logoObjectPath',v_profile.logo_object_path,'logoPublicUrl',v_profile.logo_public_url,
    'logoMimeType',v_profile.logo_mime_type,'logoSizeBytes',v_profile.logo_size_bytes,
    'logoChecksumSha256',v_profile.logo_checksum_sha256,
    'logoVersion',v_profile.logo_version,'masterVersion',v_profile.master_version,
    'uploadedAt',v_profile.uploaded_at,'updatedAt',v_profile.updated_at
  );
END
$$;

CREATE FUNCTION public.get_company_profile()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_record public.companies%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(
    v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
  ) THEN RAISE EXCEPTION 'COMPANY_PROFILE_MANAGER_REQUIRED'; END IF;
  SELECT company.* INTO STRICT v_record FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  RETURN jsonb_build_object(
    'companyId',v_record.id,'companyCode',v_record.company_code,
    'companyName',v_record.company_name,'legalName',v_record.legal_name,
    'taxId',v_record.tax_id,'registrationNo',v_record.registration_no,
    'address',v_record.address,'city',v_record.city,'province',v_record.province,
    'postalCode',v_record.postal_code,'country',v_record.country,
    'phone',v_record.phone,'email',v_record.email,'website',v_record.website,
    'bankName',v_record.bank_name,'bankAccountNumber',v_record.bank_account_number,
    'bankAccountHolder',v_record.bank_account_holder,
    'profileMasterVersion',v_record.profile_master_version,
    'updatedAt',v_record.updated_at
  );
END
$$;

CREATE FUNCTION public.save_company_profile(
  p_expected_master_version BIGINT,p_legal_name TEXT,p_tax_id TEXT,
  p_registration_no TEXT,p_address TEXT,p_city TEXT,p_province TEXT,
  p_postal_code TEXT,p_country TEXT,p_phone TEXT,p_email TEXT,p_website TEXT,
  p_bank_name TEXT,p_bank_account_number TEXT,p_bank_account_holder TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_before JSONB;v_after JSONB;v_bank_count INTEGER;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT public.private_user_has_any_company_or_store_role(
    v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
  ) THEN RAISE EXCEPTION 'COMPANY_PROFILE_MANAGER_REQUIRED'; END IF;
  IF p_expected_master_version IS NULL OR p_expected_master_version<1 THEN
    RAISE EXCEPTION 'INVALID_EXPECTED_MASTER_VERSION';
  END IF;
  v_bank_count:=(CASE WHEN NULLIF(btrim(p_bank_name),'') IS NULL THEN 0 ELSE 1 END)
    +(CASE WHEN NULLIF(btrim(p_bank_account_number),'') IS NULL THEN 0 ELSE 1 END)
    +(CASE WHEN NULLIF(btrim(p_bank_account_holder),'') IS NULL THEN 0 ELSE 1 END);
  IF v_bank_count NOT IN(0,3) THEN RAISE EXCEPTION 'COMPANY_BANK_ACCOUNT_INCOMPLETE'; END IF;
  IF NULLIF(btrim(p_email),'') IS NOT NULL
     AND btrim(p_email) !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN
    RAISE EXCEPTION 'COMPANY_EMAIL_INVALID';
  END IF;
  IF NULLIF(btrim(p_website),'') IS NOT NULL
     AND btrim(p_website) !~ '^https?://' THEN RAISE EXCEPTION 'COMPANY_WEBSITE_INVALID'; END IF;

  SELECT to_jsonb(company) INTO STRICT v_before FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE' FOR UPDATE;
  IF (v_before->>'legal_name') IS NOT DISTINCT FROM NULLIF(btrim(p_legal_name),'')
    AND (v_before->>'tax_id') IS NOT DISTINCT FROM NULLIF(btrim(p_tax_id),'')
    AND (v_before->>'registration_no') IS NOT DISTINCT FROM NULLIF(btrim(p_registration_no),'')
    AND (v_before->>'address') IS NOT DISTINCT FROM NULLIF(btrim(p_address),'')
    AND (v_before->>'city') IS NOT DISTINCT FROM NULLIF(btrim(p_city),'')
    AND (v_before->>'province') IS NOT DISTINCT FROM NULLIF(btrim(p_province),'')
    AND (v_before->>'postal_code') IS NOT DISTINCT FROM NULLIF(btrim(p_postal_code),'')
    AND (v_before->>'country') IS NOT DISTINCT FROM NULLIF(btrim(p_country),'')
    AND (v_before->>'phone') IS NOT DISTINCT FROM NULLIF(btrim(p_phone),'')
    AND (v_before->>'email') IS NOT DISTINCT FROM lower(NULLIF(btrim(p_email),''))
    AND (v_before->>'website') IS NOT DISTINCT FROM NULLIF(btrim(p_website),'')
    AND (v_before->>'bank_name') IS NOT DISTINCT FROM NULLIF(btrim(p_bank_name),'')
    AND (v_before->>'bank_account_number') IS NOT DISTINCT FROM NULLIF(btrim(p_bank_account_number),'')
    AND (v_before->>'bank_account_holder') IS NOT DISTINCT FROM NULLIF(btrim(p_bank_account_holder),'') THEN
    RETURN public.get_company_profile();
  END IF;
  IF (v_before->>'profile_master_version')::BIGINT<>p_expected_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  UPDATE public.companies SET
    legal_name=NULLIF(btrim(p_legal_name),''),tax_id=NULLIF(btrim(p_tax_id),''),
    registration_no=NULLIF(btrim(p_registration_no),''),address=NULLIF(btrim(p_address),''),
    city=NULLIF(btrim(p_city),''),province=NULLIF(btrim(p_province),''),
    postal_code=NULLIF(btrim(p_postal_code),''),country=NULLIF(btrim(p_country),''),
    phone=NULLIF(btrim(p_phone),''),email=lower(NULLIF(btrim(p_email),'')),
    website=NULLIF(btrim(p_website),''),bank_name=NULLIF(btrim(p_bank_name),''),
    bank_account_number=NULLIF(btrim(p_bank_account_number),''),
    bank_account_holder=NULLIF(btrim(p_bank_account_holder),''),
    profile_master_version=profile_master_version+1,updated_at=clock_timestamp()
  WHERE id=v_company;
  SELECT to_jsonb(company) INTO v_after FROM public.companies company WHERE company.id=v_company;
  INSERT INTO public.company_branding_audit(company_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'PROFILE_UPDATE',v_actor,v_before,v_after);
  RETURN public.get_company_profile();
END
$$;

CREATE FUNCTION public.save_company_document_visibility(
  p_expected_master_version BIGINT,p_show_logo_on_documents BOOLEAN,
  p_show_stamp_on_documents BOOLEAN,p_show_bank_account_on_invoice BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_existing public.company_branding_profiles%ROWTYPE;v_before JSONB;v_after JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_show_logo_on_documents IS NULL OR p_show_stamp_on_documents IS NULL
     OR p_show_bank_account_on_invoice IS NULL THEN
    RAISE EXCEPTION 'COMPANY_DOCUMENT_VISIBILITY_REQUIRED';
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
      show_stamp_on_documents,show_bank_account_on_invoice,updated_by,updated_at)
    VALUES(v_company,p_show_logo_on_documents,p_show_stamp_on_documents,
      p_show_bank_account_on_invoice,v_actor,clock_timestamp());
  ELSE
    IF v_existing.show_logo_on_documents=p_show_logo_on_documents
      AND v_existing.show_stamp_on_documents=p_show_stamp_on_documents
      AND v_existing.show_bank_account_on_invoice=p_show_bank_account_on_invoice THEN
      RETURN public.get_company_branding();
    END IF;
    IF p_expected_master_version IS NULL OR p_expected_master_version<>v_existing.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_existing);
    UPDATE public.company_branding_profiles SET
      show_logo_on_documents=p_show_logo_on_documents,
      show_stamp_on_documents=p_show_stamp_on_documents,
      show_bank_account_on_invoice=p_show_bank_account_on_invoice,
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
      COALESCE(v_branding.show_bank_account_on_invoice,FALSE)),TRUE);
  RETURN v_snapshot;
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_supplier_payments()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.supplier_payments','VIEW');
  RETURN jsonb_build_object(
    'companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',COALESCE(v_permission->'effectiveCapabilities','[]'::JSONB),
    'documents',(SELECT COALESCE(jsonb_agg(to_jsonb(document) ORDER BY document.created_at DESC,document.id DESC),'[]'::JSONB)
      FROM (SELECT candidate.* FROM public.supplier_payment_documents candidate WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document),
    'allocations',(SELECT COALESCE(jsonb_agg(to_jsonb(allocation) ORDER BY allocation.document_id,allocation.created_at,allocation.id),'[]'::JSONB)
      FROM public.supplier_payment_allocations allocation WHERE allocation.company_id=v_company AND EXISTS(
        SELECT 1 FROM (SELECT candidate.id FROM public.supplier_payment_documents candidate WHERE candidate.company_id=v_company ORDER BY candidate.created_at DESC,candidate.id DESC LIMIT 500) document WHERE document.id=allocation.document_id)),
    'validatedInvoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',invoice.id,'invoice_no',invoice.invoice_no,'supplier_id',invoice.supplier_id,
      'supplier_invoice_no',invoice.supplier_invoice_no,'invoice_date',invoice.invoice_date,
      'due_date',invoice.due_date,'grand_total',invoice.grand_total,'status',invoice.status,
      'matching_status',invoice.matching_status,'created_at',invoice.created_at,
      'paid_amount',COALESCE(paid.amount,0),'remaining_balance',GREATEST(invoice.grand_total-COALESCE(paid.amount,0),0))
      ORDER BY invoice.created_at DESC,invoice.id DESC),'[]'::JSONB)
      FROM public.supplier_invoice_documents invoice
      LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) amount
        FROM public.supplier_payment_allocations allocation JOIN public.supplier_payment_documents payment
          ON payment.company_id=allocation.company_id AND payment.id=allocation.document_id AND payment.status='VALIDATED'
        WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id) paid ON TRUE
      WHERE invoice.company_id=v_company AND invoice.status='VALIDATED'),
    'suppliers',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',supplier.id,'supplier_code',supplier.supplier_code,'supplier_name',supplier.supplier_name,
      'is_active',supplier.is_active,'bank_name',supplier.bank_name,
      'bank_account_number',supplier.bank_account_number,
      'bank_account_holder',supplier.bank_account_holder)
      ORDER BY supplier.supplier_name,supplier.id),'[]'::JSONB)
      FROM public.suppliers supplier WHERE supplier.company_id=v_company AND supplier.is_active),
    'accounts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',account.id,'account_code',account.account_code,'account_name',account.account_name,
      'account_type',account.account_type,'is_active',account.is_active) ORDER BY account.account_code,account.id),'[]'::JSONB)
      FROM public.chart_of_accounts account WHERE account.company_id=v_company AND account.is_active
        AND account.is_postable AND account.account_type='ASSET'
        AND (private.acp6f_source_account_allowed(v_company,account.id,'CASH')
          OR private.acp6f_source_account_allowed(v_company,account.id,'BANK_TRANSFER'))),
    'profiles',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',profile.id,'full_name',profile.name,'username',profile.name) ORDER BY profile.name,profile.id),'[]'::JSONB)
      FROM public.profiles profile WHERE EXISTS(SELECT 1 FROM public.supplier_payment_documents document
        WHERE document.company_id=v_company AND profile.id IN(document.created_by,document.validated_by,document.canceled_by)))
  );
END
$$;

REVOKE ALL ON FUNCTION public.get_company_profile(),
  public.save_company_profile(BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),
  public.save_company_document_visibility(BIGINT,BOOLEAN,BOOLEAN,BOOLEAN)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_company_profile(),
  public.save_company_profile(BIGINT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT),
  public.save_company_document_visibility(BIGINT,BOOLEAN,BOOLEAN,BOOLEAN)
TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.build_sales_invoice_snapshot(UUID,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.build_sales_invoice_snapshot(UUID,UUID,TEXT) TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260820120000','company_profile_bank_invoice',
  'Adds audited Company profile and optional bank identity, Invoice bank visibility default OFF, immutable new-Invoice bank snapshots, and Supplier Payment bank-reference autofill data');
NOTIFY pgrst,'reload schema';
COMMIT;
