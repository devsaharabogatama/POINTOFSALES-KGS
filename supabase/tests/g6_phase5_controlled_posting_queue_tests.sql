-- G6 corrective phase 5 behavioral test: controlled historical queue.
-- SAFETY: all queue, event, journal, exception, and fixture rows roll back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company_a CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021001';
    v_company_b CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021002';
    v_warehouse CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021011';
    v_period CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021021';
    v_document_good CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021031';
    v_document_bad CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021032';
    v_event_good CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021041';
    v_event_bad CONSTANT UUID :=
        '00000000-0000-0000-0000-000000021042';
    v_category UUID;
    v_result JSONB;
    v_queue UUID;
    v_version BIGINT;
    v_count BIGINT;
    v_rejected BOOLEAN;
    v_event_at TIMESTAMPTZ;
    v_period_start DATE;
    v_period_end DATE;
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
    ) VALUES
        (v_company_a,'G6P5A','G6 Phase 5 A','g6-phase5-a','ACTIVE'),
        (v_company_b,'G6P5B','G6 Phase 5 B','g6-phase5-b','ACTIVE');
    v_event_at := clock_timestamp();
    v_period_start := date_trunc('month',v_event_at)::DATE;
    v_period_end := (
        v_period_start + INTERVAL '1 month' - INTERVAL '1 day'
    )::DATE;

    SELECT category.id INTO v_category
    FROM public.transaction_categories category
    WHERE category.company_id = v_company_a
      AND category.system_key = 'STOCK_OPENING'
      AND category.is_system_default;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: STOCK_OPENING category missing';
    END IF;

    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES (
        v_warehouse,v_company_a,'G6-P5-WH','G6 Phase 5 Warehouse','CENTRAL'
    );
    INSERT INTO public.accounting_periods(
        id,company_id,period_year,period_month,start_date,end_date,status,
        created_by,updated_by
    ) VALUES (
        v_period,v_company_a,extract(YEAR FROM v_period_start)::INTEGER,
        extract(MONTH FROM v_period_start)::INTEGER,
        v_period_start,v_period_end,'OPEN',v_actor,v_actor
    );

    INSERT INTO public.financial_events(
        id,event_code,event_type,source_table,source_id,event_date,
        event_version,idempotency_key,amounts,status,error_message,
        created_by,company_id,system_event_key,transaction_category_id
    ) VALUES
        (
            v_event_good,'G6-P5-GOOD','STOCK_OPENING'::public.event_type,
            'opening_stock_documents',v_document_good,v_event_at,1,
            'G6_PHASE5_GOOD|'||v_company_a::TEXT,
            jsonb_build_object(
                'inventoryDebit',100,'openingBalanceCredit',100,
                'warehouseId',v_warehouse,
                'financePostingState','HOLD_UNTIL_G6'
            ),'HOLD'::public.event_status,
            'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company_a,
            'STOCK_OPENING',v_category
        ),
        (
            v_event_bad,'G6-P5-BAD','STOCK_OPENING'::public.event_type,
            'opening_stock_documents',v_document_bad,v_event_at,1,
            'G6_PHASE5_BAD|'||v_company_a::TEXT,
            jsonb_build_object(
                'inventoryDebit',99,'openingBalanceCredit',99,
                'warehouseId',v_warehouse,
                'financePostingState','HOLD_UNTIL_G6'
            ),'HOLD'::public.event_status,
            'CANONICAL_FINANCE_POSTING_NOT_ENABLED',v_actor,v_company_a,
            'STOCK_OPENING',v_category
        );

    INSERT INTO public.opening_stock_documents(
        id,company_id,document_no,warehouse_id,effective_date,status,
        line_count,total_quantity_base,total_cost,posting_idempotency_key,
        financial_event_id,master_version,created_by,updated_by,
        posted_by,posted_at
    ) VALUES
        (
            v_document_good,v_company_a,'G6-P5-GOOD',v_warehouse,
            v_event_at::DATE,'POSTED',1,1,100,
            '00000000-0000-0000-0000-000000021051',v_event_good,1,
            v_actor,v_actor,v_actor,clock_timestamp()
        ),
        (
            v_document_bad,v_company_a,'G6-P5-BAD',v_warehouse,
            v_event_at::DATE,'POSTED',1,1,100,
            '00000000-0000-0000-0000-000000021052',v_event_bad,1,
            v_actor,v_actor,v_actor,clock_timestamp()
        );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_a,'G6_PHASE5_TEST');

    v_result := public.preview_financial_event_posting_queue(10);
    v_queue := (v_result->>'queueRunId')::UUID;
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF v_result->>'status' <> 'PREVIEWED'
       OR (v_result->>'eventCount')::INTEGER <> 2
       OR v_result->>'previewHash' IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: queue preview invalid: %',v_result;
    END IF;

    v_rejected := FALSE;
    BEGIN
        PERFORM public.preview_financial_event_posting_queue(10);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: second active Company queue accepted';
    END IF;

    v_result := public.approve_financial_event_posting_queue(
        v_queue,v_version
    );
    v_version := (v_result->>'masterVersion')::BIGINT;
    IF v_result->>'status' <> 'APPROVED' THEN
        RAISE EXCEPTION 'TEST_FAILED: queue approval invalid: %',v_result;
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'G6_PHASE5_CROSS');
    v_rejected := FALSE;
    BEGIN
        PERFORM public.process_financial_event_posting_queue(
            v_queue,v_version
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'FINANCE_POSTING_QUEUE_NOT_FOUND' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company queue accepted';
    END IF;
    PERFORM public.set_active_company_context(v_company_a,'G6_PHASE5_TEST');

    v_result := public.process_financial_event_posting_queue(
        v_queue,v_version
    );
    IF v_result->>'status' <> 'COMPLETED_WITH_ERRORS'
       OR (v_result->>'postedCount')::INTEGER <> 1
       OR (v_result->>'failedCount')::INTEGER <> 1
       OR (v_result->>'skippedCount')::INTEGER <> 0
       OR COALESCE((v_result->>'idempotentReplay')::BOOLEAN,TRUE) THEN
        RAISE EXCEPTION 'TEST_FAILED: queue processing invalid: %',v_result;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.finance_posting_queue_items item
    WHERE item.company_id = v_company_a AND item.queue_run_id = v_queue
      AND (
          (item.financial_event_id = v_event_good
           AND item.status = 'POSTED' AND item.journal_id IS NOT NULL)
          OR
          (item.financial_event_id = v_event_bad
           AND item.status = 'FAILED' AND item.journal_id IS NULL
           AND item.error_code IS NOT NULL)
      );
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: per-event result isolation invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.financial_events event
        WHERE event.company_id = v_company_a AND event.id = v_event_good
          AND event.status::TEXT = 'POSTED'
    ) OR NOT EXISTS (
        SELECT 1 FROM public.financial_events event
        WHERE event.company_id = v_company_a AND event.id = v_event_bad
          AND event.status::TEXT = 'HOLD'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: event final states invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.finance_journals journal
    WHERE journal.company_id = v_company_a
      AND journal.financial_event_id IN (v_event_good,v_event_bad);
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: failed item produced partial journal';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.finance_posting_exceptions exception_state
        WHERE exception_state.company_id = v_company_a
          AND exception_state.financial_event_id = v_event_bad
          AND exception_state.resolver_level = 'CONTROLLED_QUEUE'
          AND exception_state.status = 'POSTING_ERROR'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: failed event exception missing';
    END IF;

    v_result := public.process_financial_event_posting_queue(v_queue,1);
    IF NOT COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE)
       OR v_result->>'status' <> 'COMPLETED_WITH_ERRORS' THEN
        RAISE EXCEPTION 'TEST_FAILED: completed queue replay invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.finance_journals journal
    WHERE journal.company_id = v_company_a
      AND journal.financial_event_id = v_event_good;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: replay duplicated journal';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.finance_posting_queue_audit audit
    WHERE audit.company_id = v_company_a AND audit.queue_run_id = v_queue
      AND audit.action IN ('PREVIEW','APPROVE','PROCESS');
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'TEST_FAILED: queue audit lifecycle incomplete';
    END IF;

    v_rejected := FALSE;
    BEGIN
        UPDATE public.finance_posting_queue_items SET error_message = 'tamper'
        WHERE company_id = v_company_a
          AND queue_run_id = v_queue
          AND financial_event_id = v_event_bad;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'FINAL_FINANCE_POSTING_QUEUE_ITEM_IMMUTABLE' THEN
            v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: final queue item was mutable';
    END IF;

    IF has_table_privilege(
        'authenticated','public.finance_posting_queue_runs',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.finance_posting_queue_items',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.finance_posting_queue_audit',
        'INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.preview_financial_event_posting_queue(integer)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.approve_financial_event_posting_queue(uuid,bigint)','EXECUTE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.process_financial_event_posting_queue(uuid,bigint)','EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Phase 5 privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: G6 Phase 5 queue is active-Company scoped, previewed, approved, per-event isolated, idempotent, immutable, and audited.';
END
$test$;

ROLLBACK;
