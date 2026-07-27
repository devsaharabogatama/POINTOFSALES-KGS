-- G1 phase 4 behavioral test: active Company context authorization/audit.
-- SAFETY: all fixtures and context changes are rolled back.

BEGIN;

DO $test$
DECLARE
    v_super_admin UUID;
    v_unauthorized UUID := '00000000-0000-0000-0000-000000004099';
    v_company_a UUID := '00000000-0000-0000-0000-000000004001';
    v_company_b UUID := '00000000-0000-0000-0000-000000004002';
    v_audit_before BIGINT;
    v_audit_after BIGINT;
    v_rejected BOOLEAN := FALSE;
BEGIN
    SELECT p.id INTO v_super_admin
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;

    IF v_super_admin IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin is required';
    END IF;

    INSERT INTO public.companies (id, company_code, company_name, company_slug, status) VALUES
        (v_company_a,'G4A','G4 Company A','g4-company-a','ACTIVE'),
        (v_company_b,'G4B','G4 Company B','g4-company-b','ACTIVE');

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', v_super_admin, 'role', 'authenticated')::text,
        TRUE
    );

    SELECT count(*) INTO v_audit_before
    FROM public.user_active_company_context_audit
    WHERE user_id = v_super_admin
      AND selection_source = 'G1_PHASE4_TEST';

    PERFORM public.set_active_company_context(v_company_a, 'G1_PHASE4_TEST');

    IF public.private_active_company_id() IS DISTINCT FROM v_company_a
       OR NOT public.private_request_company_matches(v_company_a) THEN
        RAISE EXCEPTION 'TEST_FAILED: first active Company context was not stored';
    END IF;

    -- Idempotent repeat must not append another audit row.
    PERFORM public.set_active_company_context(v_company_a, 'G1_PHASE4_TEST');
    PERFORM public.set_active_company_context(v_company_b, 'G1_PHASE4_TEST');

    IF public.private_active_company_id() IS DISTINCT FROM v_company_b
       OR public.private_request_company_matches(v_company_a) THEN
        RAISE EXCEPTION 'TEST_FAILED: active Company switch was not applied';
    END IF;

    SELECT count(*) INTO v_audit_after
    FROM public.user_active_company_context_audit
    WHERE user_id = v_super_admin
      AND selection_source = 'G1_PHASE4_TEST';

    IF v_audit_after <> v_audit_before + 2 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected two context audit rows, before %, after %',
            v_audit_before, v_audit_after;
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', v_unauthorized, 'role', 'authenticated')::text,
        TRUE
    );

    BEGIN
        PERFORM public.set_active_company_context(v_company_a, 'G1_PHASE4_TEST');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'COMPANY_ACCESS_DENIED' THEN
            v_rejected := TRUE;
        ELSE
            RAISE EXCEPTION 'TEST_FAILED with unexpected unauthorized error: %', SQLERRM;
        END IF;
    END;

    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: unauthorized user selected a Company';
    END IF;

    IF has_table_privilege(
        'authenticated', 'public.user_active_company_contexts', 'INSERT'
    ) OR NOT has_function_privilege(
        'authenticated', 'public.set_active_company_context(uuid,text)', 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: context privilege boundary is incorrect';
    END IF;

    RAISE NOTICE 'TEST PASSED: active Company selection is authorized, audited, and idempotent.';
END
$test$;

ROLLBACK;
