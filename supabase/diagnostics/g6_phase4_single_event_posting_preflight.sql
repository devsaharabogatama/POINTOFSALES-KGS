-- G6 corrective phase 4 preflight: atomic single-event posting readiness.
--
-- SAFETY:
-- - one SELECT statement only;
-- - aggregate metadata/configuration only; no payload value or business name;
-- - no DDL, DML, DO block, lock, TEMP object, or routine execution;
-- - does not post, retry, mutate, or backfill Financial Events in HOLD.

WITH required_versions(version) AS (
    VALUES
        ('20260810180000'),
        ('20260810185000'),
        ('20260810190000')
), canonical_relations(relation_name) AS (
    VALUES
        ('accounting_periods'),
        ('finance_journals'),
        ('finance_journal_lines'),
        ('posting_rule_sets'),
        ('posting_rule_lines')
), canonical_routines(schema_name,routine_name) AS (
    VALUES
        ('private','resolve_financial_event_amount'),
        ('private','resolve_financial_event_account'),
        ('private','post_financial_event_core'),
        ('public','post_financial_event_by_id')
), unsafe_routine_names(routine_name) AS (
    VALUES
        ('post_financial_event'),('post_pending_financial_events'),
        ('ensure_accounting_period_open'),('resolve_account_for_function'),
        ('resolve_account_by_code'),('get_general_ledger_report'),
        ('get_trial_balance_report'),('get_income_statement_report'),
        ('get_balance_sheet_report'),('get_account_journal_lines')
), hold_events AS (
    SELECT event.*
    FROM public.financial_events event
    WHERE event.status::TEXT = 'HOLD'
), hold_event_rule_state AS (
    SELECT
        event.id AS financial_event_id,
        event.company_id,
        event.event_date,
        event.transaction_category_id,
        event.system_event_key,
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
        ) AS approved_rule_set_count
    FROM hold_events event
), approved_rule_line_state AS (
    SELECT
        rule_set.id AS rule_set_id,
        rule_set.company_id,
        rule_set.transaction_category_id,
        rule_set.system_key,
        count(line.id) AS line_count,
        count(line.id) FILTER (WHERE line.entry_side = 'DEBIT')
            AS debit_line_count,
        count(line.id) FILTER (WHERE line.entry_side = 'CREDIT')
            AS credit_line_count,
        count(DISTINCT line.line_no) AS distinct_line_numbers,
        count(*) FILTER (
            WHERE line.id IS NOT NULL
              AND (
                  account_function.function_key IS NULL
                  OR NOT account_function.is_active
              )
        ) AS invalid_function_lines
    FROM public.posting_rule_sets rule_set
    LEFT JOIN public.posting_rule_lines line
      ON line.company_id = rule_set.company_id
     AND line.rule_set_id = rule_set.id
    LEFT JOIN public.account_functions account_function
      ON account_function.function_key = line.account_function_key
    WHERE rule_set.status = 'APPROVED'
    GROUP BY
        rule_set.id,rule_set.company_id,
        rule_set.transaction_category_id,rule_set.system_key
), approved_rule_required_function_state AS (
    SELECT
        rule_set.id AS rule_set_id,
        required_function.function_key,
        count(line.id) AS matching_line_count
    FROM public.posting_rule_sets rule_set
    JOIN public.system_events system_event
      ON system_event.system_key = rule_set.system_key
    CROSS JOIN LATERAL unnest(
        system_event.required_account_functions
    ) AS required_function(function_key)
    LEFT JOIN public.posting_rule_lines line
      ON line.company_id = rule_set.company_id
     AND line.rule_set_id = rule_set.id
     AND line.account_function_key = required_function.function_key
    WHERE rule_set.status = 'APPROVED'
    GROUP BY rule_set.id,required_function.function_key
), hold_event_period_state AS (
    SELECT
        event.id AS financial_event_id,
        event.company_id,
        count(period.id) FILTER (
            WHERE event.event_date::DATE
                  BETWEEN period.start_date AND period.end_date
        ) AS containing_period_count,
        count(period.id) FILTER (
            WHERE event.event_date::DATE
                  BETWEEN period.start_date AND period.end_date
              AND period.status IN ('OPEN','REOPENED')
        ) AS containing_postable_period_count,
        count(period.id) FILTER (
            WHERE period.start_date > event.event_date::DATE
              AND period.status IN ('OPEN','REOPENED')
        ) AS later_postable_period_count
    FROM hold_events event
    LEFT JOIN public.accounting_periods period
      ON period.company_id = event.company_id
    GROUP BY event.id,event.company_id
), source_contract_inventory AS (
    SELECT
        event.system_event_key,
        event.event_type::TEXT AS event_type,
        event.source_table,
        count(*) AS event_count,
        COALESCE(
            jsonb_agg(DISTINCT amount_key.key ORDER BY amount_key.key)
                FILTER (WHERE amount_key.key IS NOT NULL),
            '[]'::JSONB
        ) AS amount_keys
    FROM hold_events event
    LEFT JOIN LATERAL jsonb_object_keys(
        CASE WHEN jsonb_typeof(event.amounts) = 'object'
             THEN event.amounts ELSE '{}'::JSONB END
    ) AS amount_key(key) ON TRUE
    GROUP BY
        event.system_event_key,event.event_type::TEXT,event.source_table
), checks AS (
    SELECT
        'g6_phase4_dependencies'::TEXT AS check_name,
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
        'canonical_phase4_relation_state',
        CASE WHEN count(relation.oid) = count(*)
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                    FILTER (WHERE relation.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM canonical_relations expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.relation_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_single_event_routine_state',
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
    FROM canonical_routines expected
    LEFT JOIN pg_namespace namespace
      ON namespace.nspname = expected.schema_name
    LEFT JOIN pg_proc routine
      ON routine.pronamespace = namespace.oid
     AND routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'unsafe_legacy_finance_routine_execution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'executable_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(DISTINCT routine.proname ORDER BY routine.proname),
                '[]'::JSONB
            )
        )
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    JOIN unsafe_routine_names unsafe
      ON unsafe.routine_name = routine.proname
    WHERE namespace.nspname = 'public'
      AND has_function_privilege('authenticated',routine.oid,'EXECUTE')

    UNION ALL

    SELECT
        'browser_direct_phase4_write_boundary',
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
          'finance_posting_exceptions'
      )
      AND has_table_privilege(
          'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
      )

    UNION ALL

    SELECT
        'invalid_hold_event_posting_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM hold_events event
    LEFT JOIN public.companies company ON company.id = event.company_id
    LEFT JOIN public.system_events system_event
      ON system_event.system_key = event.system_event_key
    LEFT JOIN public.transaction_categories category
      ON category.company_id = event.company_id
     AND category.id = event.transaction_category_id
    WHERE company.id IS NULL
       OR event.source_id IS NULL
       OR btrim(COALESCE(event.source_table,'')) = ''
       OR btrim(COALESCE(event.idempotency_key,'')) = ''
       OR event.event_version IS NULL
       OR event.event_version <= 0
       OR jsonb_typeof(event.amounts) IS DISTINCT FROM 'object'
       OR event.amounts = '{}'::JSONB
       OR system_event.system_key IS NULL
       OR NOT system_event.is_active
       OR category.id IS NULL
       OR NOT category.is_active
       OR category.system_key IS DISTINCT FROM event.system_event_key

    UNION ALL

    SELECT
        'hold_event_source_relation_state',
        CASE WHEN count(*) FILTER (WHERE relation.oid IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'source_relations',count(*),
            'missing',COALESCE(
                jsonb_agg(source.source_table ORDER BY source.source_table)
                    FILTER (WHERE relation.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM (
        SELECT DISTINCT source_table
        FROM hold_events
    ) source
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = source.source_table
     AND relation.relkind IN ('r','p','v','m')

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
        'ambiguous_hold_event_rule_set',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM hold_event_rule_state
    WHERE approved_rule_set_count > 1

    UNION ALL

    SELECT
        'hold_event_approved_rule_set_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'events_without_approved_rule_set',count(*),
            'companies_affected',count(DISTINCT company_id),
            'categories_affected',count(DISTINCT transaction_category_id)
        )
    FROM hold_event_rule_state
    WHERE approved_rule_set_count = 0

    UNION ALL

    SELECT
        'invalid_approved_rule_line_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rule_set_count',count(*))
    FROM approved_rule_line_state
    WHERE line_count < 2
       OR debit_line_count = 0
       OR credit_line_count = 0
       OR line_count <> distinct_line_numbers
       OR invalid_function_lines <> 0

    UNION ALL

    SELECT
        'approved_rule_required_function_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('missing_or_duplicate_rows',count(*))
    FROM approved_rule_required_function_state
    WHERE matching_line_count <> 1

    UNION ALL

    SELECT
        'accounting_period_overlap',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('overlap_pairs',count(*))
    FROM public.accounting_periods left_period
    JOIN public.accounting_periods right_period
      ON right_period.company_id = left_period.company_id
     AND right_period.id > left_period.id
     AND daterange(
         left_period.start_date,left_period.end_date,'[]'
     ) && daterange(
         right_period.start_date,right_period.end_date,'[]'
     )

    UNION ALL

    SELECT
        'ambiguous_hold_event_accounting_period',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM hold_event_period_state
    WHERE containing_period_count > 1

    UNION ALL

    SELECT
        'hold_event_postable_period_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'events_without_postable_period',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM hold_event_period_state
    WHERE containing_postable_period_count = 0
      AND later_postable_period_count = 0

    UNION ALL

    SELECT
        'prior_period_adjustment_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM hold_event_period_state
    WHERE containing_postable_period_count = 0
      AND later_postable_period_count > 0

    UNION ALL

    SELECT
        'existing_event_journal_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,financial_event_id
        FROM public.finance_journals
        WHERE financial_event_id IS NOT NULL
        GROUP BY company_id,financial_event_id
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'hold_event_without_early_journal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(DISTINCT event.id))
    FROM hold_events event
    JOIN public.finance_journals journal
      ON journal.company_id = event.company_id
     AND journal.financial_event_id = event.id

    UNION ALL

    SELECT
        'posted_journal_balance_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals journal
    LEFT JOIN LATERAL (
        SELECT
            COALESCE(sum(line.debit),0) AS debit_total,
            COALESCE(sum(line.credit),0) AS credit_total,
            count(*) AS line_count
        FROM public.finance_journal_lines line
        WHERE line.company_id = journal.company_id
          AND line.journal_id = journal.id
    ) line_total ON TRUE
    WHERE journal.status = 'POSTED'
      AND (
          line_total.line_count < 2
          OR line_total.debit_total <= 0
          OR line_total.debit_total <> line_total.credit_total
          OR journal.total_debit <> line_total.debit_total
          OR journal.total_credit <> line_total.credit_total
      )

    UNION ALL

    SELECT
        'posting_exception_inventory',
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
        'approved_posting_expression_inventory',
        'INFO',
        jsonb_build_object(
            'approved_rule_sets',(
                SELECT count(*) FROM public.posting_rule_sets
                WHERE status = 'APPROVED'
            ),
            'approved_rule_lines',count(*),
            'amount_expression_keys',COALESCE(
                jsonb_agg(DISTINCT line.amount_expression_key
                          ORDER BY line.amount_expression_key),
                '[]'::JSONB
            ),
            'condition_keys',COALESCE(
                jsonb_agg(DISTINCT line.condition_key
                          ORDER BY line.condition_key)
                    FILTER (WHERE line.condition_key IS NOT NULL),
                '[]'::JSONB
            )
        )
    FROM public.posting_rule_lines line
    JOIN public.posting_rule_sets rule_set
      ON rule_set.company_id = line.company_id
     AND rule_set.id = line.rule_set_id
     AND rule_set.status = 'APPROVED'

    UNION ALL

    SELECT
        'hold_event_source_contract_inventory',
        'INFO',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'systemEventKey',system_event_key,
                    'eventType',event_type,
                    'sourceTable',source_table,
                    'eventCount',event_count,
                    'amountKeys',amount_keys
                ) ORDER BY system_event_key,event_type,source_table
            ),
            '[]'::JSONB
        )
    FROM source_contract_inventory

    UNION ALL

    SELECT
        'single_event_posting_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'hold_events',(SELECT count(*) FROM hold_events),
            'event_types',(
                SELECT count(DISTINCT event_type::TEXT) FROM hold_events
            ),
            'companies',(
                SELECT count(DISTINCT company_id) FROM hold_events
            ),
            'approved_rule_sets',(
                SELECT count(*) FROM public.posting_rule_sets
                WHERE status = 'APPROVED'
            ),
            'canonical_journals',(
                SELECT count(*) FROM public.finance_journals
            ),
            'posted_canonical_journals',(
                SELECT count(*) FROM public.finance_journals
                WHERE status = 'POSTED'
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
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
