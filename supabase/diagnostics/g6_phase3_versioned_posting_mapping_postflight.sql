-- G6 corrective phase 3 postflight: versioned posting mapping.
-- SAFETY: SELECT-only; aggregate metadata/configuration counts only.

WITH required_tables(table_name) AS (
    VALUES
        ('posting_rule_sets'),('posting_rule_lines'),
        ('posting_rule_set_audit')
), required_routines(routine_name) AS (
    VALUES ('save_posting_rule_set'),('approve_posting_rule_set')
), required_triggers(trigger_name) AS (
    VALUES
        ('g6_guard_posting_rule_set'),('g6_guard_posting_rule_line'),
        ('g6_guard_posting_rule_audit')
), required_scope AS (
    SELECT
        category.company_id,
        category.id AS transaction_category_id,
        category.system_key,
        required_function.function_key
    FROM public.transaction_categories category
    JOIN public.companies company ON company.id = category.company_id
    JOIN public.system_events system_event
      ON system_event.system_key = category.system_key
    CROSS JOIN LATERAL unnest(
        system_event.required_account_functions
    ) AS required_function(function_key)
    WHERE company.status = 'ACTIVE'
      AND category.is_active
      AND system_event.is_active
), current_rule_counts AS (
    SELECT
        scope.*,
        count(rule.id) AS rule_count
    FROM required_scope scope
    LEFT JOIN public.transaction_account_rules rule
      ON rule.company_id = scope.company_id
     AND rule.transaction_category_id = scope.transaction_category_id
     AND rule.system_key = scope.system_key
     AND rule.account_function_key = scope.function_key
     AND rule.status = 'ACTIVE'
     AND rule.effective_from <= clock_timestamp()
     AND (rule.effective_to IS NULL OR rule.effective_to > clock_timestamp())
    GROUP BY
        scope.company_id,scope.transaction_category_id,
        scope.system_key,scope.function_key
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*) FILTER (WHERE version IS NULL) AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260810190000'

    UNION ALL

    SELECT
        'required_posting_mapping_tables',
        CASE WHEN count(relation.oid) = count(*) THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE relation.oid IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER (WHERE relation.oid IS NULL),'[]'::JSONB
            )
        )
    FROM required_tables expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.table_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'required_posting_mapping_routines',
        CASE WHEN count(DISTINCT routine.proname) = count(*)
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) - count(DISTINCT routine.proname),
        jsonb_build_object(
            'expected',count(*),
            'routine_rows',count(DISTINCT routine.proname)
        )
    FROM required_routines expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_proc routine
      ON routine.pronamespace = namespace.oid
     AND routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'required_posting_mapping_triggers',
        CASE WHEN count(trigger_state.oid) = count(*) THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE trigger_state.oid IS NULL),
        jsonb_build_object(
            'expected',count(*),'trigger_rows',count(trigger_state.oid)
        )
    FROM required_triggers expected
    LEFT JOIN pg_trigger trigger_state
      ON trigger_state.tgname = expected.trigger_name
     AND NOT trigger_state.tgisinternal
     AND trigger_state.tgenabled <> 'D'

    UNION ALL

    SELECT
        'posting_mapping_rls',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        3 - count(*),
        jsonb_build_object('table_rows',count(*))
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN (
          'posting_rule_sets','posting_rule_lines','posting_rule_set_audit'
      )
      AND relation.relrowsecurity

    UNION ALL

    SELECT
        'browser_posting_mapping_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'direct_write_relations',COALESCE(
                jsonb_agg(relation.relname ORDER BY relation.relname),
                '[]'::JSONB
            )
        )
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN (
          'posting_rule_sets','posting_rule_lines','posting_rule_set_audit'
      )
      AND has_table_privilege(
          'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
      )

    UNION ALL

    SELECT
        'required_account_mapping_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'missing_or_ambiguous_rows',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM current_rule_counts
    WHERE rule_count <> 1

    UNION ALL

    SELECT
        'active_rule_custom_account_inventory',
        'INFO',0,
        jsonb_build_object('nondefault_account_rows',count(*))
    FROM public.transaction_account_rules rule
    JOIN public.chart_of_accounts account
      ON account.company_id = rule.company_id AND account.id = rule.account_id
    WHERE rule.status = 'ACTIVE'
      AND account.system_function_key IS DISTINCT FROM rule.account_function_key

    UNION ALL

    SELECT
        'approved_rule_set_overlap',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('overlap_pairs',count(*))
    FROM public.posting_rule_sets left_set
    JOIN public.posting_rule_sets right_set
      ON right_set.company_id = left_set.company_id
     AND right_set.transaction_category_id = left_set.transaction_category_id
     AND right_set.id > left_set.id
     AND right_set.status = 'APPROVED'
     AND left_set.status = 'APPROVED'
     AND tstzrange(
         left_set.effective_from,left_set.effective_to,'[)'
     ) && tstzrange(
         right_set.effective_from,right_set.effective_to,'[)'
     )

    UNION ALL

    SELECT
        'approved_rule_set_line_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('rule_set_count',count(*))
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.status = 'APPROVED'
      AND (
          NOT EXISTS (
              SELECT 1 FROM public.posting_rule_lines line
              WHERE line.company_id = rule_set.company_id
                AND line.rule_set_id = rule_set.id
                AND line.entry_side = 'DEBIT'
          )
          OR NOT EXISTS (
              SELECT 1 FROM public.posting_rule_lines line
              WHERE line.company_id = rule_set.company_id
                AND line.rule_set_id = rule_set.id
                AND line.entry_side = 'CREDIT'
          )
          OR EXISTS (
              SELECT 1
              FROM public.system_events system_event
              CROSS JOIN LATERAL unnest(
                  system_event.required_account_functions
              ) AS required_function(function_key)
              WHERE system_event.system_key = rule_set.system_key
                AND NOT EXISTS (
                    SELECT 1 FROM public.posting_rule_lines line
                    WHERE line.company_id = rule_set.company_id
                      AND line.rule_set_id = rule_set.id
                      AND line.account_function_key =
                          required_function.function_key
                )
          )
      )

    UNION ALL

    SELECT
        'hold_event_no_early_posting',
        CASE WHEN count(*) FILTER (
            WHERE status::TEXT <> 'HOLD'
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE status::TEXT <> 'HOLD'),
        jsonb_build_object(
            'event_rows',count(*),
            'hold_rows',count(*) FILTER (WHERE status::TEXT = 'HOLD'),
            'with_rule_snapshot',count(*) FILTER (
                WHERE transaction_rule_version IS NOT NULL
            )
        )
    FROM public.financial_events

    UNION ALL

    SELECT
        'phase3_runtime_inventory',
        'INFO',0,
        jsonb_build_object(
            'transaction_rules',(
                SELECT count(*) FROM public.transaction_account_rules
            ),
            'active_transaction_rules',(
                SELECT count(*) FROM public.transaction_account_rules
                WHERE status = 'ACTIVE'
            ),
            'posting_rule_sets',(
                SELECT count(*) FROM public.posting_rule_sets
            ),
            'posting_rule_lines',(
                SELECT count(*) FROM public.posting_rule_lines
            ),
            'canonical_journals',(
                SELECT count(*) FROM public.finance_journals
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
