-- G6 corrective phase 2 preflight: tenant-safe period/journal foundation.
--
-- SAFETY:
-- - one SELECT statement only;
-- - aggregate catalog/business counts only;
-- - no DDL, DML, DO block, lock, TEMP object, or business routine execution;
-- - does not assume that rejected/partial G6 objects are canonical.

WITH required_versions(version) AS (
    VALUES
        ('20260806100000'),
        ('20260807150000'),
        ('20260810160000'),
        ('20260810170000')
), rejected_g6_versions(version) AS (
    VALUES
        ('20260807180000'),('20260807190000'),('20260807200000'),
        ('20260807210000'),('20260810110000'),('20260810120000'),
        ('20260810130000'),('20260810140000'),('20260810150000')
), unsafe_routine_names(routine_name) AS (
    VALUES
        ('post_financial_event'),('post_pending_financial_events'),
        ('ensure_accounting_period_open'),('resolve_account_for_function'),
        ('resolve_account_by_code'),('get_general_ledger_report'),
        ('get_trial_balance_report'),('get_income_statement_report'),
        ('get_balance_sheet_report'),('get_account_journal_lines')
), finance_relation_names(relation_name) AS (
    VALUES
        ('financial_events'),('journal_entries'),('accounting_periods'),
        ('journal_lines'),('finance_posting_exceptions'),
        ('finance_journals'),('finance_journal_lines'),
        ('finance_journal_audit')
), expected_period_columns(column_name) AS (
    VALUES
        ('id'),('company_id'),('period_start'),('period_end'),('status'),
        ('master_version'),('created_at'),('updated_at')
), finance_relations AS (
    SELECT relation.oid,relation.relname,relation.relrowsecurity
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    JOIN finance_relation_names expected
      ON expected.relation_name = relation.relname
    WHERE namespace.nspname = 'public'
      AND relation.relkind IN ('r','p')
), relation_columns AS (
    SELECT
        relation.relname,
        COALESCE(
            jsonb_agg(attribute.attname ORDER BY attribute.attnum)
                FILTER (
                    WHERE attribute.attnum > 0 AND NOT attribute.attisdropped
                ),
            '[]'::jsonb
        ) AS columns
    FROM finance_relations relation
    LEFT JOIN pg_attribute attribute ON attribute.attrelid = relation.oid
    GROUP BY relation.relname
), relation_constraints AS (
    SELECT
        relation.relname,
        count(constraint_state.oid) FILTER (
            WHERE constraint_state.contype = 'p'
        ) AS primary_keys,
        count(constraint_state.oid) FILTER (
            WHERE constraint_state.contype = 'u'
        ) AS unique_constraints,
        count(constraint_state.oid) FILTER (
            WHERE constraint_state.contype = 'f'
        ) AS foreign_keys,
        count(constraint_state.oid) FILTER (
            WHERE constraint_state.contype = 'c'
        ) AS check_constraints
    FROM finance_relations relation
    LEFT JOIN pg_constraint constraint_state
      ON constraint_state.conrelid = relation.oid
    GROUP BY relation.relname
), relation_runtime AS (
    SELECT
        relation.relname,
        relation.relrowsecurity,
        COALESCE(statistics.n_live_tup,0) AS estimated_rows,
        (SELECT count(*) FROM pg_trigger trigger_state
         WHERE trigger_state.tgrelid = relation.oid
           AND NOT trigger_state.tgisinternal
           AND trigger_state.tgenabled <> 'D') AS enabled_triggers,
        (SELECT count(*) FROM pg_policy policy_state
         WHERE policy_state.polrelid = relation.oid) AS policies
    FROM finance_relations relation
    LEFT JOIN pg_stat_user_tables statistics
      ON statistics.relid = relation.oid
), checks AS (
    SELECT
        'g6_phase2_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::jsonb
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
                '[]'::jsonb
            )
        )
    FROM rejected_g6_versions rejected
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = rejected.version

    UNION ALL

    SELECT
        'unsafe_finance_routine_quarantine',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authenticated_executable_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(DISTINCT routine.proname ORDER BY routine.proname),
                '[]'::jsonb
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
        'browser_direct_finance_runtime_write',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'writable_relations',COALESCE(
                jsonb_agg(relation.relname ORDER BY relation.relname),
                '[]'::jsonb
            )
        )
    FROM finance_relations relation
    WHERE has_table_privilege(
              'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
          )

    UNION ALL

    SELECT
        'existing_finance_runtime_rls',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'relations_without_rls',COALESCE(
                jsonb_agg(relation.relname ORDER BY relation.relname),
                '[]'::jsonb
            )
        )
    FROM finance_relations relation
    WHERE NOT relation.relrowsecurity

    UNION ALL

    SELECT
        'accounting_period_minimum_contract',
        CASE WHEN count(*) FILTER (
            WHERE column_state.column_name IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'table_exists',to_regclass('public.accounting_periods') IS NOT NULL,
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_period_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema = 'public'
     AND column_state.table_name = 'accounting_periods'
     AND column_state.column_name = expected.column_name

    UNION ALL

    SELECT
        'journal_line_legacy_header_collision',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'journal_lines_fk_to_legacy_journal_entries',count(*),
            'constraint_names',COALESCE(
                jsonb_agg(constraint_state.conname ORDER BY constraint_state.conname),
                '[]'::jsonb
            )
        )
    FROM pg_constraint constraint_state
    JOIN pg_class source_relation
      ON source_relation.oid = constraint_state.conrelid
    JOIN pg_namespace source_namespace
      ON source_namespace.oid = source_relation.relnamespace
    JOIN pg_class target_relation
      ON target_relation.oid = constraint_state.confrelid
    JOIN pg_namespace target_namespace
      ON target_namespace.oid = target_relation.relnamespace
    WHERE constraint_state.contype = 'f'
      AND source_namespace.nspname = 'public'
      AND source_relation.relname = 'journal_lines'
      AND target_namespace.nspname = 'public'
      AND target_relation.relname = 'journal_entries'

    UNION ALL

    SELECT
        'unbalanced_legacy_journal_group',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('group_count',count(*))
    FROM (
        SELECT company_id,entry_group_id
        FROM public.journal_entries
        GROUP BY company_id,entry_group_id
        HAVING round(COALESCE(sum(debit),0),4)
             <> round(COALESCE(sum(kredit),0),4)
    ) unbalanced_groups

    UNION ALL

    SELECT
        'legacy_journal_tenant_event_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_or_cross_company_rows',count(*))
    FROM public.journal_entries journal
    LEFT JOIN public.financial_events event
      ON event.id = journal.financial_event_id
     AND event.company_id = journal.company_id
    WHERE journal.financial_event_id IS NOT NULL
      AND event.id IS NULL

    UNION ALL

    SELECT
        'legacy_journal_account_snapshot_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM public.journal_entries
    WHERE account_id IS NULL
       OR btrim(COALESCE(account_code_snapshot,'')) = ''
       OR btrim(COALESCE(account_name_snapshot,'')) = ''

    UNION ALL

    SELECT
        'hold_event_mapping_inventory',
        'INFO',
        jsonb_build_object(
            'hold_events',count(*),
            'without_system_event',count(*) FILTER (
                WHERE system_event_key IS NULL
            ),
            'without_transaction_category',count(*) FILTER (
                WHERE transaction_category_id IS NULL
            ),
            'without_rule_version',count(*) FILTER (
                WHERE transaction_rule_version IS NULL
            )
        )
    FROM public.financial_events
    WHERE status::TEXT = 'HOLD'

    UNION ALL

    SELECT
        'finance_relation_column_inventory',
        'INFO',
        COALESCE(
            jsonb_object_agg(relname,columns ORDER BY relname),
            '{}'::jsonb
        )
    FROM relation_columns

    UNION ALL

    SELECT
        'finance_relation_constraint_inventory',
        'INFO',
        COALESCE(
            jsonb_object_agg(
                relname,
                jsonb_build_object(
                    'primary_keys',primary_keys,
                    'unique_constraints',unique_constraints,
                    'foreign_keys',foreign_keys,
                    'check_constraints',check_constraints
                ) ORDER BY relname
            ),
            '{}'::jsonb
        )
    FROM relation_constraints

    UNION ALL

    SELECT
        'finance_relation_runtime_inventory',
        'INFO',
        COALESCE(
            jsonb_object_agg(
                relname,
                jsonb_build_object(
                    'estimated_rows',estimated_rows,
                    'rls_enabled',relrowsecurity,
                    'enabled_triggers',enabled_triggers,
                    'policies',policies
                ) ORDER BY relname
            ),
            '{}'::jsonb
        )
    FROM relation_runtime

    UNION ALL

    SELECT
        'canonical_additive_name_inventory',
        'INFO',
        jsonb_build_object(
            'finance_journals_exists',
                to_regclass('public.finance_journals') IS NOT NULL,
            'finance_journal_lines_exists',
                to_regclass('public.finance_journal_lines') IS NOT NULL,
            'finance_journal_audit_exists',
                to_regclass('public.finance_journal_audit') IS NOT NULL
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
