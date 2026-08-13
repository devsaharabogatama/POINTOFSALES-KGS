-- G6 corrective phase 5 postflight: controlled posting queue.
-- SAFETY: one aggregate SELECT statement; no routine execution or mutation.

WITH expected_relations(relation_name) AS (
    VALUES
        ('finance_posting_queue_runs'),
        ('finance_posting_queue_items'),
        ('finance_posting_queue_audit')
), expected_routines(schema_name,routine_name) AS (
    VALUES
        ('public','preview_financial_event_posting_queue'),
        ('public','approve_financial_event_posting_queue'),
        ('public','process_financial_event_posting_queue')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*) - 1) AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260810210000'

    UNION ALL

    SELECT
        'required_queue_relations',
        CASE WHEN count(relation.oid) = count(*) THEN 'PASS' ELSE 'FAIL' END,
        count(*) - count(relation.oid),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                    FILTER (WHERE relation.oid IS NULL),'[]'::JSONB
            )
        )
    FROM expected_relations expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.relation_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'required_queue_routines',
        CASE WHEN count(routine.oid) = count(*) THEN 'PASS' ELSE 'FAIL' END,
        count(*) - count(routine.oid),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER (WHERE routine.oid IS NULL),'[]'::JSONB
            )
        )
    FROM expected_routines expected
    LEFT JOIN pg_namespace namespace
      ON namespace.nspname = expected.schema_name
    LEFT JOIN pg_proc routine
      ON routine.pronamespace = namespace.oid
     AND routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'queue_rls',
        CASE WHEN count(*) FILTER (WHERE NOT relation.relrowsecurity) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE NOT relation.relrowsecurity),
        jsonb_build_object('relation_rows',count(*))
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN (
          'finance_posting_queue_runs','finance_posting_queue_items',
          'finance_posting_queue_audit'
      )

    UNION ALL

    SELECT
        'browser_queue_write_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'writable_relations',COALESCE(
                jsonb_agg(relation.relname ORDER BY relation.relname),
                '[]'::JSONB
            )
        )
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN (
          'finance_posting_queue_runs','finance_posting_queue_items',
          'finance_posting_queue_audit','financial_events',
          'finance_journals','finance_journal_lines'
      )
      AND has_table_privilege(
          'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
      )

    UNION ALL

    SELECT
        'queue_rpc_boundary',
        CASE WHEN count(*) FILTER (
            WHERE has_function_privilege('anon',routine.oid,'EXECUTE')
               OR NOT has_function_privilege(
                   'authenticated',routine.oid,'EXECUTE'
               )
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE has_function_privilege('anon',routine.oid,'EXECUTE')
               OR NOT has_function_privilege(
                   'authenticated',routine.oid,'EXECUTE'
               )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname IN (
          'preview_financial_event_posting_queue',
          'approve_financial_event_posting_queue',
          'process_financial_event_posting_queue'
      )

    UNION ALL

    SELECT
        'queue_history_guard_triggers',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 3),
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_state
    JOIN pg_class relation ON relation.oid = trigger_state.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN (
          'finance_posting_queue_runs','finance_posting_queue_items',
          'finance_posting_queue_audit'
      )
      AND trigger_state.tgname IN (
          'g6_touch_posting_queue_run','g6_guard_posting_queue_item',
          'g6_guard_posting_queue_audit'
      )
      AND NOT trigger_state.tgisinternal
      AND trigger_state.tgenabled <> 'D'

    UNION ALL

    SELECT
        'single_active_company_queue_index',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1),
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_finance_posting_queue_runs_company_active'
      AND indexdef ILIKE '%company_id%'
      AND indexdef ILIKE '%PREVIEWED%'
      AND indexdef ILIKE '%APPROVED%'
      AND indexdef ILIKE '%PROCESSING%'

    UNION ALL

    SELECT
        'queue_run_count_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('run_count',count(*))
    FROM public.finance_posting_queue_runs run
    LEFT JOIN LATERAL (
        SELECT
            count(*) AS item_count,
            count(*) FILTER (WHERE item.status = 'POSTED') AS posted_count,
            count(*) FILTER (WHERE item.status = 'FAILED') AS failed_count,
            count(*) FILTER (WHERE item.status = 'SKIPPED') AS skipped_count
        FROM public.finance_posting_queue_items item
        WHERE item.company_id = run.company_id
          AND item.queue_run_id = run.id
    ) item_count ON TRUE
    WHERE run.previewed_event_count <> item_count.item_count
       OR run.posted_count <> item_count.posted_count
       OR run.failed_count <> item_count.failed_count
       OR run.skipped_count <> item_count.skipped_count

    UNION ALL

    SELECT
        'posted_queue_item_final_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.finance_posting_queue_items item
    LEFT JOIN public.financial_events event
      ON event.company_id = item.company_id
     AND event.id = item.financial_event_id
    LEFT JOIN public.finance_journals journal
      ON journal.company_id = item.company_id
     AND journal.id = item.journal_id
     AND journal.financial_event_id = item.financial_event_id
    WHERE item.status = 'POSTED'
      AND (
          event.status::TEXT IS DISTINCT FROM 'POSTED'
          OR journal.id IS NULL
          OR journal.status <> 'POSTED'
      )

    UNION ALL

    SELECT
        'hold_event_without_early_journal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('event_count',count(*))
    FROM public.financial_events event
    JOIN public.finance_journals journal
      ON journal.company_id = event.company_id
     AND journal.financial_event_id = event.id
    WHERE event.status::TEXT = 'HOLD'

    UNION ALL

    SELECT
        'queue_runtime_contract',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 3),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname IN (
          'preview_financial_event_posting_queue',
          'approve_financial_event_posting_queue',
          'process_financial_event_posting_queue'
      )
      AND pg_get_functiondef(routine.oid) ILIKE '%private_active_company_id%'
      AND pg_get_functiondef(routine.oid) ILIKE '%FINANCE_QUEUE_ROLE_REQUIRED%'

    UNION ALL

    SELECT
        'process_core_and_exception_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname = 'process_financial_event_posting_queue'
      AND pg_get_functiondef(routine.oid)
          ILIKE '%private.post_financial_event_core%'
      AND pg_get_functiondef(routine.oid)
          ILIKE '%finance_posting_exceptions%'
      AND pg_get_functiondef(routine.oid) ILIKE '%EXCEPTION WHEN OTHERS%'

    UNION ALL

    SELECT
        'unsupported_hold_event_remains_unqueued',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.finance_posting_queue_items item
    WHERE item.system_event_key_snapshot <> 'STOCK_OPENING'

    UNION ALL

    SELECT
        'queue_runtime_inventory',
        'INFO',0,
        jsonb_build_object(
            'runs',(SELECT count(*) FROM public.finance_posting_queue_runs),
            'items',(SELECT count(*) FROM public.finance_posting_queue_items),
            'audits',(SELECT count(*) FROM public.finance_posting_queue_audit),
            'supported_hold_events',(
                SELECT count(*) FROM public.financial_events
                WHERE status::TEXT = 'HOLD'
                  AND system_event_key = 'STOCK_OPENING'
                  AND event_type::TEXT = 'STOCK_OPENING'
                  AND source_table = 'opening_stock_documents'
            ),
            'unsupported_hold_events',(
                SELECT count(*) FROM public.financial_events
                WHERE status::TEXT = 'HOLD'
                  AND NOT (
                      system_event_key = 'STOCK_OPENING'
                      AND event_type::TEXT = 'STOCK_OPENING'
                      AND source_table = 'opening_stock_documents'
                  )
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
