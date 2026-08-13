-- G6 corrective phase 1 preflight: Finance posting safety/readiness.
--
-- SAFETY:
-- - one SELECT statement only;
-- - no DDL, DML, DO block, TEMP object, lock, or function execution;
-- - aggregate metadata only; no Company name, source payload, or business row;
-- - detects any partial rollout of the rejected 20260807/20260810 G6 drafts.

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
), canonical_rule_columns(column_name) AS (
    VALUES
        ('transaction_category_id'),('system_key'),
        ('account_function_key'),('account_id'),('effective_from')
), unsafe_routine_names(routine_name) AS (
    VALUES
        ('post_financial_event'),('post_pending_financial_events'),
        ('ensure_accounting_period_open'),('resolve_account_for_function'),
        ('resolve_account_by_code'),('get_general_ledger_report'),
        ('get_trial_balance_report'),('get_income_statement_report'),
        ('get_balance_sheet_report'),('get_account_journal_lines')
), event_inventory AS (
    SELECT
        count(*) AS event_rows,
        count(*) FILTER (WHERE status::text = 'HOLD') AS hold_rows,
        count(*) FILTER (WHERE status::text = 'POSTED') AS posted_rows,
        count(*) FILTER (WHERE status::text IN ('FAILED','ERROR')) AS failed_rows,
        count(DISTINCT company_id) AS companies,
        count(DISTINCT event_type::text) AS event_types
    FROM public.financial_events
), journal_inventory AS (
    SELECT
        count(*) AS journal_rows,
        count(*) FILTER (WHERE financial_event_id IS NOT NULL)
            AS event_linked_rows,
        count(DISTINCT company_id) AS companies,
        COALESCE(sum(debit),0) AS debit_total,
        COALESCE(sum(kredit),0) AS credit_total
    FROM public.journal_entries
), checks AS (
    SELECT
        'g6_corrective_dependencies'::text AS check_name,
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
        'canonical_transaction_rule_requiredness',
        CASE WHEN count(*) FILTER (
            WHERE column_state.column_name IS NULL
               OR column_state.is_nullable <> 'NO'
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'invalid_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (
                        WHERE column_state.column_name IS NULL
                           OR column_state.is_nullable <> 'NO'
                    ),
                '[]'::jsonb
            )
        )
    FROM canonical_rule_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema = 'public'
     AND column_state.table_name = 'transaction_account_rules'
     AND column_state.column_name = expected.column_name

    UNION ALL

    SELECT
        'canonical_transaction_rule_history_guard',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_state
    JOIN pg_class relation ON relation.oid = trigger_state.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'transaction_account_rules'
      AND trigger_state.tgname = 'g2_guard_transaction_account_rules'
      AND NOT trigger_state.tgisinternal
      AND trigger_state.tgenabled <> 'D'

    UNION ALL

    SELECT
        'unsafe_authenticated_finance_routine_execution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'executable_rows',count(*),
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
        'browser_direct_journal_write_boundary',
        CASE WHEN has_table_privilege(
                      'authenticated','public.journal_entries',
                      'INSERT,UPDATE,DELETE'
                  )
             THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object(
            'journal_entries_write',has_table_privilege(
                'authenticated','public.journal_entries',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'posted_event_without_journal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM public.financial_events event
    WHERE event.status::text = 'POSTED'
      AND NOT EXISTS (
          SELECT 1 FROM public.journal_entries journal
          WHERE journal.company_id = event.company_id
            AND journal.financial_event_id = event.id
      )

    UNION ALL

    SELECT
        'journal_without_financial_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM public.journal_entries journal
    LEFT JOIN public.financial_events event
      ON event.company_id = journal.company_id
     AND event.id = journal.financial_event_id
    WHERE journal.financial_event_id IS NOT NULL
      AND event.id IS NULL

    UNION ALL

    SELECT
        'duplicate_journal_per_financial_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,financial_event_id
        FROM public.journal_entries
        WHERE financial_event_id IS NOT NULL
        GROUP BY company_id,financial_event_id
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'cross_company_event_journal_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.journal_entries journal
    JOIN public.financial_events event ON event.id = journal.financial_event_id
    WHERE journal.company_id <> event.company_id

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
        'invalid_active_transaction_account_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.transaction_account_rules rule
    LEFT JOIN public.transaction_categories category
      ON category.company_id = rule.company_id
     AND category.id = rule.transaction_category_id
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id = rule.company_id
     AND account.id = rule.account_id
    LEFT JOIN public.account_functions function_state
      ON function_state.function_key = rule.account_function_key
    WHERE rule.status = 'ACTIVE'
      AND (
          category.id IS NULL OR NOT category.is_active
          OR account.id IS NULL OR NOT account.is_active
          OR NOT account.is_postable
          OR function_state.function_key IS NULL
          OR NOT function_state.is_active
          OR rule.approved_by IS NULL OR rule.approved_at IS NULL
      )

    UNION ALL

    SELECT
        'multiple_current_active_transaction_rules',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,transaction_category_id,account_function_key
        FROM public.transaction_account_rules
        WHERE status = 'ACTIVE'
          AND effective_from <= clock_timestamp()
          AND (effective_to IS NULL OR effective_to > clock_timestamp())
        GROUP BY company_id,transaction_category_id,account_function_key
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'active_company_without_postable_coa',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    WHERE company.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1 FROM public.chart_of_accounts account
          WHERE account.company_id = company.id
            AND account.is_active AND account.is_postable
      )

    UNION ALL

    SELECT
        'finance_runtime_schema_state',
        'INFO',
        jsonb_build_object(
            'accounting_periods_exists',
                to_regclass('public.accounting_periods') IS NOT NULL,
            'journal_lines_exists',
                to_regclass('public.journal_lines') IS NOT NULL,
            'posting_exception_queue_exists',
                to_regclass('public.finance_posting_exceptions') IS NOT NULL
        )

    UNION ALL

    SELECT
        'financial_event_inventory',
        'INFO',
        to_jsonb(event_inventory)
    FROM event_inventory

    UNION ALL

    SELECT
        'legacy_journal_inventory',
        'INFO',
        to_jsonb(journal_inventory)
    FROM journal_inventory

    UNION ALL

    SELECT
        'canonical_finance_master_inventory',
        'INFO',
        jsonb_build_object(
            'active_transaction_categories',(
                SELECT count(*) FROM public.transaction_categories
                WHERE is_active
            ),
            'active_transaction_rules',(
                SELECT count(*) FROM public.transaction_account_rules
                WHERE status = 'ACTIVE'
            ),
            'active_company_fallbacks',(
                SELECT count(*)
                FROM public.company_account_function_fallbacks
                WHERE status = 'ACTIVE'
            ),
            'active_postable_accounts',(
                SELECT count(*) FROM public.chart_of_accounts
                WHERE is_active AND is_postable
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'BACKFILL' THEN 2
        WHEN 'REVIEW' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
