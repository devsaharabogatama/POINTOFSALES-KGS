-- G6 corrective phase 3 behavioral test.
-- SAFETY: all fixtures and mapping writes are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_result JSONB;
    v_rule_set UUID;
    v_missing_set UUID;
    v_inventory_account UUID;
    v_opening_account UUID;
    v_event_count BIGINT;
    v_journal_count BIGINT;
    v_count BIGINT;
    v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id = profile.id
    WHERE profile.role::TEXT = 'super_admin'
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;
    SELECT count(*) INTO v_event_count FROM public.financial_events;
    SELECT count(*) INTO v_journal_count FROM public.finance_journals;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
        ('00000000-0000-0000-0000-000000019001',
         'G6MA','G6 Mapping A','g6-mapping-a','ACTIVE'),
        ('00000000-0000-0000-0000-000000019002',
         'G6MB','G6 Mapping B','g6-mapping-b','ACTIVE');

    INSERT INTO public.transaction_categories(
        id,company_id,category_code,category_name,system_key,is_active
    ) VALUES
        ('00000000-0000-0000-0000-000000019011',
         '00000000-0000-0000-0000-000000019001',
         'G6-OPEN-A','G6 Opening A','STOCK_OPENING',TRUE),
        ('00000000-0000-0000-0000-000000019012',
         '00000000-0000-0000-0000-000000019002',
         'G6-OPEN-B','G6 Opening B','STOCK_OPENING',TRUE);

    -- Company provisioning already creates these canonical system accounts.
    -- Reuse them because duplicate system ownership is now correctly blocked.
    SELECT account.id INTO v_inventory_account
    FROM public.chart_of_accounts account
    WHERE account.company_id =
              '00000000-0000-0000-0000-000000019001'
      AND account.system_function_key = 'INVENTORY_ASSET'
      AND account.is_system_account
      AND account.is_active
      AND account.is_postable;
    SELECT account.id INTO v_opening_account
    FROM public.chart_of_accounts account
    WHERE account.company_id =
              '00000000-0000-0000-0000-000000019001'
      AND account.system_function_key = 'OPENING_BALANCE_CLEARING'
      AND account.is_system_account
      AND account.is_active
      AND account.is_postable;
    IF v_inventory_account IS NULL OR v_opening_account IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: canonical fixture accounts missing';
    END IF;

    INSERT INTO public.transaction_account_rules(
        company_id,transaction_category_id,system_key,
        account_function_key,account_id,effective_from,rule_version,status,
        approved_by,approved_at,created_by,updated_by
    ) VALUES
        ('00000000-0000-0000-0000-000000019001',
         '00000000-0000-0000-0000-000000019011','STOCK_OPENING',
         'INVENTORY_ASSET',v_inventory_account,
         '2026-01-01T00:00:00Z',1,'ACTIVE',v_actor,clock_timestamp(),
         v_actor,v_actor),
        ('00000000-0000-0000-0000-000000019001',
         '00000000-0000-0000-0000-000000019011','STOCK_OPENING',
         'OPENING_BALANCE_CLEARING',
         v_opening_account,
         '2026-01-01T00:00:00Z',1,'ACTIVE',v_actor,clock_timestamp(),
         v_actor,v_actor);

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000019001','G6_PHASE3_TEST'
    );

    v_result := public.save_posting_rule_set(
        NULL,NULL,'00000000-0000-0000-0000-000000019011',
        '2026-01-01T00:00:00Z',NULL,'Opening Stock mapping',
        jsonb_build_array(
            jsonb_build_object(
                'lineNo',1,'accountFunctionKey','INVENTORY_ASSET',
                'entrySide','DEBIT',
                'amountExpressionKey','EVENT:INVENTORY_DEBIT',
                'isRequired',TRUE
            ),
            jsonb_build_object(
                'lineNo',2,
                'accountFunctionKey','OPENING_BALANCE_CLEARING',
                'entrySide','CREDIT',
                'amountExpressionKey','EVENT:OPENING_BALANCE_CREDIT',
                'isRequired',TRUE
            )
        )
    );
    v_rule_set := (v_result->>'postingRuleSetId')::UUID;
    IF (v_result->>'masterVersion')::BIGINT <> 1
       OR v_result->>'status' <> 'DRAFT' THEN
        RAISE EXCEPTION 'TEST_FAILED: new rule set state invalid';
    END IF;

    v_result := public.approve_posting_rule_set(v_rule_set,1);
    IF v_result->>'status' <> 'APPROVED'
       OR (v_result->>'masterVersion')::BIGINT <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: rule set approval invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.posting_rule_set_audit audit
    WHERE audit.rule_set_id = v_rule_set
      AND audit.action IN ('CREATE','APPROVE');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: mapping audit incomplete';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_posting_rule_set(
            v_rule_set,2,'00000000-0000-0000-0000-000000019011',
            '2026-01-01T00:00:00Z',NULL,'Forbidden edit',
            jsonb_build_array(
                jsonb_build_object(
                    'lineNo',1,'accountFunctionKey','INVENTORY_ASSET',
                    'entrySide','DEBIT','amountExpressionKey','EVENT:VALUE'
                ),
                jsonb_build_object(
                    'lineNo',2,
                    'accountFunctionKey','OPENING_BALANCE_CLEARING',
                    'entrySide','CREDIT','amountExpressionKey','EVENT:VALUE'
                )
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'APPROVED_POSTING_RULE_SET_IMMUTABLE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: approved mapping was editable';
    END IF;

    v_result := public.save_posting_rule_set(
        NULL,NULL,'00000000-0000-0000-0000-000000019011',
        '2027-01-01T00:00:00Z',NULL,'Missing required function',
        jsonb_build_array(
            jsonb_build_object(
                'lineNo',1,'accountFunctionKey','INVENTORY_ASSET',
                'entrySide','DEBIT','amountExpressionKey','EVENT:VALUE'
            ),
            jsonb_build_object(
                'lineNo',2,'accountFunctionKey','INVENTORY_ASSET',
                'entrySide','CREDIT','amountExpressionKey','EVENT:VALUE'
            )
        )
    );
    v_missing_set := (v_result->>'postingRuleSetId')::UUID;
    v_rejected := FALSE;
    BEGIN
        PERFORM public.approve_posting_rule_set(v_missing_set,1);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'POSTING_RULE_REQUIRED_FUNCTION_MISSING' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: incomplete mapping approved';
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.save_posting_rule_set(
            NULL,NULL,'00000000-0000-0000-0000-000000019012',
            '2026-01-01T00:00:00Z',NULL,'Cross Company',
            jsonb_build_array(
                jsonb_build_object(
                    'lineNo',1,'accountFunctionKey','INVENTORY_ASSET',
                    'entrySide','DEBIT','amountExpressionKey','EVENT:VALUE'
                ),
                jsonb_build_object(
                    'lineNo',2,
                    'accountFunctionKey','OPENING_BALANCE_CLEARING',
                    'entrySide','CREDIT','amountExpressionKey','EVENT:VALUE'
                )
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_TRANSACTION_CATEGORY_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company category accepted';
    END IF;

    IF has_table_privilege(
        'authenticated','public.posting_rule_sets','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.posting_rule_lines','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.posting_rule_set_audit','INSERT,UPDATE,DELETE'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: direct write boundary open'; END IF;
    IF NOT has_function_privilege(
        'authenticated',
        'public.save_posting_rule_set(uuid,bigint,uuid,timestamp with time zone,timestamp with time zone,text,jsonb)',
        'EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.approve_posting_rule_set(uuid,bigint)','EXECUTE'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: guarded RPC boundary invalid'; END IF;

    IF (SELECT count(*) FROM public.financial_events) <> v_event_count
       OR (SELECT count(*) FROM public.finance_journals) <> v_journal_count THEN
        RAISE EXCEPTION 'TEST_FAILED: Phase 3 changed event/journal runtime';
    END IF;
    RAISE NOTICE 'TEST PASSED: versioned posting mapping is tenant-safe, guarded, approved, immutable, audited, and has zero posting effect.';
END
$test$;

ROLLBACK;
