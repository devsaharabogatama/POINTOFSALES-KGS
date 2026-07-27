-- G1 phase 5A preflight: active context integrity before canonical core RLS.
-- SELECT-only. Every row must PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'inactive_active_company_context'::text AS check_name,
        count(*)::bigint AS violation_rows
    FROM public.user_active_company_contexts c
    JOIN public.companies co ON co.id = c.company_id
    WHERE co.status <> 'ACTIVE'

    UNION ALL

    SELECT 'normal_user_context_without_active_membership', count(*)
    FROM public.user_active_company_contexts c
    JOIN public.profiles p ON p.id = c.user_id
    LEFT JOIN public.company_memberships cm
      ON cm.company_id = c.company_id
     AND cm.user_id = c.user_id
     AND cm.status = 'ACTIVE'
    WHERE p.role <> 'super_admin'::user_role
      AND cm.id IS NULL

    UNION ALL

    SELECT 'core_tables_without_rls', count(*)
    FROM (VALUES
        ('profiles'), ('companies'), ('company_memberships'), ('stores'),
        ('store_memberships'), ('pos_terminals'), ('warehouses')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')
    WHERE c.oid IS NULL OR NOT c.relrowsecurity
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END, check_name;
