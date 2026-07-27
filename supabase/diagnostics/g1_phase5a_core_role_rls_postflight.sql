-- G1 phase 5A postflight. SELECT-only. Expected result: 23 PASS rows.

WITH expected_tables(table_name, policy_count) AS (
    VALUES
        ('profiles',1), ('companies',1), ('company_memberships',1),
        ('store_memberships',1), ('stores',3), ('pos_terminals',3),
        ('warehouses',3)
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
), expected_functions(function_name) AS (
    VALUES
        ('private_user_company_role'),
        ('private_user_has_company_access'),
        ('get_user_role_in_company'),
        ('private_user_has_any_company_role'),
        ('private_user_has_any_store_role'),
        ('private_user_has_store_access'),
        ('private_user_has_any_company_or_store_role'),
        ('private_profile_visible')
), function_checks AS (
    SELECT
        'function:' || e.function_name AS check_name,
        CASE
            WHEN p.oid IS NULL OR NOT p.prosecdef OR p.provolatile <> 's' THEN 'FAIL'
            WHEN NOT COALESCE(p.proconfig,ARRAY[]::text[])::text[]
                     @> ARRAY['search_path=public, pg_temp']::text[] THEN 'FAIL'
            ELSE 'PASS'
        END AS status,
        jsonb_build_object(
            'exists', p.oid IS NOT NULL,
            'security_definer', COALESCE(p.prosecdef,FALSE),
            'volatility', p.provolatile,
            'config', COALESCE(to_jsonb(p.proconfig),'[]'::jsonb)
        ) AS details
    FROM expected_functions e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_proc p ON p.pronamespace = n.oid AND p.proname = e.function_name
), expected_privileges(table_name, can_insert, can_update) AS (
    VALUES
        ('profiles',FALSE,FALSE),
        ('companies',FALSE,FALSE),
        ('company_memberships',FALSE,FALSE),
        ('store_memberships',FALSE,FALSE),
        ('stores',TRUE,TRUE),
        ('pos_terminals',TRUE,TRUE),
        ('warehouses',TRUE,TRUE)
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
    FROM expected_privileges
), ledger_check AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260720210000'
)
SELECT check_name,status,details
FROM (
    SELECT * FROM table_checks
    UNION ALL SELECT * FROM function_checks
    UNION ALL SELECT * FROM privilege_checks
    UNION ALL SELECT * FROM ledger_check
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
