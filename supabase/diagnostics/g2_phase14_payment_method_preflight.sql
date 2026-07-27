-- G2 phase 14 preflight: canonical Payment Method master readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and enum labels only; no payment/business rows.
-- - Does not change checkout, settlement, reconciliation, or Finance posting.

WITH required_versions(version) AS (
    VALUES ('20260722080000')
), expected_tables(table_name) AS (
    VALUES
        ('payment_methods'),
        ('payment_method_store_assignments'),
        ('payment_method_master_audit')
), expected_sales_payment_columns(column_name) AS (
    VALUES
        ('payment_method_id'),
        ('payment_method_code_snapshot'),
        ('payment_method_name_snapshot'),
        ('payment_method_type_snapshot'),
        ('settlement_route_snapshot'),
        ('fee_bearer_snapshot'),
        ('fee_type_snapshot'),
        ('fee_percent_snapshot'),
        ('fee_fixed_amount_snapshot'),
        ('configured_fee_amount'),
        ('customer_surcharge_amount')
), payment_enum AS (
    SELECT e.enumlabel, e.enumsortorder
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE n.nspname = 'public'
      AND t.typname = 'payment_method'
), payment_inventory AS (
    SELECT
        count(*) AS payment_rows,
        count(DISTINCT company_id) AS companies,
        count(*) FILTER (WHERE is_reversal) AS reversal_rows,
        count(*) FILTER (
            WHERE payment_method::text = 'Customer_Balance'
        ) AS customer_balance_rows,
        count(*) FILTER (WHERE amount <= 0) AS nonpositive_amount_rows
    FROM public.sales_payments
), checks AS (
    SELECT
        'g2_phase13_dependency'::text AS check_name,
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
        'canonical_payment_method_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_tables', COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE to_regclass('public.' || e.table_name) IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_tables e

    UNION ALL

    SELECT
        'legacy_payment_method_enum',
        'INFO',
        jsonb_build_object(
            'labels', COALESCE(
                jsonb_agg(enumlabel ORDER BY enumsortorder),
                '[]'::jsonb
            )
        )
    FROM payment_enum

    UNION ALL

    SELECT
        'legacy_sales_payment_inventory',
        'INFO',
        jsonb_build_object(
            'payment_rows', payment_rows,
            'companies', companies,
            'reversal_rows', reversal_rows
        )
    FROM payment_inventory

    UNION ALL

    SELECT
        'nonpositive_sales_payment_amount',
        CASE WHEN nonpositive_amount_rows = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', nonpositive_amount_rows)
    FROM payment_inventory

    UNION ALL

    SELECT
        'customer_balance_internal_tender_history',
        CASE WHEN customer_balance_rows = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', customer_balance_rows)
    FROM payment_inventory

    UNION ALL

    SELECT
        'historical_payment_method_backfill_scope',
        CASE WHEN payment_rows = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('payment_rows', payment_rows)
    FROM payment_inventory

    UNION ALL

    SELECT
        'sales_payment_snapshot_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_columns', COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_sales_payment_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_payments'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'active_company_default_payment_method_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'active_companies', count(*),
            'companies_to_provision', count(*)
        )
    FROM public.companies
    WHERE status = 'ACTIVE'

    UNION ALL

    SELECT
        'payment_method_assignment_inventory',
        'INFO',
        jsonb_build_object(
            'companies', (SELECT count(*) FROM public.companies),
            'active_companies', (
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'stores', (SELECT count(*) FROM public.stores),
            'active_stores', (
                SELECT count(*) FROM public.stores WHERE status = 'ACTIVE'
            )
        )

    UNION ALL

    SELECT
        'direct_sales_payment_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert', has_table_privilege(
                'authenticated','public.sales_payments','INSERT'
            ),
            'authenticated_update', has_table_privilege(
                'authenticated','public.sales_payments','UPDATE'
            ),
            'authenticated_delete', has_table_privilege(
                'authenticated','public.sales_payments','DELETE'
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
