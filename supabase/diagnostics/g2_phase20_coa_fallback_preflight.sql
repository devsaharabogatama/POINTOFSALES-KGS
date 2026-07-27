-- G2 phase 20 preflight: guarded COA and explicit Company fallback readiness.
-- SAFETY: SELECT-only; aggregate results only, no account/business row values.

WITH RECURSIVE active_companies AS (
    SELECT id FROM public.companies WHERE status = 'ACTIVE'
), category_requirements AS (
    SELECT
        tc.company_id,
        tc.id AS transaction_category_id,
        required.function_key
    FROM public.transaction_categories tc
    JOIN public.system_events se ON se.system_key = tc.system_key
    CROSS JOIN LATERAL unnest(se.required_account_functions)
        AS required(function_key)
    WHERE tc.is_system_default
      AND tc.is_active
      AND se.is_active
), active_rules AS (
    SELECT
        company_id,transaction_category_id,account_function_key
    FROM public.transaction_account_rules
    WHERE status = 'ACTIVE'
      AND effective_from <= clock_timestamp()
      AND (effective_to IS NULL OR effective_to > clock_timestamp())
), active_fallbacks AS (
    SELECT company_id,account_function_key
    FROM public.company_account_function_fallbacks
    WHERE status = 'ACTIVE'
      AND effective_from <= clock_timestamp()
      AND (effective_to IS NULL OR effective_to > clock_timestamp())
), account_walk AS (
    SELECT
        coa.company_id,coa.id AS origin_id,coa.id,coa.parent_account_id,
        ARRAY[coa.id]::UUID[] AS path,FALSE AS cycle,1 AS depth
    FROM public.chart_of_accounts coa

    UNION ALL

    SELECT
        walk.company_id,walk.origin_id,parent.id,parent.parent_account_id,
        walk.path || parent.id,parent.id = ANY(walk.path),walk.depth + 1
    FROM account_walk walk
    JOIN public.chart_of_accounts parent
      ON parent.company_id = walk.company_id
     AND parent.id = walk.parent_account_id
    WHERE NOT walk.cycle AND walk.depth < 10
), checks AS (
    SELECT
        'g2_phase19_dependency'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722210000'

    UNION ALL

    SELECT
        'finance_master_inventory','INFO',
        jsonb_build_object(
            'active_companies',(SELECT count(*) FROM active_companies),
            'accounts',(SELECT count(*) FROM public.chart_of_accounts),
            'active_postable_accounts',(
                SELECT count(*) FROM public.chart_of_accounts
                WHERE is_active AND is_postable
            ),
            'required_categories',(
                SELECT count(*) FROM public.transaction_categories
                WHERE is_system_default AND is_active
            ),
            'rules',(SELECT count(*) FROM public.transaction_account_rules),
            'fallbacks',(
                SELECT count(*) FROM public.company_account_function_fallbacks
            )
        )

    UNION ALL

    SELECT
        'coa_blank_identity',
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
        SELECT company_id,
               upper(regexp_replace(btrim(account_code),'\s+',' ','g'))
        FROM public.chart_of_accounts
        GROUP BY company_id,
                 upper(regexp_replace(btrim(account_code),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'duplicate_normalized_coa_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,
               lower(regexp_replace(btrim(account_name),'\s+',' ','g'))
        FROM public.chart_of_accounts
        GROUP BY company_id,
                 lower(regexp_replace(btrim(account_name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'coa_hierarchy_cycle_or_depth',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('account_count',count(DISTINCT origin_id))
    FROM account_walk
    WHERE cycle OR depth > 3

    UNION ALL

    SELECT
        'postable_parent_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.chart_of_accounts parent
    WHERE parent.is_postable
      AND EXISTS (
          SELECT 1 FROM public.chart_of_accounts child
          WHERE child.company_id = parent.company_id
            AND child.parent_account_id = parent.id
      )

    UNION ALL

    SELECT
        'coa_normal_balance_override',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM public.chart_of_accounts
    WHERE normal_balance <> CASE
        WHEN account_type IN ('ASSET','COGS','EXPENSE','OTHER_EXPENSE')
            THEN 'DEBIT'
        ELSE 'CREDIT'
    END

    UNION ALL

    SELECT
        'required_function_without_compatible_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_function_count',count(*))
    FROM (
        SELECT c.id,af.function_key
        FROM active_companies c
        CROSS JOIN public.account_functions af
        WHERE af.is_active
          AND NOT EXISTS (
              SELECT 1 FROM public.chart_of_accounts coa
              WHERE coa.company_id = c.id
                AND coa.is_active
                AND coa.is_postable
                AND coa.account_type = ANY(af.compatible_account_types)
          )
    ) missing

    UNION ALL

    SELECT
        'invalid_existing_transaction_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.transaction_account_rules r
    JOIN public.account_functions af
      ON af.function_key = r.account_function_key
    LEFT JOIN public.transaction_categories tc
      ON tc.company_id = r.company_id
     AND tc.id = r.transaction_category_id
    LEFT JOIN public.chart_of_accounts coa
      ON coa.company_id = r.company_id
     AND coa.id = r.account_id
    WHERE tc.id IS NULL OR coa.id IS NULL
       OR r.system_key IS DISTINCT FROM tc.system_key
       OR NOT coa.is_active OR NOT coa.is_postable
       OR NOT (coa.account_type = ANY(af.compatible_account_types))

    UNION ALL

    SELECT
        'invalid_existing_company_fallback',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.company_account_function_fallbacks f
    JOIN public.account_functions af
      ON af.function_key = f.account_function_key
    LEFT JOIN public.chart_of_accounts coa
      ON coa.company_id = f.company_id
     AND coa.id = f.account_id
    WHERE coa.id IS NULL OR NOT coa.is_active OR NOT coa.is_postable
       OR NOT (coa.account_type = ANY(af.compatible_account_types))

    UNION ALL

    SELECT
        'required_category_function_resolution_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'missing_category_function_rows',count(*),
            'categories_affected',count(DISTINCT transaction_category_id),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM category_requirements requirement
    WHERE NOT EXISTS (
        SELECT 1 FROM active_rules r
        WHERE r.company_id = requirement.company_id
          AND r.transaction_category_id = requirement.transaction_category_id
          AND r.account_function_key = requirement.function_key
    )
      AND NOT EXISTS (
          SELECT 1 FROM active_fallbacks f
          WHERE f.company_id = requirement.company_id
            AND f.account_function_key = requirement.function_key
      )

    UNION ALL

    SELECT
        'coa_journal_history_inventory','INFO',
        jsonb_build_object(
            'accounts_with_journal_history',count(DISTINCT account_id),
            'journal_lines_with_account_id',count(*)
        )
    FROM public.journal_entries
    WHERE account_id IS NOT NULL

    UNION ALL

    SELECT
        'guarded_coa_fallback_rpc_state','INFO',
        jsonb_build_object(
            'save_chart_of_account_exists',
                to_regprocedure(
                    'public.save_chart_of_account(uuid,bigint,text,text,text,text,uuid,boolean,boolean,boolean,boolean)'
                ) IS NOT NULL,
            'save_company_fallback_exists',
                to_regprocedure(
                    'public.save_company_account_function_fallback(uuid,text,uuid,timestamp with time zone,timestamp with time zone,text)'
                ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'direct_finance_master_write_privilege','INFO',
        jsonb_build_object(
            'coa_insert',has_table_privilege(
                'authenticated','public.chart_of_accounts','INSERT'
            ),
            'coa_update',has_table_privilege(
                'authenticated','public.chart_of_accounts','UPDATE'
            ),
            'fallback_insert',has_table_privilege(
                'authenticated',
                'public.company_account_function_fallbacks','INSERT'
            ),
            'fallback_update',has_table_privilege(
                'authenticated',
                'public.company_account_function_fallbacks','UPDATE'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3 WHEN 'PASS' THEN 4 ELSE 5
    END,
    check_name;
