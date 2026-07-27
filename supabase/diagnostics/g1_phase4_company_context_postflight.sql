-- G1 phase 4 postflight. SELECT-only. Expected result: 13 PASS rows.

WITH expected_constraints(table_name, constraint_name) AS (
    VALUES
        ('company_memberships','company_memberships_role_code_check'),
        ('company_memberships','company_memberships_status_check'),
        ('company_memberships','company_memberships_default_active_check'),
        ('store_memberships','store_memberships_role_code_check'),
        ('store_memberships','store_memberships_status_check')
), constraint_checks AS (
    SELECT
        'constraint:' || e.constraint_name AS check_name,
        CASE WHEN c.oid IS NOT NULL AND c.contype = 'c' AND c.convalidated
             THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'table', e.table_name,
            'exists', c.oid IS NOT NULL,
            'validated', COALESCE(c.convalidated, FALSE)
        ) AS details
    FROM expected_constraints e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel ON rel.relnamespace = n.oid AND rel.relname = e.table_name
    LEFT JOIN pg_constraint c ON c.conrelid = rel.oid AND c.conname = e.constraint_name
), table_checks AS (
    SELECT
        'table:' || e.table_name AS check_name,
        CASE WHEN c.oid IS NOT NULL AND c.relrowsecurity THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'exists', c.oid IS NOT NULL,
            'rls_enabled', COALESCE(c.relrowsecurity, FALSE)
        ) AS details
    FROM (VALUES
        ('user_active_company_contexts'),
        ('user_active_company_context_audit')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = e.table_name
), function_checks AS (
    SELECT
        'function:' || e.function_name AS check_name,
        CASE
            WHEN p.oid IS NULL OR NOT p.prosecdef THEN 'FAIL'
            WHEN NOT COALESCE(p.proconfig, ARRAY[]::text[])::text[]
                     @> ARRAY['search_path=public, pg_temp']::text[] THEN 'FAIL'
            ELSE 'PASS'
        END AS status,
        jsonb_build_object(
            'exists', p.oid IS NOT NULL,
            'security_definer', COALESCE(p.prosecdef, FALSE),
            'config', COALESCE(to_jsonb(p.proconfig), '[]'::jsonb)
        ) AS details
    FROM (VALUES
        ('private_active_company_id'),
        ('private_request_company_matches'),
        ('set_active_company_context')
    ) e(function_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_proc p ON p.pronamespace = n.oid AND p.proname = e.function_name
), other_checks AS (
    SELECT
        'unique_default_company_per_user'::text AS check_name,
        CASE WHEN to_regclass('public.uq_company_memberships_one_default_per_user') IS NOT NULL
             THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'exists', to_regclass('public.uq_company_memberships_one_default_per_user') IS NOT NULL
        ) AS details

    UNION ALL

    SELECT
        'context_table_privileges',
        CASE
            WHEN has_table_privilege('authenticated','public.user_active_company_contexts','SELECT')
             AND NOT has_table_privilege('authenticated','public.user_active_company_contexts','INSERT')
             AND NOT has_table_privilege('authenticated','public.user_active_company_contexts','UPDATE')
             AND NOT has_table_privilege('authenticated','public.user_active_company_contexts','DELETE')
            THEN 'PASS' ELSE 'FAIL'
        END,
        jsonb_build_object(
            'select', has_table_privilege('authenticated','public.user_active_company_contexts','SELECT'),
            'insert', has_table_privilege('authenticated','public.user_active_company_contexts','INSERT'),
            'update', has_table_privilege('authenticated','public.user_active_company_contexts','UPDATE'),
            'delete', has_table_privilege('authenticated','public.user_active_company_contexts','DELETE')
        )

    UNION ALL

    SELECT
        'migration_ledger',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('row_count', count(*))
    FROM private.kgs_schema_migrations
    WHERE version = '20260720180000'
)
SELECT check_name, status, details
FROM (
    SELECT * FROM constraint_checks
    UNION ALL SELECT * FROM table_checks
    UNION ALL SELECT * FROM function_checks
    UNION ALL SELECT * FROM other_checks
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END, check_name;
