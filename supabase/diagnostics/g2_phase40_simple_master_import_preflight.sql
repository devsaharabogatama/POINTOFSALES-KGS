-- G2 phase 40 preflight: remaining simple master Import/Export readiness.
--
-- Scope:
-- - Customer Category (code-less, system category export-only);
-- - Chart of Account (business account code remains user-facing);
-- - Transaction Category (code-less, required defaults export-only).
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes business names/codes.

WITH RECURSIVE coa_walk AS (
    SELECT
        coa.company_id,
        coa.id AS origin_id,
        coa.id,
        coa.parent_account_id,
        ARRAY[coa.id]::UUID[] AS path,
        FALSE AS cycle,
        1 AS depth
    FROM public.chart_of_accounts coa

    UNION ALL

    SELECT
        walk.company_id,
        walk.origin_id,
        parent.id,
        parent.parent_account_id,
        walk.path || parent.id,
        parent.id = ANY(walk.path),
        walk.depth + 1
    FROM coa_walk walk
    JOIN public.chart_of_accounts parent
      ON parent.company_id = walk.company_id
     AND parent.id = walk.parent_account_id
    WHERE NOT walk.cycle
      AND walk.depth < 10
), checks AS (
    SELECT
        'g2_phase38_dependency'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260724040000'

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'job_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status NOT IN (
        'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
    )

    UNION ALL

    SELECT
        'remaining_import_type_contract','INFO',
        jsonb_build_object(
            'customer_category_supported',
                pg_get_constraintdef(c.oid) LIKE '%CUSTOMER_CATEGORY%',
            'chart_of_account_supported',
                pg_get_constraintdef(c.oid) LIKE '%CHART_OF_ACCOUNT%',
            'transaction_category_supported',
                pg_get_constraintdef(c.oid) LIKE '%TRANSACTION_CATEGORY%'
        )
    FROM pg_constraint c
    JOIN pg_class rel ON rel.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND rel.relname = 'master_import_jobs'
      AND c.conname = 'master_import_jobs_type_check'

    UNION ALL

    SELECT
        'required_guarded_rpc_state',
        CASE WHEN
            to_regprocedure(
                'public.save_customer_category(uuid,bigint,text,boolean)'
            ) IS NOT NULL
            AND to_regprocedure(
                'public.save_transaction_category(uuid,bigint,text,text,text,boolean)'
            ) IS NOT NULL
            AND to_regprocedure(
                'public.save_chart_of_account(uuid,bigint,text,text,text,text,uuid,text,boolean,boolean,boolean,boolean)'
            ) IS NOT NULL
        THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'customer_category_rpc',
                to_regprocedure(
                    'public.save_customer_category(uuid,bigint,text,boolean)'
                ) IS NOT NULL,
            'transaction_category_rpc',
                to_regprocedure(
                    'public.save_transaction_category(uuid,bigint,text,text,text,boolean)'
                ) IS NOT NULL,
            'chart_of_account_rpc',
                to_regprocedure(
                    'public.save_chart_of_account(uuid,bigint,text,text,text,text,uuid,text,boolean,boolean,boolean,boolean)'
                ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'blank_customer_category_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.customer_categories
    WHERE btrim(category_name) = ''

    UNION ALL

    SELECT
        'duplicate_normalized_customer_category_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,
            lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
        FROM public.customer_categories
        GROUP BY
            company_id,
            lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'customer_category_inventory','INFO',
        jsonb_build_object(
            'rows',count(*),
            'active_rows',count(*) FILTER (WHERE is_active),
            'system_rows',count(*) FILTER (WHERE is_system_category),
            'rows_with_customers',count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM public.customers customer
                    WHERE customer.company_id =
                        customer_categories.company_id
                      AND customer.customer_category_id =
                        customer_categories.id
                )
            )
        )
    FROM public.customer_categories

    UNION ALL

    SELECT
        'blank_coa_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.chart_of_accounts
    WHERE btrim(account_code) = '' OR btrim(account_name) = ''

    UNION ALL

    SELECT
        'duplicate_normalized_coa_code',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,
            upper(regexp_replace(btrim(account_code),'\s+',' ','g'))
        FROM public.chart_of_accounts
        GROUP BY
            company_id,
            upper(regexp_replace(btrim(account_code),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'duplicate_normalized_coa_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,
            lower(regexp_replace(btrim(account_name),'\s+',' ','g'))
        FROM public.chart_of_accounts
        GROUP BY
            company_id,
            lower(regexp_replace(btrim(account_name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'coa_hierarchy_cycle_or_depth',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('account_count',count(DISTINCT origin_id))
    FROM coa_walk
    WHERE cycle OR depth > 3

    UNION ALL

    SELECT
        'postable_parent_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.chart_of_accounts parent
    WHERE parent.is_postable
      AND EXISTS (
          SELECT 1
          FROM public.chart_of_accounts child
          WHERE child.company_id = parent.company_id
            AND child.parent_account_id = parent.id
      )

    UNION ALL

    SELECT
        'coa_import_inventory','INFO',
        jsonb_build_object(
            'rows',count(*),
            'active_rows',count(*) FILTER (WHERE is_active),
            'system_rows',count(*) FILTER (WHERE is_system_account),
            'parent_rows',count(*) FILTER (WHERE parent_account_id IS NOT NULL),
            'rows_with_journal_history',count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM public.journal_entries entry
                    WHERE entry.company_id = chart_of_accounts.company_id
                      AND entry.account_id = chart_of_accounts.id
                )
            )
        )
    FROM public.chart_of_accounts

    UNION ALL

    SELECT
        'blank_transaction_category_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.transaction_categories
    WHERE btrim(category_name) = ''

    UNION ALL

    SELECT
        'duplicate_normalized_transaction_category_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,
            lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
        FROM public.transaction_categories
        GROUP BY
            company_id,
            lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'invalid_transaction_category_system_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.transaction_categories category
    LEFT JOIN public.system_events event
      ON event.system_key = category.system_key
    WHERE event.system_key IS NULL
       OR (category.is_active AND NOT event.is_active)

    UNION ALL

    SELECT
        'transaction_category_inventory','INFO',
        jsonb_build_object(
            'rows',count(*),
            'active_rows',count(*) FILTER (WHERE is_active),
            'required_default_rows',
                count(*) FILTER (WHERE is_system_default),
            'custom_rows',count(*) FILTER (WHERE NOT is_system_default),
            'rows_with_account_rules',count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM public.transaction_account_rules rule
                    WHERE rule.company_id = transaction_categories.company_id
                      AND rule.transaction_category_id =
                          transaction_categories.id
                )
            )
        )
    FROM public.transaction_categories

    UNION ALL

    SELECT
        'direct_simple_master_write_privilege','INFO',
        jsonb_build_object(
            'customer_categories_write',has_table_privilege(
                'authenticated','public.customer_categories',
                'INSERT,UPDATE,DELETE'
            ),
            'chart_of_accounts_write',has_table_privilege(
                'authenticated','public.chart_of_accounts',
                'INSERT,UPDATE,DELETE'
            ),
            'transaction_categories_write',has_table_privilege(
                'authenticated','public.transaction_categories',
                'INSERT,UPDATE,DELETE'
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
