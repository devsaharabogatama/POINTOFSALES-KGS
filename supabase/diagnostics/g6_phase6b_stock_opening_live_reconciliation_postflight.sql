-- G6 phase 6B postflight: one controlled live STOCK_OPENING final effect.
-- SAFETY: one aggregate SELECT only; no routine execution or mutation.

WITH stock_opening_events AS (
    SELECT event.*
    FROM public.financial_events event
    WHERE event.system_event_key='STOCK_OPENING'
      AND event.event_type::TEXT='STOCK_OPENING'
      AND event.source_table='opening_stock_documents'
), event_journal AS (
    SELECT
        event.id AS event_id,event.company_id,event.status::TEXT AS event_status,
        CASE WHEN jsonb_typeof(event.amounts->'inventoryDebit')='number'
             THEN (event.amounts->>'inventoryDebit')::NUMERIC END AS expected_amount,
        journal.id AS journal_id,journal.status AS journal_status,
        journal.total_debit,journal.total_credit,
        COALESCE(sum(line.debit) FILTER (
            WHERE line.account_function_key_snapshot='INVENTORY_ASSET'
        ),0) AS inventory_debit,
        COALESCE(sum(line.credit) FILTER (
            WHERE line.account_function_key_snapshot='OPENING_BALANCE_CLEARING'
        ),0) AS opening_credit
    FROM stock_opening_events event
    LEFT JOIN public.finance_journals journal
      ON journal.company_id=event.company_id
     AND journal.financial_event_id=event.id
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id=journal.company_id AND line.journal_id=journal.id
    GROUP BY event.id,event.company_id,event.status,event.amounts,journal.id,
        journal.status,journal.total_debit,journal.total_credit
), fifo_value AS (
    SELECT company.id company_id,
        COALESCE(sum(batch.qty_remaining*batch.cogs_unit),0)::NUMERIC(24,4) amount
    FROM public.companies company
    LEFT JOIN public.product_batches batch
      ON batch.company_id=company.id AND batch.qty_remaining>0
    WHERE company.status='ACTIVE'
    GROUP BY company.id
), inventory_gl AS (
    SELECT company.id company_id,
        COALESCE(sum(line.debit-line.credit),0)::NUMERIC(24,4) amount
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id=company.id AND journal.status='POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id=journal.company_id AND line.journal_id=journal.id
     AND line.account_function_key_snapshot='INVENTORY_ASSET'
    WHERE company.status='ACTIVE'
    GROUP BY company.id
), checks AS (
    SELECT 'supported_stock_opening_final_effect'::TEXT check_name,
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
        jsonb_build_object('row_count',count(*)) details
    FROM event_journal
    WHERE event_status<>'POSTED' OR journal_id IS NULL OR journal_status<>'POSTED'

    UNION ALL
    SELECT 'supported_stock_opening_journal_amount',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM event_journal
    WHERE expected_amount IS NULL OR expected_amount<=0
       OR total_debit<>expected_amount OR total_credit<>expected_amount
       OR inventory_debit<>expected_amount OR opening_credit<>expected_amount

    UNION ALL
    SELECT 'duplicate_stock_opening_journal',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT event.company_id,event.id
        FROM stock_opening_events event
        JOIN public.finance_journals journal
          ON journal.company_id=event.company_id
         AND journal.financial_event_id=event.id
        GROUP BY event.company_id,event.id HAVING count(*)>1
    ) duplicate_group

    UNION ALL
    SELECT 'active_finance_queue',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('run_count',count(*))
    FROM public.finance_posting_queue_runs
    WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')

    UNION ALL
    SELECT 'controlled_live_queue_result',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('invalid_run_count',count(*))
    FROM public.finance_posting_queue_runs run
    WHERE run.scope_system_key='STOCK_OPENING'
      AND run.created_at=(SELECT max(created_at)
          FROM public.finance_posting_queue_runs latest
          WHERE latest.company_id=run.company_id)
      AND (run.status<>'COMPLETED' OR run.posted_count<>1
           OR run.failed_count<>0 OR run.skipped_count<>0)

    UNION ALL
    SELECT 'controlled_live_queue_presence',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),jsonb_build_object('matching_run_count',count(*))
    FROM public.finance_posting_queue_runs run
    WHERE run.scope_system_key='STOCK_OPENING'
      AND run.status='COMPLETED' AND run.previewed_event_count=1
      AND run.posted_count=1 AND run.failed_count=0 AND run.skipped_count=0

    UNION ALL
    SELECT 'posted_queue_item_journal_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.finance_posting_queue_items item
    LEFT JOIN public.finance_journals journal
      ON journal.company_id=item.company_id AND journal.id=item.journal_id
    WHERE item.status='POSTED'
      AND (journal.id IS NULL OR journal.status<>'POSTED'
           OR journal.financial_event_id<>item.financial_event_id)

    UNION ALL
    SELECT 'supported_stock_opening_open_exception',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.finance_posting_exceptions exception_state
    JOIN stock_opening_events event
      ON event.company_id=exception_state.company_id
     AND event.id=exception_state.financial_event_id
    WHERE exception_state.status<>'RESOLVED'

    UNION ALL
    SELECT 'posted_report_fixture_readiness',
        CASE WHEN count(*)>0 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)>0 THEN 0 ELSE 1 END,
        jsonb_build_object('posted_journals',count(*),
            'posted_lines',COALESCE(sum(line_state.line_count),0))
    FROM public.finance_journals journal
    LEFT JOIN LATERAL (
        SELECT count(*) line_count FROM public.finance_journal_lines line
        WHERE line.company_id=journal.company_id AND line.journal_id=journal.id
    ) line_state ON TRUE
    WHERE journal.status='POSTED'

    UNION ALL
    SELECT 'stock_fifo_gl_full_reconciliation',
        CASE WHEN count(*) FILTER (WHERE fifo.amount<>ledger.amount)=0
             THEN 'PASS' ELSE 'DEFERRED' END,0,
        jsonb_build_object(
            'company_count',count(*) FILTER (WHERE fifo.amount<>ledger.amount),
            'fifo_value',COALESCE(sum(fifo.amount),0),
            'inventory_gl_value',COALESCE(sum(ledger.amount),0),
            'absolute_difference',COALESCE(sum(abs(fifo.amount-ledger.amount)),0),
            'reason','unsupported operational event contracts remain HOLD'
        )
    FROM fifo_value fifo JOIN inventory_gl ledger USING(company_id)

    UNION ALL
    SELECT 'remaining_hold_event_inventory','INFO',0,jsonb_build_object(
        'hold_events',count(*),
        'event_contracts',count(DISTINCT (
            system_event_key,event_type::TEXT,source_table
        )))
    FROM public.financial_events WHERE status::TEXT='HOLD'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2
    WHEN 'DEFERRED' THEN 3 ELSE 4 END,check_name;
