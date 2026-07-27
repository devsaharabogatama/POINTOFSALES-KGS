-- G2 phase 8 behavioral test: Customer Category and Customer guarded writes.
-- SAFETY: every fixture and audit row is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_general_a UUID;
    v_general_b UUID;
    v_category UUID;
    v_customer UUID;
    v_walk_in UUID;
    v_result JSONB;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000014001',
         'G14A','G14 Company A','g14-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000014002',
         'G14B','G14 Company B','g14-company-b','ACTIVE');

    SELECT id INTO v_general_a FROM public.customer_categories
    WHERE company_id = '00000000-0000-0000-0000-000000014001'
      AND is_system_category;
    SELECT id INTO v_general_b FROM public.customer_categories
    WHERE company_id = '00000000-0000-0000-0000-000000014002'
      AND is_system_category;
    SELECT id INTO v_walk_in FROM public.customers
    WHERE company_id = '00000000-0000-0000-0000-000000014001'
      AND is_system_customer;

    IF v_general_a IS NULL OR v_general_b IS NULL OR v_walk_in IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: Company defaults were not provisioned';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.customers
    WHERE company_id IN (
        '00000000-0000-0000-0000-000000014001',
        '00000000-0000-0000-0000-000000014002'
    ) AND is_system_customer
      AND code = 'WALK-IN'
      AND customer_type = 'WALK_IN'
      AND current_balance = 0;
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two valid Walk-In rows, got %',v_count;
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000014001','G2_PHASE8_TEST'
    );

    v_result := public.save_customer_category(
        NULL,NULL,'RETAIL','Retail',TRUE
    );
    v_category := (v_result->>'customerCategoryId')::UUID;

    v_result := public.save_customer_category(
        v_category,1,'RETAIL','Retail Customer',TRUE
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category version did not increment';
    END IF;

    v_result := public.save_customer(
        NULL,NULL,NULL,'Customer Alpha',v_category,
        '0800','ALPHA@EXAMPLE.INVALID','Address','BUSINESS',
        1000,30,'Test Customer',TRUE
    );
    v_customer := (v_result->>'customerId')::UUID;
    IF v_result->>'customerCode' <> 'CUST-000001' THEN
        RAISE EXCEPTION
            'TEST_FAILED: generated Customer code %',v_result->>'customerCode';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.customers
    WHERE id = v_customer
      AND company_id = '00000000-0000-0000-0000-000000014001'
      AND customer_category_id = v_category
      AND email = 'alpha@example.invalid'
      AND current_balance = 0
      AND credit_limit = 1000
      AND credit_term_days = 30
      AND master_version = 1;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical Customer row invalid';
    END IF;

    SELECT count(*) INTO v_count FROM public.customer_master_audit
    WHERE customer_id = v_customer AND action = 'CREATE';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer create audit missing';
    END IF;

    v_result := public.save_customer(
        v_customer,1,'CUST-ALPHA','Customer Alpha Updated',v_category,
        '0801','alpha@example.invalid','New Address','BUSINESS',
        2000,45,NULL,TRUE
    );
    IF (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer version did not increment';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_customer(
            v_customer,1,'CUST-ALPHA','Stale Customer',v_category,
            NULL,NULL,NULL,'INDIVIDUAL',0,NULL,NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale Customer update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_customer(
            v_walk_in,1,'WALK-IN','Changed Walk-In',v_general_a,
            NULL,NULL,NULL,'INDIVIDUAL',0,NULL,NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'SYSTEM_CUSTOMER_IMMUTABLE' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: system Walk-In update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_customer(
            NULL,NULL,NULL,'Cross Company Category',v_general_b,
            NULL,NULL,NULL,'INDIVIDUAL',0,NULL,NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company Category accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_customer(
            NULL,NULL,NULL,'Customer Alpha Updated',v_category,
            NULL,NULL,NULL,'INDIVIDUAL',0,NULL,NULL,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'DUPLICATE_CUSTOMER' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate normalized Customer accepted';
    END IF;

    IF has_table_privilege(
        'authenticated','public.customers','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.customer_categories','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Customer defaults and guarded Category/Customer writes are tenant-safe, versioned, audited, and balance-immutable.';
END
$test$;

ROLLBACK;
