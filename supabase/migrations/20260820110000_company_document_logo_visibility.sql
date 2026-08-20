-- Optional Company logo visibility for printable business documents.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260820110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260820110000';
  END IF;
  IF to_regclass('public.company_branding_profiles') IS NULL
     OR to_regclass('public.company_branding_audit') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Company branding foundation missing';
  END IF;
END
$guard$;

ALTER TABLE public.company_branding_profiles
  ADD COLUMN show_logo_on_documents BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN show_stamp_on_documents BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.company_branding_audit
  DROP CONSTRAINT company_branding_audit_action_check,
  DROP CONSTRAINT company_branding_audit_state_check,
  ADD CONSTRAINT company_branding_audit_action_check CHECK(
    action IN('UPLOAD','REPLACE','REMOVE','VISIBILITY_UPDATE')
  ),
  ADD CONSTRAINT company_branding_audit_state_check CHECK(
    (action='UPLOAD' AND before_state IS NULL AND after_state IS NOT NULL)
    OR (action='REPLACE' AND before_state IS NOT NULL AND after_state IS NOT NULL)
    OR (action='REMOVE' AND before_state IS NOT NULL AND after_state IS NOT NULL)
    OR (action='VISIBILITY_UPDATE' AND after_state IS NOT NULL)
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
    'showStampOnDocuments',FALSE,
    'logoVersion',0,'masterVersion',NULL
  ); END IF;
  RETURN jsonb_build_object(
    'companyId',v_company,'hasLogo',v_profile.logo_object_path IS NOT NULL,
    'showLogoOnDocuments',v_profile.show_logo_on_documents,
    'showStampOnDocuments',v_profile.show_stamp_on_documents,
    'logoObjectPath',v_profile.logo_object_path,
    'logoPublicUrl',v_profile.logo_public_url,
    'logoMimeType',v_profile.logo_mime_type,
    'logoSizeBytes',v_profile.logo_size_bytes,
    'logoChecksumSha256',v_profile.logo_checksum_sha256,
    'logoVersion',v_profile.logo_version,'masterVersion',v_profile.master_version,
    'uploadedAt',v_profile.uploaded_at,'updatedAt',v_profile.updated_at
  );
END
$$;

CREATE FUNCTION public.save_company_document_logo_visibility(
  p_expected_master_version BIGINT,p_show_logo_on_documents BOOLEAN,
  p_show_stamp_on_documents BOOLEAN
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=auth.uid();v_company UUID:=public.private_active_company_id();
  v_existing public.company_branding_profiles%ROWTYPE;v_before JSONB;v_after JSONB;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_show_logo_on_documents IS NULL OR p_show_stamp_on_documents IS NULL THEN
    RAISE EXCEPTION 'COMPANY_DOCUMENT_LOGO_VISIBILITY_REQUIRED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE') THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND';
  END IF;
  IF NOT public.private_user_has_any_company_or_store_role(
    v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
  ) THEN RAISE EXCEPTION 'COMPANY_BRANDING_MANAGER_REQUIRED'; END IF;

  SELECT profile.* INTO v_existing FROM public.company_branding_profiles profile
  WHERE profile.company_id=v_company FOR UPDATE;
  IF NOT FOUND THEN
    IF p_expected_master_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    INSERT INTO public.company_branding_profiles(
      company_id,show_logo_on_documents,show_stamp_on_documents,updated_by,updated_at
    ) VALUES(v_company,p_show_logo_on_documents,p_show_stamp_on_documents,
      v_actor,clock_timestamp());
  ELSE
    IF v_existing.show_logo_on_documents=p_show_logo_on_documents
       AND v_existing.show_stamp_on_documents=p_show_stamp_on_documents THEN
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
      master_version=master_version+1,updated_by=v_actor,
      updated_at=clock_timestamp()
    WHERE company_id=v_company;
  END IF;
  SELECT to_jsonb(profile) INTO v_after FROM public.company_branding_profiles profile
  WHERE profile.company_id=v_company;
  INSERT INTO public.company_branding_audit(
    company_id,action,actor_id,before_state,after_state
  ) VALUES(v_company,'VISIBILITY_UPDATE',v_actor,v_before,v_after);
  RETURN public.get_company_branding();
END
$$;

REVOKE ALL ON FUNCTION public.save_company_document_logo_visibility(BIGINT,BOOLEAN,BOOLEAN)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_company_document_logo_visibility(BIGINT,BOOLEAN,BOOLEAN)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260820110000','company_document_logo_visibility',
  'Adds audited Company settings for independent header-logo and stamp visibility on printable Invoice and Delivery documents; existing Companies default header visible and stamp hidden');
NOTIFY pgrst,'reload schema';
COMMIT;
