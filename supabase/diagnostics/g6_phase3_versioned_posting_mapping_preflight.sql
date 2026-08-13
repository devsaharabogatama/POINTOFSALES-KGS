-- G6 corrective phase 3 preflight: versioned posting mapping readiness.
--
-- SAFETY:
-- - one SELECT statement only;
-- - aggregate configuration/runtime metadata only;
-- - no DDL, DML, DO block, lock, TEMP object, or routine execution;
-- - does not post, retry, mutate, or backfill Financial Events in HOLD.

WITH required_versions(version) AS (
    VALUES
        ('20260810170000'),('20260810180000'),('20260810185000')
), rejected_g6_versions(version) AS (
    VALUES
        ('20260807180000'),('20260807190000'),('20260807200000'),
        ('20260807210000'),('20260810110000'),('20260810120000'),
        ('20260810130000'),('20260810140000'),('20260810150000')
), expected_expression_tables(table_name) AS (
    VALUES
        ('posting_rule_sets'),
        ('posting_rule_lines'),
        ('posting_rule_set_audit')
), hold_events AS (
    SELECT event.*
    FROM public.financial_events event
    WHERE event.status::TEXT = 'HOLD'
), event_amount_keys AS (
    SELECT
        event.system_event_key,
        event.event_type::TEXT AS event_type,
        event.source_table,
        amount_key.key AS amount_key,
        count(*) AS event_count
    FROM hold_events event
    CROSS JOIN LATERAL jsonb_object_keys(
        CASE WHEN jsonb_typeof(event.amounts) = 'object'
             THEN event.amounts ELSE '{}'::JSONB END
    ) amount_key(key)
    GROUP BY
        event.system_event_key,event.event_type::TEXT,
        event.source_table,amount_key.key
), event_contract_inventory AS (
    SELECT
        event.system_event_key,
        event.event_type::TEXT AS event_type,
        event.source_table,
        count(DISTINCT event.id) AS event_count,
        COALESCE(
            jsonb_agg(DISTINCT keys.amount_key ORDER BY keys.amount_key)
                FILTER (WHERE keys.amount_key IS NOT NULL),
            '[]'::JSONB
        ) AS amount_keys
    FROM hold_events event
    LEFT JOIN event_amount_keys keys
      ON keys.system_event_key IS NOT DISTINCT FROM event.system_event_key
     AND keys.event_type = event.event_type::TEXT
     AND keys.source_table IS NOT DISTINCT FROM event.source_table
    GROUP BY event.system_event_key,event.event_type::TEXT,event.source_table
), required_event_functions AS (
    SELECT
        event.id AS financial_event_id,
        event.company_id,
        event.event_date,
        event.system_event_key,
        event.transaction_category_id,
        required_function.function_key
    FROM hold_events event
    JOIN public.system_events system_event
      ON system_event.system_key = event.system_event_key
    CROSS JOIN LATERAL unnest(
        system_event.required_account_functions
    ) AS required_function(function_key)
), event_function_resolution AS (
    SELECT
        required.*,
        (SELECT count(*)
         FROM public.transaction_account_rules rule
         WHERE rule.company_id = required.company_id
           AND rule.transaction_category_id = required.transaction_category_id
           AND rule.system_key = required.system_event_key
           AND rule.account_function_key = required.function_key
           AND rule.status = 'ACTIVE'
           AND rule.effective_from <= required.event_date
           AND (
               rule.effective_to IS NULL
               OR rule.effective_to > required.event_date
           )) AS exact_rule_count,
        (SELECT count(*)
         FROM public.company_account_function_fallbacks fallback
         WHERE fallback.company_id = required.company_id
           AND fallback.account_function_key = required.function_key
           AND fallback.status = 'ACTIVE'
           AND fallback.effective_from <= required.event_date
           AND (
               fallback.effective_to IS NULL
               OR fallback.effective_to > required.event_date
           )) AS fallback_count
    FROM required_event_functions required
), active_category_required_functions AS (
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
        scope.company_id,scope.transaction_category_id,
        scope.system_key,scope.function_key,
        count(rule.id) AS exact_rule_count,
        (SELECT count(*)
         FROM public.company_account_function_fallbacks fallback
         WHERE fallback.company_id = scope.company_id
           AND fallback.account_function_key = scope.function_key
           AND fallback.status = 'ACTIVE'
           AND fallback.effective_from <= clock_timestamp()
           AND (
               fallback.effective_to IS NULL
               OR fallback.effective_to > clock_timestamp()
           )) AS fallback_count
    FROM active_category_required_functions scope
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
        'g6_phase3_dependencies'::TEXT AS check_name,
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
        'rejected_g6_migration_ledger',
        CASE WHEN count(migration.version) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'applied_count',count(migration.version),
            'applied_versions',COALESCE(
                jsonb_agg(rejected.version ORDER BY rejected.version)
                    FILTER (WHERE migration.version IS NOT NULL),
                '[]'::JSONB
            )
        )
    FROM rejected_g6_versions rejected
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = rejected.version

    UNION ALL

    SELECT
        'canonical_phase2_journal_foundation',
        CASE WHEN count(relation.oid) = 3 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',3,
            'relation_rows',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER (WHERE relation.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM (
        VALUES
            ('finance_journals'),
            ('finance_journal_lines'),
            ('finance_journal_audit')
    ) expected(table_name)
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.table_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'invalid_hold_event_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM hold_events event
    LEFT JOIN public.system_events system_event
      ON system_event.system_key = event.system_event_key
    LEFT JOIN public.transaction_categories category
      ON category.company_id = event.company_id
     AND category.id = event.transaction_category_id
    WHERE event.system_event_key IS NULL
       OR event.transaction_category_id IS NULL
       OR system_event.system_key IS NULL
       OR category.id IS NULL
       OR category.system_key IS DISTINCT FROM event.system_event_key
       OR NOT system_event.is_active
       OR NOT category.is_active
       OR jsonb_typeof(event.amounts) IS DISTINCT FROM 'object'

    UNION ALL

    SELECT
        'duplicate_financial_event_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,idempotency_key
        FROM public.financial_events
        WHERE idempotency_key IS NOT NULL
        GROUP BY company_id,idempotency_key
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'system_event_function_catalog_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('invalid_function_rows',count(*))
    FROM (
        SELECT system_event.system_key,function_row.function_key
        FROM public.system_events system_event
        CROSS JOIN LATERAL unnest(
            system_event.required_account_functions
            || system_event.conditional_account_functions
            || system_event.optional_account_functions
        ) AS function_row(function_key)
        LEFT JOIN public.account_functions function_state
          ON function_state.function_key = function_row.function_key
        WHERE btrim(COALESCE(function_row.function_key,'')) = ''
           OR function_state.function_key IS NULL
           OR NOT function_state.is_active
    ) invalid_functions

    UNION ALL

    SELECT
        'duplicate_system_event_function_role',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_rows',count(*))
    FROM (
        SELECT system_event.system_key,function_row.function_key
        FROM public.system_events system_event
        CROSS JOIN LATERAL unnest(
            system_event.required_account_functions
            || system_event.conditional_account_functions
            || system_event.optional_account_functions
        ) AS function_row(function_key)
        GROUP BY system_event.system_key,function_row.function_key
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'invalid_transaction_account_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.transaction_account_rules rule
    LEFT JOIN public.transaction_categories category
      ON category.company_id = rule.company_id
     AND category.id = rule.transaction_category_id
    LEFT JOIN public.account_functions function_state
      ON function_state.function_key = rule.account_function_key
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id = rule.company_id
     AND account.id = rule.account_id
    WHERE category.id IS NULL
       OR category.system_key IS DISTINCT FROM rule.system_key
       OR function_state.function_key IS NULL
       OR account.id IS NULL
       OR NOT account.is_active
       OR NOT account.is_postable
       OR NOT (account.account_type = ANY(function_state.compatible_account_types))
       OR (rule.status = 'ACTIVE' AND NOT category.is_active)

    UNION ALL

    SELECT
        'invalid_company_account_fallback',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.company_account_function_fallbacks fallback
    LEFT JOIN public.account_functions function_state
      ON function_state.function_key = fallback.account_function_key
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id = fallback.company_id
     AND account.id = fallback.account_id
    WHERE function_state.function_key IS NULL
       OR account.id IS NULL
       OR NOT account.is_active
       OR NOT account.is_postable
       OR NOT (account.account_type = ANY(function_state.compatible_account_types))

    UNION ALL

    SELECT
        'ambiguous_current_transaction_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('mapping_groups',count(*))
    FROM current_rule_counts
    WHERE exact_rule_count > 1

    UNION ALL

    SELECT
        'ambiguous_current_company_fallback',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('mapping_groups',count(*))
    FROM (
        SELECT company_id,account_function_key
        FROM public.company_account_function_fallbacks
        WHERE status = 'ACTIVE'
          AND effective_from <= clock_timestamp()
          AND (effective_to IS NULL OR effective_to > clock_timestamp())
        GROUP BY company_id,account_function_key
        HAVING count(*) > 1
    ) ambiguous

    UNION ALL

    SELECT
        'hold_event_ambiguous_account_resolution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_function_rows',count(*))
    FROM event_function_resolution
    WHERE exact_rule_count > 1
       OR (exact_rule_count = 0 AND fallback_count > 1)

    UNION ALL

    SELECT
        'active_category_required_mapping_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'missing_mapping_rows',count(*),
            'categories_affected',count(DISTINCT transaction_category_id),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM current_rule_counts
    WHERE exact_rule_count = 0 AND fallback_count = 0

    UNION ALL

    SELECT
        'hold_event_required_mapping_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'missing_event_function_rows',count(*),
            'events_affected',count(DISTINCT financial_event_id),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM event_function_resolution
    WHERE exact_rule_count = 0 AND fallback_count = 0

    UNION ALL

    SELECT
        'compatible_account_candidate_scope',
        CASE WHEN count(*) FILTER (WHERE compatible_accounts = 0) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'company_function_rows',count(*),
            'without_compatible_account',count(*) FILTER (
                WHERE compatible_accounts = 0
            )
        )
    FROM (
        SELECT
            scope.company_id,scope.function_key,
            count(DISTINCT account.id) AS compatible_accounts
        FROM active_category_required_functions scope
        JOIN public.account_functions function_state
          ON function_state.function_key = scope.function_key
        LEFT JOIN public.chart_of_accounts account
          ON account.company_id = scope.company_id
         AND account.is_active
         AND account.is_postable
         AND account.account_type = ANY(function_state.compatible_account_types)
        GROUP BY scope.company_id,scope.function_key
    ) candidates

    UNION ALL

    SELECT
        'explicit_system_function_account_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'unresolved_company_function_rows',count(*),
            'companies_affected',count(DISTINCT company_id),
            'unresolved_functions',COALESCE(
                jsonb_agg(jsonb_build_object(
                    'functionKey',function_key,
                    'systemAccountCount',system_account_count,
                    'explicitAccountCount',explicit_account_count
                ) ORDER BY function_key),
                '[]'::JSONB
            )
        )
    FROM (
        SELECT
            missing.company_id,missing.function_key,
            count(DISTINCT account.id) AS explicit_account_count,
            count(DISTINCT account.id) FILTER (
                WHERE account.is_system_account
            ) AS system_account_count
        FROM current_rule_counts missing
        LEFT JOIN public.chart_of_accounts account
          ON account.company_id = missing.company_id
         AND account.system_function_key = missing.function_key
         AND account.is_active
         AND account.is_postable
        WHERE missing.exact_rule_count = 0
          AND missing.fallback_count = 0
        GROUP BY missing.company_id,missing.function_key
        HAVING NOT (
            count(DISTINCT account.id) FILTER (
                WHERE account.is_system_account
            ) = 1
            OR (
                count(DISTINCT account.id) FILTER (
                    WHERE account.is_system_account
                ) = 0
                AND count(DISTINCT account.id) = 1
            )
        )
    ) unresolved

    UNION ALL

    SELECT
        'canonical_posting_expression_model_state',
        CASE WHEN count(relation.oid) = count(*) THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_tables',count(*),
            'missing_tables',COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER (WHERE relation.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_expression_tables expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.table_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'hold_event_rule_snapshot_state',
        CASE WHEN count(*) FILTER (
            WHERE transaction_rule_version IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'hold_events',count(*),
            'without_rule_version',count(*) FILTER (
                WHERE transaction_rule_version IS NULL
            )
        )
    FROM hold_events

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
        'hold_event_source_amount_contract_inventory',
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
    FROM event_contract_inventory

    UNION ALL

    SELECT
        'versioned_mapping_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'active_transaction_categories',(
                SELECT count(*) FROM public.transaction_categories
                WHERE is_active
            ),
            'active_system_events',(
                SELECT count(*) FROM public.system_events WHERE is_active
            ),
            'active_transaction_rules',(
                SELECT count(*) FROM public.transaction_account_rules
                WHERE status = 'ACTIVE'
            ),
            'active_company_fallbacks',(
                SELECT count(*) FROM public.company_account_function_fallbacks
                WHERE status = 'ACTIVE'
            ),
            'hold_events',(SELECT count(*) FROM hold_events),
            'canonical_journals',(SELECT count(*) FROM public.finance_journals)
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
