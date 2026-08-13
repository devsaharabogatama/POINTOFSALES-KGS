-- BRD phase 1: tenant-safe Company branding/logo metadata foundation.
-- File bytes remain in Supabase Storage; PostgreSQL stores metadata and audit.

BEGIN;

DO $migration_guard$
BEGIN
    IF (
        SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20260811100000'
    ) <> 1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G6 Phase 7B dependency missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811110000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: BRD Phase 1 already applied';
    END IF;
    IF to_regclass('public.companies') IS NULL
       OR to_regclass('public.profiles') IS NULL
       OR to_regclass('storage.buckets') IS NULL
       OR to_regclass('storage.objects') IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Company or Storage foundation missing';
    END IF;
    IF to_regclass('public.company_branding_profiles') IS NOT NULL
       OR to_regclass('public.company_branding_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: branding relation collision';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_policies policy
        WHERE policy.schemaname='storage'
          AND policy.tablename='objects'
          AND policy.cmd IN ('ALL','INSERT','UPDATE','DELETE')
          AND 'authenticated'=ANY(policy.roles::TEXT[])
          AND concat_ws(' ',policy.qual,policy.with_check)
                ILIKE '%company-branding%'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: unsafe branding Storage policy';
    END IF;
END
$migration_guard$;

CREATE TABLE public.company_branding_profiles (
    company_id UUID PRIMARY KEY
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    logo_object_path TEXT,
    logo_public_url TEXT,
    logo_mime_type TEXT,
    logo_size_bytes BIGINT,
    logo_checksum_sha256 TEXT,
    logo_version BIGINT NOT NULL DEFAULT 0,
    master_version BIGINT NOT NULL DEFAULT 1,
    uploaded_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    uploaded_at TIMESTAMPTZ,
    updated_by UUID NOT NULL
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT company_branding_logo_version_check CHECK(logo_version >= 0),
    CONSTRAINT company_branding_master_version_check CHECK(master_version > 0),
    CONSTRAINT company_branding_logo_metadata_shape CHECK (
        (
            logo_object_path IS NULL
            AND logo_public_url IS NULL
            AND logo_mime_type IS NULL
            AND logo_size_bytes IS NULL
            AND logo_checksum_sha256 IS NULL
            AND uploaded_by IS NULL
            AND uploaded_at IS NULL
        ) OR (
            logo_object_path IS NOT NULL
            AND logo_public_url IS NOT NULL
            AND logo_mime_type IN ('image/png','image/jpeg','image/webp')
            AND logo_size_bytes BETWEEN 1 AND 2097152
            AND logo_checksum_sha256 ~ '^[0-9a-f]{64}$'
            AND uploaded_by IS NOT NULL
            AND uploaded_at IS NOT NULL
            AND logo_object_path LIKE company_id::TEXT || '/logo/%'
            AND logo_public_url ~ '^https://'
        )
    )
);

CREATE TABLE public.company_branding_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL
        REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT company_branding_audit_action_check CHECK (
        action IN ('UPLOAD','REPLACE','REMOVE')
    ),
    CONSTRAINT company_branding_audit_state_check CHECK (
        (action='UPLOAD' AND before_state IS NULL AND after_state IS NOT NULL)
        OR (action='REPLACE' AND before_state IS NOT NULL
            AND after_state IS NOT NULL)
        OR (action='REMOVE' AND before_state IS NOT NULL
            AND after_state IS NOT NULL)
    )
);

CREATE INDEX idx_company_branding_audit_company_time
    ON public.company_branding_audit(company_id,created_at DESC,id DESC);

CREATE FUNCTION private.trg_brd_guard_branding_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path=public,pg_temp
AS $$
BEGIN
    IF TG_TABLE_NAME='company_branding_audit' THEN
        RAISE EXCEPTION 'COMPANY_BRANDING_AUDIT_IMMUTABLE';
    END IF;
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'COMPANY_BRANDING_PROFILE_DELETE_FORBIDDEN';
    END IF;
    IF NEW.company_id IS DISTINCT FROM OLD.company_id THEN
        RAISE EXCEPTION 'COMPANY_BRANDING_COMPANY_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER company_branding_profile_history_guard
BEFORE UPDATE OR DELETE ON public.company_branding_profiles
FOR EACH ROW EXECUTE FUNCTION private.trg_brd_guard_branding_history();

CREATE TRIGGER company_branding_audit_history_guard
BEFORE UPDATE OR DELETE ON public.company_branding_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_brd_guard_branding_history();

