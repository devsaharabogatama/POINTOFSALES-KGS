-- G6 corrective phase 4 behavioral test: atomic single-event posting.
-- SAFETY: all fixture, event, journal, exception, and audit rows roll back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company_a CONSTANT UUID :=
        '00000000-0000-0000-0000-000000020001';
    v_company_b CONSTANT UUID :=
        '00000000-0000-0000-0000-000000020002';
    v_warehouse CONSTANT UUID :=
        '00000000-0000-0000-0000-000000020011';
    v_period CONSTANT UUID :=
        '00000000-0000-0000-0000-000000020021';
    v_document CONSTANT UUID :=
        '00000000-0000-0000-0000-000000020031';
    v_event CONSTANT UUID :=
        '00000000-0000-0000-0000-000000020041';
    v_unsupported_event CONSTANT UUID :=
        '00000000-0000-0000-0000-000000020042';
    v_category UUID;
    v_unsupported_category UUID;
    v_result JSONB;
    v_journal UUID;
    v_exception UUID;
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
        (v_company_a,'G6P4A','G6 Phase 4 A','g6-phase4-a','ACTIVE'),
        (v_company_b,'G6P4B','G6 Phase 4 B','g6-phase4-b','ACTIVE');
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
    SELECT category.id INTO v_unsupported_category
    FROM public.transaction_categories category
    WHERE category.company_id = v_company_a
      AND category.system_key = 'STOCK_GAIN'
      AND category.is_system_default;
    IF v_category IS NULL OR v_unsupported_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: required categories missing';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id = v_company_a
      AND rule_set.transaction_category_id = v_category
      AND rule_set.status = 'APPROVED';
    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: future Company posting configuration missing';
    END IF;

    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type
    ) VALUES (
        v_warehouse,v_company_a,'G6-WH','G6 Warehouse','CENTRAL'
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
    ) VALUES (
        v_event,'G6-P4-OPEN','STOCK_OPENING'::public.event_type,
        'opening_stock_documents',v_document,
        v_event_at,1,
        'G6_PHASE4_OPENING|'||v_company_a::TEXT,
        jsonb_build_object(
            'inventoryDebit',100,
            'openingBalanceCredit',100,
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
    ) VALUES (
        v_document,v_company_a,'G6-P4-OPENING',v_warehouse,
        v_event_at::DATE,'POSTED',1,1,100,
        '00000000-0000-0000-0000-000000020051',v_event,1,
        v_actor,v_actor,v_actor,clock_timestamp()
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company_a,'G6_PHASE4_TEST');

    v_result := public.post_financial_event_by_id(v_event,1);
    IF v_result->>'status' <> 'POSTED'
       OR COALESCE((v_result->>'idempotentReplay')::BOOLEAN,TRUE) THEN
        RAISE EXCEPTION 'TEST_FAILED: event was not posted: %',v_result;
    END IF;
    v_journal := (v_result->>'journalId')::UUID;

    SELECT count(*) INTO v_count
    FROM public.finance_journals journal
    WHERE journal.company_id = v_company_a
      AND journal.id = v_journal
      AND journal.financial_event_id = v_event
      AND journal.status = 'POSTED'
      AND journal.journal_type = 'AUTOMATIC'
      AND journal.accounting_date = v_event_at::DATE
      AND journal.original_event_date = v_event_at::DATE
      AND journal.source_version = 1
      AND journal.transaction_rule_version = 1
      AND journal.total_debit = 100
      AND journal.total_credit = 100;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical journal header invalid';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.finance_journal_lines line
    WHERE line.company_id = v_company_a
      AND line.journal_id = v_journal
      AND (
          (
              line.line_no = 1 AND line.debit = 100 AND line.credit = 0
              AND line.account_function_key_snapshot = 'INVENTORY_ASSET'
          )
          OR (
              line.line_no = 2 AND line.debit = 0 AND line.credit = 100
              AND line.account_function_key_snapshot =
                  'OPENING_BALANCE_CLEARING'
          )
      );
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'TEST_FAILED: canonical journal lines invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.financial_events event
        WHERE event.company_id = v_company_a AND event.id = v_event
          AND event.status::TEXT = 'POSTED'
          AND event.processed_at IS NOT NULL
          AND event.transaction_rule_version = 1
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Financial Event not finalized';
    END IF;

    v_result := public.post_financial_event_by_id(v_event,1);
    IF NOT COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE)
       OR (v_result->>'journalId')::UUID <> v_journal THEN
        RAISE EXCEPTION 'TEST_FAILED: idempotent replay invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.finance_journals
    WHERE company_id = v_company_a AND financial_event_id = v_event;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'TEST_FAILED: replay duplicated journal';
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'G6_PHASE4_CROSS');
    v_rejected := FALSE;
    BEGIN
        PERFORM public.post_financial_event_by_id(v_event,1);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM = 'FINANCIAL_EVENT_NOT_FOUND' THEN v_rejected := TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company event posting accepted';
    END IF;
    PERFORM public.set_active_company_context(v_company_a,'G6_PHASE4_TEST');

    INSERT INTO public.financial_events(
        id,event_code,event_type,source_table,source_id,event_date,
        event_version,idempotency_key,amounts,status,error_message,
        created_by,company_id,system_event_key,transaction_category_id
    ) VALUES (
        v_unsupported_event,'G6-P4-UNSUPPORTED',
        'STOCK_GAIN'::public.event_type,'stock_adjustment_documents',
        '00000000-0000-0000-0000-000000020061',clock_timestamp(),1,
        'G6_PHASE4_UNSUPPORTED|'||v_company_a::TEXT,
        jsonb_build_object('inventoryDebit',10,'stockGainCredit',10),
        'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_NOT_ENABLED',
        v_actor,v_company_a,'STOCK_GAIN',v_unsupported_category
    );
    v_result := public.post_financial_event_by_id(v_unsupported_event,1);
    IF v_result->>'status' <> 'HOLD'
       OR v_result->>'errorCode' <> 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'
       OR v_result->>'postingExceptionId' IS NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: unsupported contract not isolated: %',v_result;
    END IF;
    v_exception := (v_result->>'postingExceptionId')::UUID;
    v_result := public.post_financial_event_by_id(v_unsupported_event,1);
    IF (v_result->>'postingExceptionId')::UUID <> v_exception THEN
        RAISE EXCEPTION 'TEST_FAILED: retry duplicated posting exception';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.finance_journals
        WHERE company_id = v_company_a
          AND financial_event_id = v_unsupported_event
    ) OR NOT EXISTS (
        SELECT 1 FROM public.finance_posting_exceptions exception_state
        WHERE exception_state.company_id = v_company_a
          AND exception_state.financial_event_id = v_unsupported_event
          AND exception_state.status = 'POSTING_ERROR'
          AND exception_state.reason_code = 'INVALID_DIMENSION'
          AND exception_state.retry_count = 2
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: unsupported event produced partial effect';
    END IF;

    IF has_table_privilege(
        'authenticated','public.financial_events','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.finance_journals','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.finance_journal_lines','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated','public.post_financial_event_by_id(uuid,bigint)',
        'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Phase 4 privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: G6 Phase 4 single-event posting is tenant-safe, source-validated, balanced, atomic, idempotent, and exception-isolated.';
END
$test$;

ROLLBACK;
