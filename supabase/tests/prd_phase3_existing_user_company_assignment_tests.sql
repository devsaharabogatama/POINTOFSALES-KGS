-- PRD-1 phase 3 behavior: one identity can hold isolated Company memberships.
-- SAFETY: every Company, Store, membership, and audit fixture is rolled back.

BEGIN;

DO $setup$
DECLARE
    v_actor UUID;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000123001',
         'PRD123A','PRD Company A','prd-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000123002',
         'PRD123B','PRD Company B','prd-company-b','ACTIVE');
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES
        ('00000000-0000-0000-0000-000000123011',
         '00000000-0000-0000-0000-000000123001',
         'STORE-A','PRD Store A','ACTIVE'),
        ('00000000-0000-0000-0000-000000123012',
         '00000000-0000-0000-0000-000000123002',
         'STORE-B','PRD Store B','ACTIVE');

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
END
$setup$;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
    v_actor UUID:=auth.uid();
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN:=FALSE;
BEGIN
    v_result:=public.assign_existing_user_to_company(
        '00000000-0000-0000-0000-000000123001',v_actor,
        'COMPANY_ADMIN',NULL
    );
    IF v_result->>'action'<>'ASSIGN' THEN
        RAISE EXCEPTION 'TEST_FAILED: first assignment action invalid';
    END IF;

    v_result:=public.assign_existing_user_to_company(
        '00000000-0000-0000-0000-000000123002',v_actor,
        'CASHIER','00000000-0000-0000-0000-000000123012'
    );
    IF v_result->>'action'<>'ASSIGN'
       OR NOT (v_result->>'storeAssigned')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: second Company Cashier assignment invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.company_memberships membership
    WHERE membership.user_id=v_actor
      AND membership.company_id IN(
        '00000000-0000-0000-0000-000000123001',
        '00000000-0000-0000-0000-000000123002'
      ) AND membership.status='ACTIVE';
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: multi-Company membership count invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.store_memberships membership
    WHERE membership.company_id='00000000-0000-0000-0000-000000123002'
      AND membership.store_id='00000000-0000-0000-0000-000000123012'
      AND membership.user_id=v_actor AND membership.role_code='CASHIER'
      AND membership.status='ACTIVE';
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cashier Store assignment missing';
    END IF;

    v_result:=public.assign_existing_user_to_company(
        '00000000-0000-0000-0000-000000123002',v_actor,
        'CASHIER','00000000-0000-0000-0000-000000123012'
    );
    IF v_result->>'action'<>'EXACT_RETRY' THEN
        RAISE EXCEPTION 'TEST_FAILED: exact retry not recognized';
    END IF;

    BEGIN
        PERFORM public.assign_existing_user_to_company(
            '00000000-0000-0000-0000-000000123001',v_actor,
            'CASHIER','00000000-0000-0000-0000-000000123012'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='STORE_NOT_IN_COMPANY' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Store accepted';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.user_company_assignment_audit audit
    WHERE audit.target_user_id=v_actor
      AND audit.company_id IN(
        '00000000-0000-0000-0000-000000123001',
        '00000000-0000-0000-0000-000000123002'
      );
    IF v_count<>3 THEN
        RAISE EXCEPTION 'TEST_FAILED: assignment audit count invalid';
    END IF;

    IF has_table_privilege(
        'authenticated','public.company_memberships','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.store_memberships','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.user_company_assignment_audit',
        'INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.assign_existing_user_to_company(uuid,uuid,text,uuid)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: assignment privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: existing identity assignment is tenant-safe, role-scoped, retry-safe, and audited.';
END
$test$;

ROLLBACK;