CREATE FUNCTION public.get_company_branding()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_profile public.company_branding_profiles%ROWTYPE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_company_access(v_company) THEN
        RAISE EXCEPTION 'COMPANY_ACCESS_DENIED';
    END IF;
    SELECT profile.* INTO v_profile
    FROM public.company_branding_profiles profile
    WHERE profile.company_id=v_company;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'companyId',v_company,'hasLogo',FALSE,
            'logoVersion',0,'masterVersion',NULL
        );
    END IF;
    RETURN jsonb_build_object(
        'companyId',v_company,
        'hasLogo',v_profile.logo_object_path IS NOT NULL,
        'logoObjectPath',v_profile.logo_object_path,
        'logoPublicUrl',v_profile.logo_public_url,
        'logoMimeType',v_profile.logo_mime_type,
        'logoSizeBytes',v_profile.logo_size_bytes,
        'logoChecksumSha256',v_profile.logo_checksum_sha256,
        'logoVersion',v_profile.logo_version,
        'masterVersion',v_profile.master_version,
        'uploadedAt',v_profile.uploaded_at,
        'updatedAt',v_profile.updated_at
    );
END;
$$;

CREATE FUNCTION public.save_company_branding_logo(
    p_expected_master_version BIGINT,
    p_logo_object_path TEXT,
    p_logo_public_url TEXT,
    p_logo_mime_type TEXT,
    p_logo_size_bytes BIGINT,
    p_logo_checksum_sha256 TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_existing public.company_branding_profiles%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_checksum TEXT:=lower(btrim(COALESCE(p_logo_checksum_sha256,'')));
    v_path TEXT:=btrim(COALESCE(p_logo_object_path,''));
    v_url TEXT:=btrim(COALESCE(p_logo_public_url,''));
    v_mime TEXT:=lower(btrim(COALESCE(p_logo_mime_type,'')));
    v_extension TEXT;
    v_next_logo_version BIGINT;
    v_expected_path TEXT;
    v_result_version BIGINT;
    v_profile_exists BOOLEAN;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.companies company
        WHERE company.id=v_company AND company.status='ACTIVE'
    ) THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'COMPANY_BRANDING_MANAGER_REQUIRED'; END IF;
    IF v_mime NOT IN ('image/png','image/jpeg','image/webp') THEN
        RAISE EXCEPTION 'COMPANY_LOGO_MIME_NOT_ALLOWED';
    END IF;
    IF p_logo_size_bytes IS NULL
       OR p_logo_size_bytes NOT BETWEEN 1 AND 2097152 THEN
        RAISE EXCEPTION 'COMPANY_LOGO_SIZE_INVALID';
    END IF;
    IF v_checksum !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'COMPANY_LOGO_CHECKSUM_INVALID';
    END IF;
    IF v_url !~ '^https://' THEN
        RAISE EXCEPTION 'COMPANY_LOGO_PUBLIC_URL_INVALID';
    END IF;
    v_extension:=CASE v_mime
        WHEN 'image/png' THEN 'png'
        WHEN 'image/jpeg' THEN 'jpg'
        ELSE 'webp'
    END;

    SELECT profile.* INTO v_existing
    FROM public.company_branding_profiles profile
    WHERE profile.company_id=v_company
    FOR UPDATE;
    v_profile_exists:=FOUND;

    IF v_profile_exists
       AND v_existing.logo_object_path=v_path
       AND v_existing.logo_checksum_sha256=v_checksum THEN
        RETURN public.get_company_branding();
    END IF;

    IF NOT v_profile_exists THEN
        IF p_expected_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_next_logo_version:=1;
    ELSE
        IF p_expected_master_version IS NULL
           OR p_expected_master_version<>v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        v_before:=to_jsonb(v_existing);
        v_next_logo_version:=v_existing.logo_version+1;
    END IF;

    v_expected_path:=v_company::TEXT || '/logo/v'
        || v_next_logo_version::TEXT || '-' || left(v_checksum,12)
        || '.' || v_extension;
    IF v_path<>v_expected_path THEN
        RAISE EXCEPTION 'COMPANY_LOGO_OBJECT_PATH_INVALID';
    END IF;
    IF position('/company-branding/' || v_path IN v_url)=0 THEN
        RAISE EXCEPTION 'COMPANY_LOGO_PUBLIC_URL_PATH_MISMATCH';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM storage.objects object_state
        WHERE object_state.bucket_id='company-branding'
          AND object_state.name=v_path
    ) THEN
        RAISE EXCEPTION 'COMPANY_LOGO_STORAGE_OBJECT_NOT_FOUND';
    END IF;

    IF NOT v_profile_exists THEN
        INSERT INTO public.company_branding_profiles(
            company_id,logo_object_path,logo_public_url,logo_mime_type,
            logo_size_bytes,logo_checksum_sha256,logo_version,master_version,
            uploaded_by,uploaded_at,updated_by,updated_at
        ) VALUES(
            v_company,v_path,v_url,v_mime,p_logo_size_bytes,v_checksum,
            v_next_logo_version,1,v_actor,clock_timestamp(),v_actor,
            clock_timestamp()
        ) RETURNING master_version INTO v_result_version;
    ELSE
        UPDATE public.company_branding_profiles SET
            logo_object_path=v_path,
            logo_public_url=v_url,
            logo_mime_type=v_mime,
            logo_size_bytes=p_logo_size_bytes,
            logo_checksum_sha256=v_checksum,
            logo_version=v_next_logo_version,
            master_version=master_version+1,
            uploaded_by=v_actor,
            uploaded_at=clock_timestamp(),
            updated_by=v_actor,
            updated_at=clock_timestamp()
        WHERE company_id=v_company
        RETURNING master_version INTO v_result_version;
    END IF;

    SELECT to_jsonb(profile) INTO v_after
    FROM public.company_branding_profiles profile
    WHERE profile.company_id=v_company;
    INSERT INTO public.company_branding_audit(
        company_id,action,actor_id,before_state,after_state
    ) VALUES(
        v_company,CASE WHEN NOT v_profile_exists THEN 'UPLOAD' ELSE 'REPLACE' END,
        v_actor,v_before,v_after
    );
    RETURN public.get_company_branding();
