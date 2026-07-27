-- G2 phase 20 behavioral test: guarded COA and versioned Company fallback.
-- SAFETY: all Company/account/fallback/audit fixtures are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_root UUID;
    v_level2 UUID;
    v_level3 UUID;
    v_foreign_account UUID;
    v_expense_account UUID;
    v_first_fallback UUID;
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
        ('00000000-0000-0000-0000-000000020001',
         'G20A','G20 Company A','g20-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000020002',
         'G20B','G20 Company B','g20-company-b','ACTIVE');

    SELECT id INTO v_expense_account
    FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000020001'
      AND system_function_key = 'EXPENSE';
    SELECT id INTO v_foreign_account
    FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000020002'
      AND system_function_key = 'EXPENSE';

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000020001','G2_PHASE20_TEST'
    );

    v_result := public.save_chart_of_account(
        NULL,NULL,'6000','Beban Operasional','EXPENSE','DEBIT',
        NULL,NULL,FALSE,FALSE,FALSE,TRUE
    );
    v_root := (v_result->>'accountId')::UUID;

    v_result := public.save_chart_of_account(
        NULL,NULL,'6010','Beban Utilitas','EXPENSE','DEBIT',
        v_root,NULL,FALSE,FALSE,FALSE,TRUE
    );
    v_level2 := (v_result->>'accountId')::UUID;

    v_result := public.save_chart_of_account(
        NULL,NULL,'6011','Beban Listrik','EXPENSE','DEBIT',
        v_level2,'EXPENSE',TRUE,TRUE,FALSE,TRUE
    );
    v_level3 := (v_result->>'accountId')::UUID;

    v_result := public.save_chart_of_account(
        v_level3,1,'6011','Beban Listrik','EXPENSE','DEBIT',
        v_level2,'EXPENSE',FALSE,FALSE,FALSE,TRUE
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_chart_of_account(
            NULL,NULL,'6012','Beban Listrik Detail','EXPENSE','DEBIT',
            v_level3,'EXPENSE',TRUE,FALSE,FALSE,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'COA_HIERARCHY_MAX_DEPTH_EXCEEDED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: fourth COA hierarchy level accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_chart_of_account(
            v_root,0,'6000','Stale Parent','EXPENSE','DEBIT',
            NULL,NULL,FALSE,FALSE,FALSE,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'MASTER_VERSION_CONFLICT' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale COA update accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_chart_of_account(
            NULL,NULL,'6020','Cross Company Child','EXPENSE','DEBIT',
            v_foreign_account,NULL,TRUE,FALSE,FALSE,TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'PARENT_ACCOUNT_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company parent accepted';
    END IF;

    v_result := public.save_company_account_function_fallback(
        NULL,'EXPENSE',v_expense_account,
        '2026-01-01 00:00:00+00',NULL,'ACTIVE'
    );
    v_first_fallback := (v_result->>'fallbackId')::UUID;
    IF (v_result->>'fallbackVersion')::BIGINT <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: first fallback version invalid';
    END IF;

    v_result := public.save_company_account_function_fallback(
        NULL,'EXPENSE',v_expense_account,
        '2026-06-01 00:00:00+00',NULL,'ACTIVE'
    );
    IF (v_result->>'fallbackVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: replacement fallback version invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.company_account_function_fallbacks
    WHERE id = v_first_fallback
      AND effective_to = '2026-06-01 00:00:00+00'::TIMESTAMPTZ;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: prior fallback period not closed';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_company_account_function_fallback(
            NULL,'EXPENSE',v_foreign_account,
            '2027-01-01 00:00:00+00',NULL,'ACTIVE'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_POSTABLE_ACCOUNT_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company fallback account accepted';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.finance_master_audit
    WHERE company_id = '00000000-0000-0000-0000-000000020001'
      AND entity_type IN ('ACCOUNT','FALLBACK');
    IF v_count < 7 THEN
        RAISE EXCEPTION 'TEST_FAILED: Finance master audit incomplete';
    END IF;

    IF has_table_privilege(
        'authenticated','public.chart_of_accounts','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.company_account_function_fallbacks',
        'INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: direct Finance master write remains';
    END IF;

    RAISE NOTICE 'TEST PASSED: COA is tenant-safe, hierarchical, versioned, audited, and Company fallback replacement preserves history.';
END
$test$;

ROLLBACK;
