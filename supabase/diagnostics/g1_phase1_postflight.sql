-- G1 phase 1 postflight. SELECT-only; safe for Supabase SQL Editor.

WITH expected_not_null(table_name) AS (
    VALUES
        ('product_batches'),
        ('product_uom_conversions'),
        ('sales_fifo_allocations'),
        ('stock_adjustments'),
        ('stock_movements'),
        ('stock_opname_details'),
        ('stock_opnames'),
        ('uoms')
), checks AS (
    SELECT
        'tenant_not_null:' || e.table_name AS check_name,
        CASE WHEN c.is_nullable = 'NO' THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('is_nullable', c.is_nullable) AS details
    FROM expected_not_null e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = 'company_id'

    UNION ALL

    SELECT
        'table:' || e.table_name,
        CASE
            WHEN c.oid IS NULL THEN 'FAIL'
            WHEN NOT c.relrowsecurity THEN 'FAIL'
            ELSE 'PASS'
        END,
        jsonb_build_object(
            'exists', c.oid IS NOT NULL,
            'rls_enabled', COALESCE(c.relrowsecurity, FALSE)
        )
    FROM (VALUES
        ('platform_features'),
        ('company_features'),
        ('company_feature_audit')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r', 'p')

    UNION ALL

    SELECT
        'feature_catalog_seed',
        CASE WHEN count(*) = 6 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('expected', 6, 'actual', count(*))
    FROM public.platform_features
    WHERE feature_code IN (
        'customer_balance_enabled',
        'ketul_enabled',
        'offline_pos_enabled',
        'tempo_enabled',
        'tax_purchase_enabled',
        'tax_sales_enabled'
    )

    UNION ALL

    SELECT
        'optional_features_default_disabled',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('enabled_rows', count(*))
    FROM public.company_features
    WHERE is_enabled

    UNION ALL

    SELECT
        'migration_ledger',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('row_count', count(*))
    FROM private.kgs_schema_migrations
    WHERE version = '20260720090000'

    UNION ALL

    SELECT
        'anon_has_no_public_table_privileges',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('privilege_rows', count(*))
    FROM information_schema.table_privileges
    WHERE table_schema = 'public'
      AND grantee = 'anon'

    UNION ALL

    SELECT
        'authenticated_has_no_unsafe_table_privileges',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('privilege_rows', count(*))
    FROM information_schema.table_privileges
    WHERE table_schema = 'public'
      AND grantee = 'authenticated'
      AND privilege_type IN ('TRUNCATE', 'REFERENCES', 'TRIGGER')

    UNION ALL

    SELECT
        'unsafe_rpc_not_authenticated',
        CASE
            WHEN NOT has_function_privilege(
                'authenticated',
                'public.process_financial_events_queue()',
                'EXECUTE'
            )
             AND NOT has_function_privilege(
                'authenticated',
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
                'EXECUTE'
            )
            THEN 'PASS'
            ELSE 'FAIL'
        END,
        jsonb_build_object(
            'worker_authenticated_execute', has_function_privilege(
                'authenticated',
                'public.process_financial_events_queue()',
                'EXECUTE'
            ),
            'transfer_authenticated_execute', has_function_privilege(
                'authenticated',
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
                'EXECUTE'
            )
        )
)
SELECT check_name, status, details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END, check_name;