END;
$$;

CREATE FUNCTION public.remove_company_branding_logo(
    p_expected_master_version BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_existing public.company_branding_profiles%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'COMPANY_BRANDING_MANAGER_REQUIRED'; END IF;

    SELECT profile.* INTO v_existing
    FROM public.company_branding_profiles profile
    WHERE profile.company_id=v_company
    FOR UPDATE;
    IF NOT FOUND THEN RETURN public.get_company_branding(); END IF;
    IF v_existing.logo_object_path IS NULL THEN
        RETURN public.get_company_branding();
    END IF;
    IF p_expected_master_version IS NULL
       OR p_expected_master_version<>v_existing.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_existing);
    UPDATE public.company_branding_profiles SET
        logo_object_path=NULL,
        logo_public_url=NULL,
        logo_mime_type=NULL,
        logo_size_bytes=NULL,
        logo_checksum_sha256=NULL,
        master_version=master_version+1,
        uploaded_by=NULL,
        uploaded_at=NULL,
        updated_by=v_actor,
        updated_at=clock_timestamp()
    WHERE company_id=v_company;
    SELECT to_jsonb(profile) INTO v_after
    FROM public.company_branding_profiles profile
    WHERE profile.company_id=v_company;
    INSERT INTO public.company_branding_audit(
        company_id,action,actor_id,before_state,after_state
    ) VALUES(v_company,'REMOVE',v_actor,v_before,v_after);
    RETURN public.get_company_branding();
END;
$$;

ALTER TABLE public.company_branding_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_branding_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Company branding readable in active Company"
ON public.company_branding_profiles FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);

CREATE POLICY "Company branding audit readable by Company administrators"
ON public.company_branding_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);

REVOKE ALL ON public.company_branding_profiles,public.company_branding_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.company_branding_profiles TO authenticated;
GRANT SELECT ON public.company_branding_audit TO authenticated;
GRANT ALL ON public.company_branding_profiles,public.company_branding_audit
TO service_role;

REVOKE ALL ON FUNCTION public.get_company_branding() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.save_company_branding_logo(
    BIGINT,TEXT,TEXT,TEXT,BIGINT,TEXT
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.remove_company_branding_logo(BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_company_branding()
TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.save_company_branding_logo(
    BIGINT,TEXT,TEXT,TEXT,BIGINT,TEXT
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.remove_company_branding_logo(BIGINT)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION private.trg_brd_guard_branding_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_brd_guard_branding_history()
TO service_role;

INSERT INTO storage.buckets(
    id,name,public,file_size_limit,allowed_mime_types
) VALUES(
    'company-branding','company-branding',TRUE,2097152,
    ARRAY['image/png','image/jpeg','image/webp']::TEXT[]
) ON CONFLICT(id) DO NOTHING;

DO $bucket_contract$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM storage.buckets bucket
        WHERE bucket.id='company-branding'
          AND bucket.name='company-branding'
          AND bucket.public
          AND bucket.file_size_limit=2097152
          AND bucket.allowed_mime_types @> ARRAY[
                'image/png','image/jpeg','image/webp'
              ]::TEXT[]
          AND cardinality(bucket.allowed_mime_types)=3
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: branding bucket contract mismatch';
    END IF;
END
$bucket_contract$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260811110000',
    'brd_phase1_company_branding_foundation',
    'Tenant-safe Company logo metadata and immutable audit, guarded active-Company RPC, optimistic versioning, public-read server-write Storage bucket contract, and no transaction evidence upload expansion'
);

COMMIT;
