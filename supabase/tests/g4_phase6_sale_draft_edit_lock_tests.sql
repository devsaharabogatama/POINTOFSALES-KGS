-- G4 phase 6 behavior: Draft lock, heartbeat, takeover, list, and cancel.
-- SAFETY: every fixture and mutation is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_result JSONB;
    v_rejected BOOLEAN;
    v_count BIGINT;
    v_customer UUID;
BEGIN
    SELECT p.id INTO v_actor
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::public.user_role
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES (
        '00000000-0000-0000-0000-000000056001',
        'G56A','G56 Company A','g56-company-a','ACTIVE'
    );
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES (
        '00000000-0000-0000-0000-000000056011',
        '00000000-0000-0000-0000-000000056001',
        'S1','G56 Store','ACTIVE'
    );
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES
        (
            '00000000-0000-0000-0000-000000056021',
            '00000000-0000-0000-0000-000000056001',
            '00000000-0000-0000-0000-000000056011',
            'POS1','G56 POS 1','ACTIVE'
        ),
        (
            '00000000-0000-0000-0000-000000056022',
            '00000000-0000-0000-0000-000000056001',
            '00000000-0000-0000-0000-000000056011',
            'POS2','G56 POS 2','ACTIVE'
        );
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,
        is_sale_source,is_purchase_destination,is_active
    ) VALUES (
        '00000000-0000-0000-0000-000000056031',
        '00000000-0000-0000-0000-000000056001',
        'SWA','G56 Warehouse','STORE',
        '00000000-0000-0000-0000-000000056011',
        TRUE,FALSE,TRUE
    );
    SELECT id INTO v_customer
    FROM public.customers
    WHERE company_id = '00000000-0000-0000-0000-000000056001'
      AND is_system_customer
      AND upper(btrim(code)) = 'WALK-IN';
    IF v_customer IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Walk-In not provisioned';
    END IF;
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,opening_balance,expected_cash,
        actual_cash,difference,status,company_id,store_id,pos_id,
        sales_warehouse_id,opening_cash_actual
    ) VALUES (
        '00000000-0000-0000-0000-000000056051',
        'G56-SESSION-1',v_actor,0,0,0,0,'OPEN',
        '00000000-0000-0000-0000-000000056001',
        '00000000-0000-0000-0000-000000056011',
        '00000000-0000-0000-0000-000000056021',
        '00000000-0000-0000-0000-000000056031',0
    );
    INSERT INTO public.sales_headers(
        id,invoice_no,session_id,customer_id,created_by,payload_snapshot,
        company_id,store_id,pos_id,sales_warehouse_id
    ) VALUES (
        '00000000-0000-0000-0000-000000056061',
        'G56-DRAFT',
        '00000000-0000-0000-0000-000000056051',
        v_customer,
        v_actor,'{"items":[]}'::jsonb,
        '00000000-0000-0000-0000-000000056001',
        '00000000-0000-0000-0000-000000056011',
        '00000000-0000-0000-0000-000000056021',
        '00000000-0000-0000-0000-000000056031'
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(
        '00000000-0000-0000-0000-000000056001','G4_PHASE6_TEST'
    );

    v_result := public.acquire_pos_sale_draft_lock(
        '00000000-0000-0000-0000-000000056061',
        '00000000-0000-0000-0000-000000056051',FALSE
    );
    IF v_result->>'action' <> 'LOCK_ACQUIRE' THEN
        RAISE EXCEPTION 'TEST_FAILED: initial lock not acquired';
    END IF;

    v_result := public.heartbeat_pos_sale_draft_lock(
        '00000000-0000-0000-0000-000000056061',
        '00000000-0000-0000-0000-000000056051'
    );
    IF v_result->>'lockHeartbeatAt' IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: heartbeat missing';
    END IF;

    SELECT jsonb_array_length(public.list_pos_sale_drafts(
        '00000000-0000-0000-0000-000000056011'
    )) INTO v_count;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft list expected one row';
    END IF;

    UPDATE public.sales_headers
    SET edit_lock_acquired_at =
            clock_timestamp() - interval '10 minutes',
        edit_lock_heartbeat_at =
            clock_timestamp() - interval '6 minutes'
    WHERE id = '00000000-0000-0000-0000-000000056061';
    UPDATE public.cashier_sessions
    SET status = 'CLOSED'::public.session_status,
        closed_at = clock_timestamp(),
        closing_cash_actual = 0
    WHERE id = '00000000-0000-0000-0000-000000056051';
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,opening_balance,expected_cash,
        actual_cash,difference,status,company_id,store_id,pos_id,
        sales_warehouse_id,opening_cash_actual
    ) VALUES (
        '00000000-0000-0000-0000-000000056052',
        'G56-SESSION-2',v_actor,0,0,0,0,'OPEN',
        '00000000-0000-0000-0000-000000056001',
        '00000000-0000-0000-0000-000000056011',
        '00000000-0000-0000-0000-000000056022',
        '00000000-0000-0000-0000-000000056031',0
    );

    v_rejected := FALSE;
    BEGIN
        PERFORM public.acquire_pos_sale_draft_lock(
            '00000000-0000-0000-0000-000000056061',
            '00000000-0000-0000-0000-000000056052',FALSE
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'SALE_DRAFT_TAKEOVER_CONFIRMATION_REQUIRED' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: stale takeover lacked confirmation';
    END IF;

    v_result := public.acquire_pos_sale_draft_lock(
        '00000000-0000-0000-0000-000000056061',
        '00000000-0000-0000-0000-000000056052',TRUE
    );
    IF v_result->>'action' <> 'LOCK_TAKEOVER' THEN
        RAISE EXCEPTION 'TEST_FAILED: stale lock was not taken over';
    END IF;

    v_result := public.cancel_pos_sale_draft(
        '00000000-0000-0000-0000-000000056061',1,
        '00000000-0000-0000-0000-000000056052','Customer canceled'
    );
    IF v_result->>'documentStatus' <> 'CANCELED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft not canceled';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.sale_master_audit
    WHERE sales_id = '00000000-0000-0000-0000-000000056061'
      AND action IN ('LOCK_ACQUIRE','LOCK_TAKEOVER','CANCEL_DRAFT');
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: lifecycle audit incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.sales_payments
        WHERE sales_id = '00000000-0000-0000-0000-000000056061'
    ) OR EXISTS (
        SELECT 1 FROM public.stock_movements
        WHERE reference_table = 'sales_headers'
          AND reference_id = '00000000-0000-0000-0000-000000056061'
    ) OR EXISTS (
        SELECT 1 FROM public.financial_events
        WHERE source_table = 'sales_headers'
          AND source_id = '00000000-0000-0000-0000-000000056061'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft lifecycle wrote final effect';
    END IF;

    RAISE NOTICE
        'TEST PASSED: Draft list, heartbeat, confirmed stale takeover, cancel, audit, and no-final-effect contract are enforced.';
END
$test$;

ROLLBACK;
