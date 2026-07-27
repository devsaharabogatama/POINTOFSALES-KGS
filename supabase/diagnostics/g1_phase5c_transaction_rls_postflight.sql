-- G1 phase 5C postflight. SELECT-only. Expected result: 18 PASS rows.

WITH expected_tables(table_name) AS (
    VALUES
        ('cashier_sessions'), ('sales_headers'), ('sales_details'),
        ('sales_payments'), ('purchases_headers'), ('purchases_details')
), policy_counts AS (
    SELECT tablename,count(*)::integer AS policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
    GROUP BY tablename
), table_checks AS (
    SELECT
        'table_policy:' || e.table_name AS check_name,
        CASE
            WHEN c.oid IS NOT NULL
             AND c.relrowsecurity
             AND COALESCE(pc.policy_count,0) = 1
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists',c.oid IS NOT NULL,
            'rls_enabled',COALESCE(c.relrowsecurity,FALSE),
            'expected_policies',1,
            'actual_policies',COALESCE(pc.policy_count,0)
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
             AND NOT has_table_privilege('authenticated','public.' || table_name,'INSERT')
             AND NOT has_table_privilege('authenticated','public.' || table_name,'UPDATE')
             AND NOT has_table_privilege('authenticated','public.' || table_name,'DELETE')
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'select',has_table_privilege('authenticated','public.' || table_name,'SELECT'),
            'insert',has_table_privilege('authenticated','public.' || table_name,'INSERT'),
            'update',has_table_privilege('authenticated','public.' || table_name,'UPDATE'),
            'delete',has_table_privilege('authenticated','public.' || table_name,'DELETE')
        ) AS details
    FROM expected_tables
), expected_helpers(function_name) AS (
    VALUES
        ('private_sales_document_visible'),
        ('private_purchase_document_visible')
), helper_checks AS (
    SELECT
        'function:' || e.function_name AS check_name,
        CASE
            WHEN p.oid IS NOT NULL
             AND p.prosecdef
             AND p.provolatile = 's'
             AND COALESCE(p.proconfig,ARRAY[]::text[])::text[]
                 @> ARRAY['search_path=public, pg_temp']::text[]
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists',p.oid IS NOT NULL,
            'security_definer',COALESCE(p.prosecdef,FALSE),
            'volatility',p.provolatile,
            'config',COALESCE(to_jsonb(p.proconfig),'[]'::jsonb)
        ) AS details
    FROM expected_helpers e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_proc p ON p.pronamespace = n.oid AND p.proname = e.function_name
), checkout_checks AS (
    SELECT
        'function:guarded_checkout'::text AS check_name,
        CASE
            WHEN p.oid IS NOT NULL
             AND p.prosecdef
             AND COALESCE(p.proconfig,ARRAY[]::text[])::text[]
                 @> ARRAY['search_path=public, pg_temp']::text[]
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists',p.oid IS NOT NULL,
            'security_definer',COALESCE(p.prosecdef,FALSE),
            'config',COALESCE(to_jsonb(p.proconfig),'[]'::jsonb)
        ) AS details
    FROM (VALUES (to_regprocedure(
        'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)'
    ))) expected(oid)
    LEFT JOIN pg_proc p ON p.oid = expected.oid

    UNION ALL

    SELECT
        'function:guarded_checkout_authenticated_execute',
        CASE WHEN has_function_privilege(
            'authenticated',
            'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)',
            'EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('execute',has_function_privilege(
            'authenticated',
            'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)',
            'EXECUTE'
        ))

    UNION ALL

    SELECT
        'function:legacy_checkout_not_api_executable',
        CASE WHEN NOT has_function_privilege(
            'authenticated',
            'public.private_create_sales_transaction_g1_legacy(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)',
            'EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('authenticated_execute',has_function_privilege(
            'authenticated',
            'public.private_create_sales_transaction_g1_legacy(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)',
            'EXECUTE'
        ))
), ledger_check AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260721090000'
)
SELECT check_name,status,details
FROM (
    SELECT * FROM table_checks
    UNION ALL SELECT * FROM privilege_checks
    UNION ALL SELECT * FROM helper_checks
    UNION ALL SELECT * FROM checkout_checks
    UNION ALL SELECT * FROM ledger_check
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
