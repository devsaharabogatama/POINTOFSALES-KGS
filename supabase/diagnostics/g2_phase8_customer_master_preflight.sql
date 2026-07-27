-- G2 phase 8 preflight: canonical Customer and Customer Category readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Customer names/contact data.

WITH required_versions(version) AS (
    VALUES ('20260721230000')
), normalized_customers AS (
    SELECT
        c.*,
        upper(regexp_replace(btrim(c.code), '\s+', ' ', 'g'))
            AS normalized_code,
        lower(regexp_replace(btrim(c.name), '\s+', ' ', 'g'))
            AS normalized_name
    FROM public.customers c
), active_company_walk_in AS (
    SELECT
        co.id AS company_id,
        count(c.id) FILTER (
            WHERE upper(btrim(c.code)) = 'WALK-IN'
        ) AS walk_in_rows
    FROM public.companies co
    LEFT JOIN public.customers c ON c.company_id = co.id
    WHERE co.status = 'ACTIVE'
    GROUP BY co.id
), expected_customer_columns(column_name) AS (
    VALUES
        ('customer_category_id'), ('email'), ('customer_type'),
        ('default_pricelist_id'), ('credit_term_days'), ('is_active'),
        ('notes'), ('master_version'), ('created_by'), ('updated_by'),
        ('updated_at'), ('is_system_customer')
), checks AS (
    SELECT
        'g2_phase6_dependency'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected', count(*),
            'missing', COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'canonical_customer_schema_state',
        'INFO',
        jsonb_build_object(
            'customer_categories_exists',
                to_regclass('public.customer_categories') IS NOT NULL,
            'missing_customer_columns', COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_customer_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'customers'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'customer_inventory',
        'INFO',
        jsonb_build_object(
            'customers', count(*),
            'companies', count(DISTINCT company_id),
            'customers_with_sales', count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM public.sales_headers sh
                    WHERE sh.company_id = normalized_customers.company_id
                      AND sh.customer_id = normalized_customers.id
                )
            ),
            'customers_with_balance', count(*) FILTER (
                WHERE current_balance <> 0
            ),
            'customers_with_credit_limit', count(*) FILTER (
                WHERE credit_limit <> 0
            )
        )
    FROM normalized_customers

    UNION ALL

    SELECT
        'blank_customer_code_or_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM normalized_customers
    WHERE normalized_code = '' OR normalized_name = ''

    UNION ALL

    SELECT
        'duplicate_normalized_customer_code',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_code
        FROM normalized_customers
        GROUP BY company_id, normalized_code
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'duplicate_normalized_customer_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_name
        FROM normalized_customers
        GROUP BY company_id, normalized_name
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'negative_customer_financial_value',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM public.customers
    WHERE current_balance < 0 OR credit_limit < 0

    UNION ALL

    SELECT
        'nonzero_customer_balance_without_canonical_ledger',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM public.customers
    WHERE current_balance <> 0

    UNION ALL

    SELECT
        'active_company_without_walk_in_customer',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('company_count', count(*))
    FROM active_company_walk_in
    WHERE walk_in_rows = 0

    UNION ALL

    SELECT
        'active_company_with_multiple_walk_in_customers',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count', count(*))
    FROM active_company_walk_in
    WHERE walk_in_rows > 1

    UNION ALL

    SELECT
        'walk_in_customer_with_financial_configuration',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM public.customers
    WHERE upper(btrim(code)) = 'WALK-IN'
      AND (current_balance <> 0 OR credit_limit <> 0)

    UNION ALL

    SELECT
        'customer_company_reference_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_rows', count(*))
    FROM public.customers c
    LEFT JOIN public.companies co ON co.id = c.company_id
    WHERE co.id IS NULL

    UNION ALL

    SELECT
        'direct_customer_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert', has_table_privilege(
                'authenticated','public.customers','INSERT'
            ),
            'authenticated_update', has_table_privilege(
                'authenticated','public.customers','UPDATE'
            ),
            'authenticated_delete', has_table_privilege(
                'authenticated','public.customers','DELETE'
            )
        )
)
SELECT check_name, status, details
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
