-- BRD phase 1 behavior: guarded branding and two-Company isolation.
-- SAFETY: every Company/profile/audit fixture is rolled back.

BEGIN;

DO $setup$
DECLARE
    v_actor UUID;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000120001',
         'BRD120A','BRD Company A','brd-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000120002',
         'BRD120B','BRD Company B','brd-company-b','ACTIVE');

    -- Simulate objects already uploaded by the future server-only upload API.
    -- Metadata activation must fail when the object is absent.
    INSERT INTO storage.objects(bucket_id,name) VALUES
        ('company-branding',
         '00000000-0000-0000-0000-000000120001/logo/v1-aaaaaaaaaaaa.png'),
        ('company-branding',
         '00000000-0000-0000-0000-000000120001/logo/v2-cccccccccccc.webp'),
        ('company-branding',
         '00000000-0000-0000-0000-000000120002/logo/v1-bbbbbbbbbbbb.jpg');

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000120001','BRD_PHASE1_TEST'
    );
END
$setup$;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
    v_path_a1 TEXT:=
        '00000000-0000-0000-0000-000000120001/logo/v1-aaaaaaaaaaaa.png';
    v_path_a2 TEXT:=
        '00000000-0000-0000-0000-000000120001/logo/v2-cccccccccccc.webp';
    v_path_b1 TEXT:=
        '00000000-0000-0000-0000-000000120002/logo/v1-bbbbbbbbbbbb.jpg';
BEGIN
    v_result:=public.get_company_branding();
    IF (v_result->>'companyId')::UUID<>
            '00000000-0000-0000-0000-000000120001'
       OR (v_result->>'hasLogo')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: empty Company A branding invalid';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_company_branding_logo(
            NULL,
            '00000000-0000-0000-0000-000000120002/logo/v1-aaaaaaaaaaaa.png',
            'https://example.invalid/storage/v1/object/public/company-branding/'
                || '00000000-0000-0000-0000-000000120002/logo/'
                || 'v1-aaaaaaaaaaaa.png',
            'image/png',100,repeat('a',64)
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='COMPANY_LOGO_OBJECT_PATH_INVALID' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company object path accepted';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_company_branding_logo(
            NULL,
            '00000000-0000-0000-0000-000000120001/logo/v1-dddddddddddd.png',
            'https://example.invalid/storage/v1/object/public/company-branding/'
                || '00000000-0000-0000-0000-000000120001/logo/'
                || 'v1-dddddddddddd.png',
            'image/png',100,repeat('d',64)
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='COMPANY_LOGO_STORAGE_OBJECT_NOT_FOUND' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: absent Storage object activated';
    END IF;

    v_result:=public.save_company_branding_logo(
        NULL,v_path_a1,
        'https://example.invalid/storage/v1/object/public/company-branding/'
            || v_path_a1,
        'image/png',100,repeat('a',64)
    );
    IF (v_result->>'masterVersion')::BIGINT<>1
       OR (v_result->>'logoVersion')::BIGINT<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company A upload version invalid';
    END IF;

    -- Exact retry is idempotent even if the caller repeats create semantics.
    v_result:=public.save_company_branding_logo(
        NULL,v_path_a1,
        'https://example.invalid/storage/v1/object/public/company-branding/'
            || v_path_a1,
        'image/png',100,repeat('a',64)
    );
    SELECT count(*) INTO v_count
    FROM public.company_branding_audit audit
    WHERE audit.company_id='00000000-0000-0000-0000-000000120001';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated audit';
    END IF;

    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000120002','BRD_PHASE1_TEST'
    );
    SELECT count(*) INTO v_count
    FROM public.company_branding_profiles profile
    WHERE profile.company_id='00000000-0000-0000-0000-000000120001';
    IF v_count<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company B can read Company A branding';
    END IF;
    v_result:=public.get_company_branding();
    IF (v_result->>'companyId')::UUID<>
            '00000000-0000-0000-0000-000000120002'
       OR (v_result->>'hasLogo')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: active Company B resolved A branding';
    END IF;

    v_result:=public.save_company_branding_logo(
        NULL,v_path_b1,
        'https://example.invalid/storage/v1/object/public/company-branding/'
            || v_path_b1,
        'image/jpeg',200,repeat('b',64)
    );
    IF (v_result->>'companyId')::UUID<>
            '00000000-0000-0000-0000-000000120002' THEN
        RAISE EXCEPTION 'TEST_FAILED: Company B branding identity invalid';
    END IF;

    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000120001','BRD_PHASE1_TEST'
    );
    SELECT count(*) INTO v_count
    FROM public.company_branding_profiles profile
    WHERE profile.company_id='00000000-0000-0000-0000-000000120002';
    IF v_count<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company A can read Company B branding';
    END IF;
    v_result:=public.get_company_branding();
    IF v_result->>'logoObjectPath'<>v_path_a1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company A resolved Company B branding';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_company_branding_logo(
            0,v_path_a2,
            'https://example.invalid/storage/v1/object/public/company-branding/'
                || v_path_a2,
            'image/webp',300,repeat('c',64)
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='MASTER_VERSION_CONFLICT' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Company A replace accepted';
    END IF;

    v_result:=public.save_company_branding_logo(
        1,v_path_a2,
        'https://example.invalid/storage/v1/object/public/company-branding/'
            || v_path_a2,
        'image/webp',300,repeat('c',64)
    );
    IF (v_result->>'masterVersion')::BIGINT<>2
       OR (v_result->>'logoVersion')::BIGINT<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: replace version invalid';
    END IF;

    v_result:=public.remove_company_branding_logo(2);
    IF (v_result->>'hasLogo')::BOOLEAN
       OR (v_result->>'masterVersion')::BIGINT<>3 THEN
        RAISE EXCEPTION 'TEST_FAILED: remove result invalid';
    END IF;
    PERFORM public.remove_company_branding_logo(2);
    SELECT count(*) INTO v_count
    FROM public.company_branding_audit audit
    WHERE audit.company_id='00000000-0000-0000-0000-000000120001';
    IF v_count<>3 THEN
        RAISE EXCEPTION 'TEST_FAILED: remove retry duplicated audit';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        UPDATE public.company_branding_profiles
        SET updated_at=clock_timestamp()
        WHERE company_id='00000000-0000-0000-0000-000000120001';
    EXCEPTION WHEN insufficient_privilege THEN
        v_rejected:=TRUE;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: browser direct profile update accepted';
    END IF;
END
$test$;

RESET ROLE;

DO $verify$
DECLARE
    v_count BIGINT;
BEGIN
    SELECT count(*) INTO v_count
    FROM public.company_branding_profiles profile
    WHERE profile.company_id IN (
        '00000000-0000-0000-0000-000000120001',
        '00000000-0000-0000-0000-000000120002'
    );
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two isolated profiles';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.company_branding_profiles profile
        WHERE profile.logo_object_path IS NOT NULL
          AND profile.logo_object_path NOT LIKE
                profile.company_id::TEXT || '/logo/%'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: persisted cross-Company logo path';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.company_branding_audit audit
    WHERE audit.company_id IN (
        '00000000-0000-0000-0000-000000120001',
        '00000000-0000-0000-0000-000000120002'
    );
    IF v_count<>4 THEN
        RAISE EXCEPTION 'TEST_FAILED: branding audit total invalid';
    END IF;
    RAISE NOTICE
        'TEST PASSED: Company branding is guarded, versioned, audited, idempotent, and isolated across two active Companies.';
END
$verify$;

ROLLBACK;
