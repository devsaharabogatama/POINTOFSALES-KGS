-- G1 phase 4 preflight: membership vocabulary and default Company integrity.
-- SELECT-only. Every row must PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'company_memberships_role_code'::text AS check_name,
        count(*)::bigint AS violation_rows
    FROM public.company_memberships
    WHERE role_code NOT IN (
        'COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING',
        'STORE_MANAGER', 'WAREHOUSE_ADMIN', 'CASHIER'
    )

    UNION ALL

    SELECT 'company_memberships_status', count(*)
    FROM public.company_memberships
    WHERE status NOT IN ('ACTIVE', 'INACTIVE')

    UNION ALL

    SELECT 'store_memberships_role_code', count(*)
    FROM public.store_memberships
    WHERE role_code NOT IN (
        'COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING',
        'STORE_MANAGER', 'WAREHOUSE_ADMIN', 'CASHIER'
    )

    UNION ALL

    SELECT 'store_memberships_status', count(*)
    FROM public.store_memberships
    WHERE status NOT IN ('ACTIVE', 'INACTIVE')

    UNION ALL

    SELECT 'inactive_default_company_membership', count(*)
    FROM public.company_memberships
    WHERE is_default_company AND status <> 'ACTIVE'

    UNION ALL

    SELECT 'multiple_default_company_per_user', count(*)
    FROM (
        SELECT user_id
        FROM public.company_memberships
        WHERE is_default_company
        GROUP BY user_id
        HAVING count(*) > 1
    ) duplicates
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END, check_name;
