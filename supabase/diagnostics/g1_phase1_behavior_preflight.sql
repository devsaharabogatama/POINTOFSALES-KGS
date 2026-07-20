-- G1 phase 1 behavioral-test preflight.
-- SELECT-only and returns counts only; no email/name/business row is exposed.

WITH checks AS (
    SELECT
        'super_admin_profiles'::text AS check_name,
        count(*)::bigint AS row_count,
        'At least 1 required'::text AS expectation
    FROM public.profiles
    WHERE role = 'super_admin'::user_role

    UNION ALL

    SELECT
        'super_admin_profiles_linked_to_auth',
        count(*),
        'At least 1 required'
    FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
    WHERE p.role = 'super_admin'::user_role

    UNION ALL

    SELECT
        'normal_profiles',
        count(*),
        'Informational; no longer required by test'
    FROM public.profiles
    WHERE role <> 'super_admin'::user_role

    UNION ALL

    SELECT
        'companies',
        count(*),
        'Informational; test creates rollback-only fixture if 0'
    FROM public.companies
)
SELECT
    check_name,
    CASE
        WHEN check_name IN (
            'super_admin_profiles',
            'super_admin_profiles_linked_to_auth'
        ) AND row_count = 0 THEN 'FAIL'
        ELSE 'PASS'
    END AS status,
    row_count,
    expectation
FROM checks
ORDER BY check_name;
