-- G2 phase 19 regression test: table-specific Finance history trigger fields.
-- SAFETY: all Company/category/COA/audit changes are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_category UUID;
    v_version BIGINT;
    v_account UUID;
    v_result JSONB;
    v_count BIGINT;
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
        '00000000-0000-0000-0000-000000019001',
        'G19A','G19 Company A','g19-company-a','ACTIVE'
    );

    SELECT id,master_version INTO v_category,v_version
    FROM public.transaction_categories
    WHERE company_id = '00000000-0000-0000-0000-000000019001'
      AND system_key = 'EXPENSE_SETTLEMENT'
      AND is_system_default;

    SELECT id INTO v_account
    FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000019001'
      AND system_function_key = 'EXPENSE';

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000019001','G2_PHASE19_TEST'
    );

    -- Regression: this update previously attempted NEW.account_type on a
    -- transaction_categories record and failed with SQLSTATE 42703.
    v_result := public.save_transaction_category(
        v_category,v_version,'DEFAULT-EXPENSE-SETTLEMENT',
        'Beban Operasional Default','EXPENSE_SETTLEMENT',
        'Regression category update',TRUE
    );
    IF (v_result->>'masterVersion')::BIGINT <> v_version + 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Category update version invalid';
    END IF;

    -- Exercise the COA branch independently. It must not attempt to read
    -- category-only fields such as system_key.
    UPDATE public.chart_of_accounts
    SET account_name = 'Beban Operasional Regression'
    WHERE company_id = '00000000-0000-0000-0000-000000019001'
      AND id = v_account;

    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000019001'
      AND id = v_account
      AND account_name = 'Beban Operasional Regression';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: COA branch update did not persist';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.transaction_categories
    WHERE company_id = '00000000-0000-0000-0000-000000019001'
      AND is_system_default AND is_active;
    IF v_count <> 26 THEN
        RAISE EXCEPTION 'TEST_FAILED: required category coverage changed';
    END IF;

    RAISE NOTICE 'TEST PASSED: Finance history guard isolates Transaction Category and COA fields correctly.';
END
$test$;

ROLLBACK;
