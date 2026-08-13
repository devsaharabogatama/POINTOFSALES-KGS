-- G6 corrective phase 6B preflight: controlled live STOCK_OPENING posting.
--
-- SAFETY:
-- - one aggregate SELECT only;
-- - no queue preview/approval/process routine is executed;
-- - no DDL, DML, lock, TEMP object, journal, or Financial Event mutation;
-- - returns counts and aggregate values only, never business names/payloads.

WITH required_versions(version) AS (
    VALUES ('20260810210000'),('20260810220000')
), supported_hold_events AS (
    SELECT event.*
    FROM public.financial_events event
    WHERE event.status::TEXT = 'HOLD'
      AND event.system_event_key = 'STOCK_OPENING'
      AND event.event_type::TEXT = 'STOCK_OPENING'
      AND event.source_table = 'opening_stock_documents'
), supported_readiness AS (
    SELECT
        event.id AS event_id,
        event.company_id,
        event.event_date,
        company.status AS company_status,
        document.id AS document_id,
        document.status AS document_status,
        document.total_cost,
        CASE WHEN jsonb_typeof(event.amounts->'inventoryDebit') = 'number'
             THEN (event.amounts->>'inventoryDebit')::NUMERIC END
            AS inventory_debit,
        CASE WHEN jsonb_typeof(event.amounts->'openingBalanceCredit') = 'number'
             THEN (event.amounts->>'openingBalanceCredit')::NUMERIC END
            AS opening_credit,
        (
            SELECT count(*)
            FROM public.posting_rule_sets rule_set
            WHERE rule_set.company_id = event.company_id
              AND rule_set.transaction_category_id = event.transaction_category_id
              AND rule_set.system_key = event.system_event_key
              AND rule_set.status = 'APPROVED'
              AND rule_set.effective_from <= event.event_date
              AND (rule_set.effective_to IS NULL
                   OR rule_set.effective_to > event.event_date)
        ) AS approved_rule_count,
        (
            SELECT count(*)
            FROM public.accounting_periods period
            WHERE period.company_id = event.company_id
              AND event.event_date::DATE BETWEEN period.start_date AND period.end_date
              AND period.status IN ('OPEN','REOPENED')
        ) AS direct_period_count,
        (
            SELECT count(*)
            FROM public.accounting_periods period
            WHERE period.company_id = event.company_id
              AND period.start_date > event.event_date::DATE
              AND period.status IN ('OPEN','REOPENED')
        ) AS later_period_count,
        EXISTS (
            SELECT 1 FROM public.finance_journals journal
            WHERE journal.company_id = event.company_id
              AND journal.financial_event_id = event.id
        ) AS has_journal,
        EXISTS (
            SELECT 1 FROM public.finance_posting_exceptions exception_state
            WHERE exception_state.company_id = event.company_id
              AND exception_state.financial_event_id = event.id
              AND exception_state.status <> 'RESOLVED'
        ) AS has_open_exception
    FROM supported_hold_events event
    LEFT JOIN public.companies company ON company.id = event.company_id
    LEFT JOIN public.opening_stock_documents document
      ON document.company_id = event.company_id
     AND document.id = event.source_id
     AND document.financial_event_id = event.id
), fifo_value AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(batch.qty_remaining * batch.cogs_unit),0)::NUMERIC(24,4)
            AS amount
    FROM public.companies company
    LEFT JOIN public.product_batches batch
      ON batch.company_id = company.id AND batch.qty_remaining > 0
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), inventory_gl AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(line.debit-line.credit),0)::NUMERIC(24,4) AS amount
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id = company.id AND journal.status = 'POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id = journal.company_id
     AND line.journal_id = journal.id
     AND line.account_function_key_snapshot = 'INVENTORY_ASSET'
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), checks AS (
    SELECT
        'g6_phase6b_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
                FILTER (WHERE migration.version IS NULL),'[]'::JSONB)
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = required.version

    UNION ALL

    SELECT
        'required_queue_and_report_routines',
        CASE WHEN count(routine.oid)=count(*) THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                FILTER (WHERE routine.oid IS NULL),'[]'::JSONB)
        )
    FROM (VALUES
        ('preview_financial_event_posting_queue'),
        ('approve_financial_event_posting_queue'),
        ('process_financial_event_posting_queue'),
        ('get_finance_trial_balance'),
        ('get_finance_general_ledger')
    ) expected(routine_name)
    LEFT JOIN pg_namespace namespace ON namespace.nspname='public'
    LEFT JOIN pg_proc routine
      ON routine.pronamespace=namespace.oid
     AND routine.proname=expected.routine_name

    UNION ALL

    SELECT
        'active_finance_queue',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('run_count',count(*))
    FROM public.finance_posting_queue_runs
    WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')

    UNION ALL

    SELECT
        'supported_event_source_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM supported_readiness state
    WHERE state.company_status IS DISTINCT FROM 'ACTIVE'
       OR state.document_id IS NULL
       OR state.document_status <> 'POSTED'
       OR state.total_cost IS NULL OR state.total_cost <= 0
       OR state.inventory_debit IS NULL OR state.opening_credit IS NULL
       OR state.inventory_debit <= 0
       OR state.inventory_debit <> state.opening_credit
       OR state.inventory_debit <> state.total_cost

    UNION ALL

    SELECT
        'supported_event_rule_contract',
        CASE WHEN count(*) FILTER (WHERE approved_rule_count<>1)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'missing_rule_events',count(*) FILTER (WHERE approved_rule_count=0),
            'ambiguous_rule_events',count(*) FILTER (WHERE approved_rule_count>1)
        )
    FROM supported_readiness

    UNION ALL

    SELECT
        'supported_event_period_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM supported_readiness
    WHERE direct_period_count=0 AND later_period_count=0

    UNION ALL

    SELECT
        'supported_event_prior_period_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('event_count',count(*))
    FROM supported_readiness
    WHERE direct_period_count=0 AND later_period_count>0

    UNION ALL

    SELECT
        'supported_event_existing_final_effect',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM supported_readiness
    WHERE has_journal

    UNION ALL

    SELECT
        'supported_event_open_exception',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('event_count',count(*))
    FROM supported_readiness
    WHERE has_open_exception

    UNION ALL

    SELECT
        'supported_stock_opening_live_run_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies',count(DISTINCT company_id),
            'amount_total',COALESCE(sum(total_cost),0)
        )
    FROM supported_readiness

    UNION ALL

    SELECT
        'unsupported_hold_event_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'DEFERRED' END,
        jsonb_build_object(
            'event_count',count(*),
            'event_contracts',count(DISTINCT (
                system_event_key,event_type::TEXT,source_table
            ))
        )
    FROM public.financial_events event
    WHERE event.status::TEXT='HOLD'
      AND NOT (
          event.system_event_key='STOCK_OPENING'
          AND event.event_type::TEXT='STOCK_OPENING'
          AND event.source_table='opening_stock_documents'
      )

    UNION ALL

    SELECT
        'browser_direct_live_posting_write_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'writable_relations',COALESCE(
                jsonb_agg(relation.relname ORDER BY relation.relname),
                '[]'::JSONB
            )
        )
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname IN (
          'financial_events','finance_journals','finance_journal_lines',
          'finance_posting_queue_runs','finance_posting_queue_items',
          'finance_posting_queue_audit'
      )
      AND has_table_privilege(
          'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
      )

    UNION ALL

    SELECT
        'stock_fifo_gl_live_baseline',
        CASE WHEN count(*) FILTER (WHERE fifo.amount<>ledger.amount)=0
             THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'company_count',count(*) FILTER (WHERE fifo.amount<>ledger.amount),
            'fifo_value',COALESCE(sum(fifo.amount),0),
            'inventory_gl_value',COALESCE(sum(ledger.amount),0),
            'absolute_difference',COALESCE(sum(abs(fifo.amount-ledger.amount)),0)
        )
    FROM fifo_value fifo
    JOIN inventory_gl ledger ON ledger.company_id=fifo.company_id

    UNION ALL

    SELECT
        'controlled_queue_history_inventory',
        'INFO',
        jsonb_build_object(
            'runs',count(*),
            'completed',count(*) FILTER (WHERE status='COMPLETED'),
            'completed_with_errors',count(*) FILTER (
                WHERE status='COMPLETED_WITH_ERRORS'
            ),
            'posted_items',(SELECT count(*)
                FROM public.finance_posting_queue_items WHERE status='POSTED'),
            'failed_items',(SELECT count(*)
                FROM public.finance_posting_queue_items WHERE status='FAILED')
        )
    FROM public.finance_posting_queue_runs
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'BACKFILL' THEN 3
    WHEN 'DEFERRED' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,check_name;
