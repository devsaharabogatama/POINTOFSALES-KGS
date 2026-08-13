-- G4 phase 49 behavior: Customer Balance correction ledger foundation.
-- SAFETY: all fixtures, balance, ledger, events, and audit are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID; v_reviewer UUID;
    v_company UUID:='00000000-0000-0000-0000-000000079001';
    v_company_b UUID:='00000000-0000-0000-0000-000000079002';
    v_store UUID:='00000000-0000-0000-0000-000000079011';
    v_customer UUID:='00000000-0000-0000-0000-000000079021';
    v_category UUID; v_request UUID; v_entry UUID; v_result JSONB;
    v_count BIGINT; v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    SELECT profile.id INTO v_reviewer
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.id<>v_actor ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL OR v_reviewer IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: two linked users required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
      (v_company,'G79','G79 Balance Company','g79-balance-company','ACTIVE'),
      (v_company_b,'G79B','G79 Company B','g79-company-b','ACTIVE');
    INSERT INTO public.company_memberships(
        company_id,user_id,role_code,status,is_default_company
    ) VALUES
      (v_company,v_actor,'FINANCE','ACTIVE',FALSE),
      (v_company,v_reviewer,'COMPANY_ADMIN','ACTIVE',FALSE),
      (v_company_b,v_actor,'FINANCE','ACTIVE',FALSE)
    ON CONFLICT(company_id,user_id) DO UPDATE SET
        role_code=excluded.role_code,status=excluded.status;
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES(v_store,v_company,'G79S','G79 Store','ACTIVE');
    SELECT id INTO v_category FROM public.customer_categories
    WHERE company_id=v_company AND is_system_category ORDER BY id LIMIT 1;
    INSERT INTO public.customers(
        id,company_id,code,name,customer_category_id,customer_type,
        current_balance,credit_limit,is_active,is_system_customer
    ) VALUES(
        v_customer,v_company,'G79-CUST','G79 Customer',v_category,
        'INDIVIDUAL',0,0,TRUE,FALSE
    );
    -- G1 does not provision feature rows for a newly inserted synthetic
    -- Company. Upsert the rollback-only entitlement fixture explicitly so the
    -- Phase-49 lifecycle trigger receives an INSERT as well as an UPDATE.
    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,config,updated_by
    ) VALUES
      (v_company,'customer_balance_enabled',TRUE,'{}'::JSONB,v_actor),
      (v_company_b,'customer_balance_enabled',TRUE,'{}'::JSONB,v_actor)
    ON CONFLICT(company_id,feature_code) DO UPDATE SET
        is_enabled=excluded.is_enabled,config=excluded.config,
        updated_by=excluded.updated_by,updated_at=clock_timestamp();

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE49_TEST');

    v_result:=public.request_customer_balance_correction(
        v_customer,v_store,'CREDIT',100,'CASH_DRAWER',
        'Customer deposit correction','https://example.invalid/deposit.jpg',
        '00000000-0000-0000-0000-000000079031'
    );
    v_request:=(v_result->>'correctionRequestId')::UUID;
    IF v_result->>'status'<>'SUBMITTED' THEN
        RAISE EXCEPTION 'TEST_FAILED: correction request not submitted';
    END IF;
    v_result:=public.request_customer_balance_correction(
        v_customer,v_store,'CREDIT',100,'CASH_DRAWER',
        'Customer deposit correction','https://example.invalid/deposit.jpg',
        '00000000-0000-0000-0000-000000079031'
    );
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: request retry not idempotent';
    END IF;
    IF (SELECT current_balance FROM public.customers WHERE id=v_customer)<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: request changed balance before approval';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.review_customer_balance_correction(
            v_request,1,'APPROVE',NULL,
            '00000000-0000-0000-0000-000000079032'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='MAKER_CANNOT_REVIEW_OWN_CUSTOMER_BALANCE_CORRECTION' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: maker approved own correction';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_reviewer,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE49_REVIEW');
    v_result:=public.review_customer_balance_correction(
        v_request,1,'APPROVE',NULL,
        '00000000-0000-0000-0000-000000079032'
    );
    IF v_result->>'status'<>'APPROVED'
       OR (v_result->>'balanceAfter')::NUMERIC<>100 THEN
        RAISE EXCEPTION 'TEST_FAILED: credit correction approval invalid';
    END IF;
    v_result:=public.review_customer_balance_correction(
        v_request,1,'APPROVE',NULL,
        '00000000-0000-0000-0000-000000079032'
    );
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: review retry not idempotent';
    END IF;
    SELECT count(*) INTO v_count FROM public.customer_balance_ledger_entries
    WHERE company_id=v_company AND customer_id=v_customer;
    IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: expected one ledger entry'; END IF;
    SELECT count(*) INTO v_count FROM public.financial_events
    WHERE company_id=v_company
      AND event_type='CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type
      AND status='HOLD'::public.event_status;
    IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: credit HOLD event missing'; END IF;

    -- Disabling with liability moves policy to WIND_DOWN, not hard disabled.
    -- ACP must retain the authorized role's restricted capabilities during
    -- WIND_DOWN so the outstanding liability can be settled.
    UPDATE public.company_features SET is_enabled=FALSE,updated_by=v_reviewer
    WHERE company_id=v_company
      AND feature_code='customer_balance_enabled';
    IF (SELECT lifecycle_state FROM public.customer_balance_company_policies
        WHERE company_id=v_company)<>'WIND_DOWN' THEN
        RAISE EXCEPTION 'TEST_FAILED: outstanding disable did not wind down';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE49_TEST');
    v_result:=public.resolve_user_permission(
        v_company,v_actor,'finance.customer_balances'
    );
    IF NOT ((v_result->'effectiveCapabilities') ? 'MANAGE')
       OR COALESCE((v_result->>'historyOnly')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION
            'TEST_FAILED: WIND_DOWN ACP capability contract invalid: %',
            v_result;
    END IF;
    v_result:=public.request_customer_balance_correction(
        v_customer,v_store,'DEBIT',100,'CUSTOMER_RECEIVABLE',
        'Customer liability settlement',NULL,
        '00000000-0000-0000-0000-000000079033'
    );
    v_request:=(v_result->>'correctionRequestId')::UUID;
    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_reviewer,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE49_REVIEW');
    v_result:=public.review_customer_balance_correction(
        v_request,1,'APPROVE',NULL,
        '00000000-0000-0000-0000-000000079034'
    );
    IF (v_result->>'balanceAfter')::NUMERIC<>0
       OR (SELECT lifecycle_state FROM public.customer_balance_company_policies
           WHERE company_id=v_company)<>'DISABLED' THEN
        RAISE EXCEPTION 'TEST_FAILED: wind-down did not close at zero';
    END IF;
    IF (SELECT current_balance FROM public.customers WHERE id=v_customer)<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: Customer cache did not return to zero';
    END IF;

    v_result:=public.resolve_user_permission(
        v_company,v_reviewer,'finance.customer_balances'
    );
    IF NOT COALESCE((v_result->>'historyOnly')::BOOLEAN,FALSE)
       OR NOT ((v_result->'effectiveCapabilities') ? 'VIEW')
       OR NOT ((v_result->'effectiveCapabilities') ? 'EXPORT')
       OR ((v_result->'effectiveCapabilities') ? 'MANAGE') THEN
        RAISE EXCEPTION
            'TEST_FAILED: disabled-history ACP capability contract invalid: %',
            v_result;
    END IF;
    v_result:=public.get_customer_balance_statement(v_customer,NULL,NULL);
    IF jsonb_array_length(v_result->'entries')<>2
       OR (v_result->>'currentBalance')::NUMERIC<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: statement ledger invalid';
    END IF;

    v_rejected:=FALSE;
    SELECT id INTO v_entry FROM public.customer_balance_ledger_entries
    WHERE company_id=v_company ORDER BY entry_no LIMIT 1;
    BEGIN
        UPDATE public.customer_balance_ledger_entries SET reason='tamper'
        WHERE id=v_entry;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='CUSTOMER_BALANCE_HISTORY_IMMUTABLE' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: ledger mutable'; END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_b,'G4_PHASE49_CROSS');
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.get_customer_balance_statement(v_customer,NULL,NULL);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company statement visible'; END IF;

    IF has_table_privilege('authenticated','public.customer_balance_ledger_entries','INSERT,UPDATE,DELETE')
       OR has_table_privilege('authenticated','public.customer_balance_correction_requests','INSERT,UPDATE,DELETE')
       OR has_column_privilege('authenticated','public.customers','current_balance','UPDATE') THEN
        RAISE EXCEPTION 'TEST_FAILED: browser write boundary open';
    END IF;

    RAISE NOTICE 'TEST PASSED: Customer Balance correction is tenant-safe, append-only, idempotent, maker-checker guarded, lifecycle-aware, cache-reconciled, and Finance-HOLD only.';
END
$test$;

ROLLBACK;
