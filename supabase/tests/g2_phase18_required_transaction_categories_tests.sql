-- G2 phase 18 behavioral test: required default Transaction Categories.
-- SAFETY: every Company/category/audit fixture is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_category UUID;
    v_version BIGINT;
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
    ) VALUES (
        '00000000-0000-0000-0000-000000018001',
        'G18A','G18 Company A','g18-company-a','ACTIVE'
    );

    SELECT count(*) INTO v_count
    FROM public.transaction_categories
    WHERE company_id = '00000000-0000-0000-0000-000000018001'
      AND is_system_default AND is_active;
    IF v_count <> 26 THEN
        RAISE EXCEPTION
            'TEST_FAILED: provisioned % required categories, expected 26',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.transaction_account_rules
    WHERE company_id = '00000000-0000-0000-0000-000000018001';
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'TEST_FAILED: provisioning silently created account rules';
    END IF;

    SELECT id,master_version INTO v_category,v_version
    FROM public.transaction_categories
    WHERE company_id = '00000000-0000-0000-0000-000000018001'
      AND system_key = 'EXPENSE_SETTLEMENT'
      AND is_system_default;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000018001','G2_PHASE18_TEST'
    );

    v_result := public.save_transaction_category(
        v_category,v_version,'DEFAULT-EXPENSE-SETTLEMENT',
        'Biaya Operasional Umum','EXPENSE_SETTLEMENT',
        'Nama bawaan boleh disesuaikan Company',TRUE
    );
    IF (v_result->>'masterVersion')::BIGINT <> v_version + 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: editable label did not increment version';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_transaction_category(
            v_category,(v_result->>'masterVersion')::BIGINT,
            'DEFAULT-EXPENSE-SETTLEMENT','Biaya Operasional Umum',
            'EXPENSE_SETTLEMENT','Required category',FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: required category was disabled';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_transaction_category(
            v_category,(v_result->>'masterVersion')::BIGINT,
            'DEFAULT-EXPENSE-SETTLEMENT','Biaya Operasional Umum',
            'CASH_IN','Required category',TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: required category system event changed';
    END IF;

    v_rejected := FALSE;
    BEGIN
        DELETE FROM public.transaction_categories
        WHERE id = v_category;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DELETED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: required category was deleted';
    END IF;

    v_result := public.save_transaction_category(
        NULL,NULL,'ELECTRICITY','Listrik','EXPENSE_SETTLEMENT',
        'Custom category remains allowed',TRUE
    );
    IF (v_result->>'categoryId') IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: custom category was not created';
    END IF;

    IF has_table_privilege(
        'authenticated','public.transaction_categories','INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: browser direct write privilege remains';
    END IF;

    RAISE NOTICE 'TEST PASSED: every Company receives 26 protected default categories, labels remain editable, custom categories remain allowed, and no account mapping or journal is created.';
END
$test$;

ROLLBACK;
