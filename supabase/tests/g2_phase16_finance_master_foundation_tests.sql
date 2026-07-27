-- G2 phase 16 behavioral test: tenant COA and versioned category mapping.
-- SAFETY: every Company, master, rule, and audit fixture is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_category UUID;
    v_rule UUID;
    v_expense_account UUID;
    v_foreign_account UUID;
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
        ('00000000-0000-0000-0000-000000016001',
         'G16A','G16 Company A','g16-company-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000016002',
         'G16B','G16 Company B','g16-company-b','ACTIVE');

    SELECT count(*) INTO v_count FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000016001'
      AND is_system_account;
    IF v_count < 36 THEN
        RAISE EXCEPTION 'TEST_FAILED: minimum COA provisioned only % rows',v_count;
    END IF;

    SELECT id INTO v_expense_account FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000016001'
      AND system_function_key = 'EXPENSE';
    SELECT id INTO v_foreign_account FROM public.chart_of_accounts
    WHERE company_id = '00000000-0000-0000-0000-000000016002'
      AND system_function_key = 'EXPENSE';

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000016001','G2_PHASE16_TEST'
    );

    v_result := public.save_transaction_category(
        NULL,NULL,'OPS','Operasional','EXPENSE_SETTLEMENT',
        'Biaya operasional',TRUE
    );
    v_category := (v_result->>'categoryId')::UUID;

    v_result := public.save_transaction_account_rule(
        NULL,v_category,'EXPENSE',v_expense_account,
        '2026-01-01 00:00:00+00',NULL,'ACTIVE'
    );
    v_rule := (v_result->>'ruleId')::UUID;
    IF (v_result->>'ruleVersion')::BIGINT <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: first rule version is not 1';
    END IF;

    SELECT count(*) INTO v_count FROM public.finance_master_audit
    WHERE company_id = '00000000-0000-0000-0000-000000016001'
      AND entity_id IN (v_category,v_rule);
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two audit rows, got %',v_count;
    END IF;

    v_result := public.save_transaction_account_rule(
        NULL,v_category,'EXPENSE',v_expense_account,
        '2026-06-01 00:00:00+00',NULL,'ACTIVE'
    );
    IF (v_result->>'ruleVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: replacement rule version is not 2';
    END IF;
    SELECT count(*) INTO v_count FROM public.transaction_account_rules
    WHERE id = v_rule
      AND effective_to = '2026-06-01 00:00:00+00'::TIMESTAMPTZ;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: prior rule period was not closed';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_transaction_account_rule(
            NULL,v_category,'EXPENSE',v_foreign_account,
            '2027-01-01 00:00:00+00',NULL,'ACTIVE'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_POSTABLE_ACCOUNT_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company account accepted';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_transaction_category(
            v_category,1,'OPS','Operasional','EXPENSE_DISBURSEMENT',
            'Biaya operasional',TRUE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'CATEGORY_SYSTEM_EVENT_LOCKED_BY_HISTORY' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: used Category changed System Event';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_transaction_account_rule(
            v_rule,v_category,'EXPENSE',v_expense_account,
            '2026-01-01 00:00:00+00',NULL,'INACTIVE'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_TRANSACTION_RULE_IMMUTABLE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: active mapping mutated in place';
    END IF;

    IF has_table_privilege(
        'authenticated','public.chart_of_accounts','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.transaction_account_rules','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_transaction_category(uuid,bigint,text,text,text,text,boolean)',
        'EXECUTE'
    ) OR has_function_privilege(
        'authenticated','public.process_financial_events_queue()','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Finance privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: minimum COA is provisioned and Transaction Category mapping is tenant-safe, versioned, audited, and posting remains disabled.';
END
$test$;

ROLLBACK;
