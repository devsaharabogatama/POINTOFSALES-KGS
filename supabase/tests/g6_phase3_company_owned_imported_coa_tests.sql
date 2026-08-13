-- G6 phase 3 imported-COA ownership correction behavior.
-- SAFETY: every fixture is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_rejected BOOLEAN := FALSE;
    v_count BIGINT;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id = profile.id
    WHERE profile.role::TEXT = 'super_admin'
    ORDER BY profile.id
    LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES (
        '00000000-0000-0000-0000-000000018501',
        'G6COWN','G6 Company-owned COA','g6-company-owned-coa','ACTIVE'
    );

    BEGIN
        INSERT INTO public.chart_of_accounts(
            company_id,account_code,account_name,account_type,normal_balance,
            system_function_key,is_system_account,is_postable,is_active,
            created_by,updated_by
        ) VALUES (
            '00000000-0000-0000-0000-000000018501',
            'G6-SYS-DUP','G6 Duplicate System COGS','COGS','DEBIT','COGS',
            TRUE,TRUE,TRUE,v_actor,v_actor
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'SYSTEM_FUNCTION_ACCOUNT_ALREADY_EXISTS' THEN
            v_rejected := TRUE;
        ELSE
            RAISE;
        END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: duplicate system function account accepted';
    END IF;

    INSERT INTO public.chart_of_accounts(
        company_id,account_code,account_name,account_type,normal_balance,
        system_function_key,is_system_account,is_postable,is_active,
        created_by,updated_by
    ) VALUES (
        '00000000-0000-0000-0000-000000018501',
        'G6-COMPANY-COGS','G6 Company COGS','COGS','DEBIT','COGS',
        FALSE,TRUE,TRUE,v_actor,v_actor
    );

    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts account
    WHERE account.company_id =
              '00000000-0000-0000-0000-000000018501'
      AND account.system_function_key = 'COGS'
      AND account.is_system_account;
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected one canonical system COGS, got %',v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.chart_of_accounts account
    WHERE account.company_id =
              '00000000-0000-0000-0000-000000018501'
      AND account.account_code = 'G6-COMPANY-COGS'
      AND NOT account.is_system_account
      AND account.system_function_key = 'COGS';
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Company-owned function account missing';
    END IF;

    RAISE NOTICE 'TEST PASSED: imported-style COA remains Company-owned and duplicate system ownership is rejected.';
END
$test$;

ROLLBACK;
