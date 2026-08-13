-- G6 corrective phase 5 preflight: controlled queue and historical HOLD scope.
--
-- SAFETY:
-- - one SELECT statement only;
-- - aggregate metadata and counts only; no payload values or business names;
-- - no DDL, DML, lock, TEMP object, or routine execution;
-- - does not preview, approve, post, retry, or mutate any Financial Event.

WITH required_versions(version) AS (
    VALUES
        ('20260810190000'),
        ('20260810200000')
), expected_queue_relations(relation_name) AS (
    VALUES
        ('finance_posting_queue_runs'),
        ('finance_posting_queue_items'),
        ('finance_posting_queue_audit')
), expected_queue_routines(schema_name,routine_name) AS (
    VALUES
        ('public','preview_financial_event_posting_queue'),
        ('public','approve_financial_event_posting_queue'),
        ('public','process_financial_event_posting_queue')
), hold_events AS (
    SELECT event.*
    FROM public.financial_events event
    WHERE event.status::TEXT = 'HOLD'
), supported_hold_events AS (
    SELECT event.*
    FROM hold_events event
    WHERE event.system_event_key = 'STOCK_OPENING'
      AND event.event_type::TEXT = 'STOCK_OPENING'
      AND event.source_table = 'opening_stock_documents'
), supported_event_readiness AS (
    SELECT
        event.id AS event_id,
        event.company_id,
        event.event_date,
        event.event_version,
        company.status AS company_status,
        document.id AS source_document_id,
        document.status AS source_document_status,
        document.total_cost AS source_total_cost,
        CASE
            WHEN jsonb_typeof(event.amounts->'inventoryDebit') = 'number'
            THEN (event.amounts->>'inventoryDebit')::NUMERIC
            ELSE NULL
        END AS inventory_debit,
        CASE
            WHEN jsonb_typeof(event.amounts->'openingBalanceCredit') = 'number'
            THEN (event.amounts->>'openingBalanceCredit')::NUMERIC
            ELSE NULL
        END AS opening_balance_credit,
        (
            SELECT count(*)
            FROM public.posting_rule_sets rule_set
            WHERE rule_set.company_id = event.company_id
              AND rule_set.transaction_category_id =
                  event.transaction_category_id
              AND rule_set.system_key = event.system_event_key
              AND rule_set.status = 'APPROVED'
              AND rule_set.effective_from <= event.event_date
              AND (
                  rule_set.effective_to IS NULL
                  OR rule_set.effective_to > event.event_date
              )
        ) AS approved_rule_set_count,
        (
            SELECT count(*)
            FROM public.accounting_periods period
            WHERE period.company_id = event.company_id
              AND event.event_date::DATE
                  BETWEEN period.start_date AND period.end_date
              AND period.status IN ('OPEN','REOPENED')
        ) AS direct_postable_period_count,
        (
            SELECT count(*)
            FROM public.accounting_periods period
            WHERE period.company_id = event.company_id
              AND period.start_date > event.event_date::DATE
              AND period.status IN ('OPEN','REOPENED')
        ) AS later_postable_period_count,
        EXISTS (
            SELECT 1
            FROM public.finance_journals journal
            WHERE journal.company_id = event.company_id
              AND journal.financial_event_id = event.id
        ) AS has_canonical_journal
    FROM supported_hold_events event
    LEFT JOIN public.companies company ON company.id = event.company_id
    LEFT JOIN public.opening_stock_documents document
      ON document.company_id = event.company_id
     AND document.id = event.source_id
     AND document.financial_event_id = event.id
), checks AS (
    SELECT
        'g6_phase5_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = required.version

    UNION ALL

    SELECT
        'canonical_phase4_posting_runtime',
        CASE WHEN count(*) FILTER (WHERE routine.oid IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',2,
            'missing',COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER (WHERE routine.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM (
        VALUES
            ('private','post_financial_event_core'),
            ('public','post_financial_event_by_id')
    ) AS expected(schema_name,routine_name)
    LEFT JOIN pg_namespace namespace
      ON namespace.nspname = expected.schema_name
    LEFT JOIN pg_proc routine
      ON routine.pronamespace = namespace.oid
     AND routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'canonical_queue_schema_state',
        CASE WHEN count(relation.oid) = count(*)
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                    FILTER (WHERE relation.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_queue_relations expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.relation_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_queue_routine_state',
        CASE WHEN count(routine.oid) = count(*)
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(
                    expected.schema_name || '.' || expected.routine_name
                    ORDER BY expected.schema_name,expected.routine_name
                ) FILTER (WHERE routine.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_queue_routines expected
    LEFT JOIN pg_namespace namespace
      ON namespace.nspname = expected.schema_name
    LEFT JOIN pg_proc routine
      ON routine.pronamespace = namespace.oid
     AND routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'browser_direct_finance_queue_write_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
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
          'financial_events','finance_journals','finance_journal_lines',
          'finance_posting_exceptions','finance_posting_queue_runs',
          'finance_posting_queue_items','finance_posting_queue_audit'
      )
      AND has_table_privilege(
          'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
      )

    UNION ALL

    SELECT
        'legacy_batch_posting_execution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authenticated_executable_rows',count(*)
        )
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname = 'post_pending_financial_events'
      AND has_function_privilege('authenticated',routine.oid,'EXECUTE')

    UNION ALL

    SELECT
        'duplicate_financial_event_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,idempotency_key
        FROM public.financial_events
        GROUP BY company_id,idempotency_key
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'supported_hold_event_source_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM supported_event_readiness state
    WHERE state.source_document_id IS NULL
       OR state.source_document_status <> 'POSTED'
       OR state.source_total_cost IS NULL
       OR state.source_total_cost <= 0
       OR state.inventory_debit IS NULL
       OR state.opening_balance_credit IS NULL
       OR state.inventory_debit <= 0
       OR state.inventory_debit <> state.opening_balance_credit
       OR state.inventory_debit <> state.source_total_cost

    UNION ALL

    SELECT
        'supported_hold_event_company_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'inactive_or_missing_company_events',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM supported_event_readiness
    WHERE company_status IS DISTINCT FROM 'ACTIVE'

    UNION ALL

    SELECT
        'supported_hold_event_rule_scope',
        CASE
            WHEN count(*) FILTER (WHERE approved_rule_set_count > 1) > 0
                THEN 'BLOCKER'
            WHEN count(*) FILTER (WHERE approved_rule_set_count = 0) > 0
                THEN 'BACKFILL'
            ELSE 'PASS'
        END,
        jsonb_build_object(
            'missing_rule_events',count(*) FILTER (
                WHERE approved_rule_set_count = 0
            ),
            'ambiguous_rule_events',count(*) FILTER (
                WHERE approved_rule_set_count > 1
            )
        )
    FROM supported_event_readiness

    UNION ALL

    SELECT
        'supported_hold_event_period_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'events_without_postable_period',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM supported_event_readiness
    WHERE direct_postable_period_count = 0
      AND later_postable_period_count = 0

    UNION ALL

    SELECT
        'supported_hold_event_prior_period_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM supported_event_readiness
    WHERE direct_postable_period_count = 0
      AND later_postable_period_count > 0

    UNION ALL

    SELECT
        'hold_event_without_early_canonical_journal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM supported_event_readiness
    WHERE has_canonical_journal

    UNION ALL

    SELECT
        'supported_historical_queue_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM supported_event_readiness
    WHERE company_status = 'ACTIVE'

    UNION ALL

    SELECT
        'unsupported_hold_event_contract_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'DEFERRED' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies',count(DISTINCT company_id),
            'event_contracts',count(DISTINCT (
                system_event_key,event_type::TEXT,source_table
            ))
        )
    FROM hold_events event
    WHERE NOT (
        event.system_event_key = 'STOCK_OPENING'
        AND event.event_type::TEXT = 'STOCK_OPENING'
        AND event.source_table = 'opening_stock_documents'
    )

    UNION ALL

    SELECT
        'non_hold_event_without_canonical_journal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM public.financial_events event
    LEFT JOIN public.finance_journals journal
      ON journal.company_id = event.company_id
     AND journal.financial_event_id = event.id
    WHERE event.status::TEXT = 'POSTED'
      AND journal.id IS NULL

    UNION ALL

    SELECT
        'posting_exception_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'rows',count(*),
            'pending_mapping',count(*) FILTER (
                WHERE status = 'PENDING_MAPPING'
            ),
            'posting_error',count(*) FILTER (
                WHERE status = 'POSTING_ERROR'
            ),
            'resolved',count(*) FILTER (WHERE status = 'RESOLVED')
        )
    FROM public.finance_posting_exceptions

    UNION ALL

    SELECT
        'historical_hold_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'hold_events',(SELECT count(*) FROM hold_events),
            'supported_stock_opening_events',(
                SELECT count(*) FROM supported_hold_events
            ),
            'unsupported_events',(
                SELECT count(*) FROM hold_events
                WHERE NOT (
                    system_event_key = 'STOCK_OPENING'
                    AND event_type::TEXT = 'STOCK_OPENING'
                    AND source_table = 'opening_stock_documents'
                )
            ),
            'companies',(SELECT count(DISTINCT company_id) FROM hold_events),
            'posted_events',(
                SELECT count(*) FROM public.financial_events
                WHERE status::TEXT = 'POSTED'
            ),
            'canonical_journals',(
                SELECT count(*) FROM public.finance_journals
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3
        WHEN 'SETUP' THEN 4
        WHEN 'DEFERRED' THEN 5
        WHEN 'PASS' THEN 6
        ELSE 7
    END,
    check_name;
