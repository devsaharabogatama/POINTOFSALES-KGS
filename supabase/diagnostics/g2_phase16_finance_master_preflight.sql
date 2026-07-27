-- G2 phase 16 preflight: Transaction Category and minimum COA readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Expense description or business row.
-- - Does not activate the Finance worker, journal posting, or resolver.

WITH required_versions(version) AS (
    VALUES ('20260722120000')
), expected_tables(table_name) AS (
    VALUES
        ('account_functions'),
        ('system_events'),
        ('chart_of_accounts'),
        ('transaction_categories'),
        ('transaction_account_rules'),
        ('company_account_function_fallbacks'),
        ('finance_posting_exceptions')
), expected_journal_columns(column_name) AS (
    VALUES
        ('account_id'),
        ('account_code_snapshot'),
        ('account_name_snapshot'),
        ('system_event_key'),
        ('transaction_category_id'),
        ('transaction_rule_version')
), normalized_expense_categories AS (
    SELECT
        ca.company_id,
        ca.category,
        upper(regexp_replace(btrim(ca.category), '\s+', ' ', 'g'))
            AS normalized_category
    FROM public.cash_advances ca
), normalized_legacy_coa AS (
    SELECT
        je.company_id,
        upper(regexp_replace(btrim(je.coa_code), '\s+', ' ', 'g'))
            AS normalized_code,
        lower(regexp_replace(btrim(je.coa_name), '\s+', ' ', 'g'))
            AS normalized_name
    FROM public.journal_entries je
), journal_group_balance AS (
    SELECT
        company_id,
        entry_group_id,
        COALESCE(sum(debit),0) AS total_debit,
        COALESCE(sum(kredit),0) AS total_credit
    FROM public.journal_entries
    GROUP BY company_id,entry_group_id
), checks AS (
    SELECT
        'g2_phase14_dependency'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'canonical_finance_master_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (
                        WHERE to_regclass('public.' || e.table_name) IS NULL
                    ),
                '[]'::jsonb
            )
        )
    FROM expected_tables e

    UNION ALL

    SELECT
        'journal_finance_snapshot_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_journal_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'journal_entries'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'active_company_coa_provision_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'active_companies',count(*),
            'companies_to_provision',count(*)
        )
    FROM public.companies
    WHERE status = 'ACTIVE'

    UNION ALL

    SELECT
        'legacy_expense_category_inventory',
        'INFO',
        jsonb_build_object(
            'expense_rows',count(*),
            'companies',count(DISTINCT company_id),
            'normalized_category_groups',
                count(DISTINCT (company_id,normalized_category))
        )
    FROM normalized_expense_categories

    UNION ALL

    SELECT
        'blank_legacy_expense_category',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM normalized_expense_categories
    WHERE normalized_category = ''

    UNION ALL

    SELECT
        'legacy_expense_category_normalization_collisions',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('collision_groups',count(*))
    FROM (
        SELECT company_id,normalized_category
        FROM normalized_expense_categories
        WHERE normalized_category <> ''
        GROUP BY company_id,normalized_category
        HAVING count(DISTINCT category) > 1
    ) collision_groups

    UNION ALL

    SELECT
        'legacy_expense_category_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('category_groups',count(*))
    FROM (
        SELECT DISTINCT company_id,normalized_category
        FROM normalized_expense_categories
        WHERE normalized_category <> ''
    ) category_groups

    UNION ALL

    SELECT
        'legacy_finance_event_inventory',
        'INFO',
        jsonb_build_object(
            'event_rows',count(*),
            'companies',count(DISTINCT company_id),
            'processed_rows',count(*) FILTER (WHERE processed_at IS NOT NULL),
            'error_rows',count(*) FILTER (WHERE error_message IS NOT NULL)
        )
    FROM public.financial_events

    UNION ALL

    SELECT
        'legacy_journal_coa_inventory',
        'INFO',
        jsonb_build_object(
            'journal_lines',count(*),
            'companies',count(DISTINCT company_id),
            'normalized_account_identities',
                count(DISTINCT (company_id,normalized_code,normalized_name))
        )
    FROM normalized_legacy_coa

    UNION ALL

    SELECT
        'blank_legacy_journal_coa_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM normalized_legacy_coa
    WHERE normalized_code = '' OR normalized_name = ''

    UNION ALL

    SELECT
        'legacy_journal_coa_code_conflicts',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('conflict_groups',count(*))
    FROM (
        SELECT company_id,normalized_code
        FROM normalized_legacy_coa
        GROUP BY company_id,normalized_code
        HAVING count(DISTINCT normalized_name) > 1
    ) conflict_groups

    UNION ALL

    SELECT
        'legacy_journal_coa_name_conflicts',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('conflict_groups',count(*))
    FROM (
        SELECT company_id,normalized_name
        FROM normalized_legacy_coa
        GROUP BY company_id,normalized_name
        HAVING count(DISTINCT normalized_code) > 1
    ) conflict_groups

    UNION ALL

    SELECT
        'invalid_legacy_journal_line_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.journal_entries
    WHERE debit < 0
       OR kredit < 0
       OR (debit = 0 AND kredit = 0)
       OR (debit > 0 AND kredit > 0)

    UNION ALL

    SELECT
        'unbalanced_legacy_journal_groups',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('group_count',count(*))
    FROM journal_group_balance
    WHERE total_debit <> total_credit

    UNION ALL

    SELECT
        'payment_account_function_inventory',
        'INFO',
        jsonb_build_object(
            'payment_methods',count(DISTINCT pm.id),
            'clearing_function_rows',count(DISTINCT pm.id) FILTER (
                WHERE pm.clearing_account_function IS NOT NULL
            ),
            'bank_function_rows',count(DISTINCT pm.id) FILTER (
                WHERE pm.bank_account_function IS NOT NULL
            ),
            'distinct_functions',count(DISTINCT account_function)
        )
    FROM public.payment_methods pm
    CROSS JOIN LATERAL unnest(ARRAY[
        pm.clearing_account_function,
        pm.bank_account_function
    ]) AS function_values(account_function)

    UNION ALL

    SELECT
        'blank_payment_account_function',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.payment_methods pm
    CROSS JOIN LATERAL unnest(ARRAY[
        pm.clearing_account_function,
        pm.bank_account_function
    ]) AS function_values(account_function)
    WHERE account_function IS NOT NULL
      AND btrim(account_function) = ''

    UNION ALL

    SELECT
        'direct_finance_write_privilege',
        'INFO',
        jsonb_build_object(
            'financial_events_insert',has_table_privilege(
                'authenticated','public.financial_events','INSERT'
            ),
            'journal_entries_insert',has_table_privilege(
                'authenticated','public.journal_entries','INSERT'
            ),
            'journal_entries_update',has_table_privilege(
                'authenticated','public.journal_entries','UPDATE'
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
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
