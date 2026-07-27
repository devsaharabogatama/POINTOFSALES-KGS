-- G1 phase 5B postflight. SELECT-only. Expected result: 19 PASS rows.

WITH expected_tables(table_name, policy_count, can_insert, can_update) AS (
    VALUES
        ('products',3,TRUE,TRUE),
        ('product_bundle_items',3,TRUE,TRUE),
        ('product_stocks',1,FALSE,FALSE),
        ('customers',3,FALSE,FALSE),
        ('uoms',3,TRUE,TRUE),
        ('product_uom_conversions',3,TRUE,TRUE),
        ('product_batches',1,FALSE,FALSE)
), policy_counts AS (
    SELECT tablename, count(*)::integer AS policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
    GROUP BY tablename
), table_checks AS (
    SELECT
        'table_policy:' || e.table_name AS check_name,
        CASE
            WHEN c.oid IS NOT NULL
             AND c.relrowsecurity
             AND COALESCE(pc.policy_count,0) = e.policy_count
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists', c.oid IS NOT NULL,
            'rls_enabled', COALESCE(c.relrowsecurity,FALSE),
            'expected_policies', e.policy_count,
            'actual_policies', COALESCE(pc.policy_count,0)
        ) AS details
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = e.table_name
    LEFT JOIN policy_counts pc ON pc.tablename = e.table_name
), privilege_checks AS (
    SELECT
        'privilege:' || table_name AS check_name,
        CASE
            WHEN has_table_privilege('authenticated','public.' || table_name,'SELECT')
             AND has_table_privilege('authenticated','public.' || table_name,'INSERT') = can_insert
             AND has_table_privilege('authenticated','public.' || table_name,'UPDATE') = can_update
             AND NOT has_table_privilege('authenticated','public.' || table_name,'DELETE')
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'select', has_table_privilege('authenticated','public.' || table_name,'SELECT'),
            'insert', has_table_privilege('authenticated','public.' || table_name,'INSERT'),
            'update', has_table_privilege('authenticated','public.' || table_name,'UPDATE'),
            'delete', has_table_privilege('authenticated','public.' || table_name,'DELETE')
        ) AS details
    FROM expected_tables
), function_checks AS (
    SELECT
        'function:guarded_product_import'::text AS check_name,
        CASE
            WHEN p.oid IS NOT NULL
             AND p.prosecdef
             AND COALESCE(p.proconfig,ARRAY[]::text[])::text[]
                 @> ARRAY['search_path=public, pg_temp']::text[]
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists', p.oid IS NOT NULL,
            'security_definer', COALESCE(p.prosecdef,FALSE),
            'config', COALESCE(to_jsonb(p.proconfig),'[]'::jsonb)
        ) AS details
    FROM (VALUES (
        to_regprocedure('public.import_products_for_company(uuid,jsonb)')
    )) expected(oid)
    LEFT JOIN pg_proc p ON p.oid = expected.oid

    UNION ALL

    SELECT
        'function:guarded_product_import_authenticated_execute',
        CASE WHEN has_function_privilege(
            'authenticated',
            'public.import_products_for_company(uuid,jsonb)',
            'EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('execute',has_function_privilege(
            'authenticated',
            'public.import_products_for_company(uuid,jsonb)',
            'EXECUTE'
        ))

    UNION ALL

    SELECT
        'function:legacy_import_not_api_executable',
        CASE WHEN NOT has_function_privilege(
            'authenticated',
            'public.private_import_products_for_company_g1_legacy(uuid,jsonb)',
            'EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('authenticated_execute',has_function_privilege(
            'authenticated',
            'public.private_import_products_for_company_g1_legacy(uuid,jsonb)',
            'EXECUTE'
        ))
), customer_column_check AS (
    SELECT
        'customer_safe_column_privileges'::text AS check_name,
        CASE
            WHEN has_column_privilege(
                'authenticated','public.customers','credit_limit','UPDATE'
            )
             AND NOT has_column_privilege(
                'authenticated','public.customers','current_balance','UPDATE'
            )
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'credit_limit_update',has_column_privilege(
                'authenticated','public.customers','credit_limit','UPDATE'
            ),
            'current_balance_update',has_column_privilege(
                'authenticated','public.customers','current_balance','UPDATE'
            )
        ) AS details
), ledger_check AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260720230000'
)
SELECT check_name,status,details
FROM (
    SELECT * FROM table_checks
    UNION ALL SELECT * FROM privilege_checks
    UNION ALL SELECT * FROM function_checks
    UNION ALL SELECT * FROM customer_column_check
    UNION ALL SELECT * FROM ledger_check
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
