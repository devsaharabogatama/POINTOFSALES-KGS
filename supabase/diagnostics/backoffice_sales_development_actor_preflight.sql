-- Development actor bootstrap preflight. READ ONLY.
WITH target_auth AS (
  SELECT id
  FROM auth.users
  WHERE lower(email) = 'localadmin@local.com'
),
target_profile AS (
  SELECT profile.id, profile.role::text AS role
  FROM public.profiles profile
  JOIN target_auth auth_user ON auth_user.id = profile.id
),
results AS (
  SELECT
    'development_auth_identity'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    abs(count(*) - 1)::bigint AS violation_rows,
    jsonb_build_object('expected', 1, 'authRows', count(*)) AS details
  FROM target_auth

  UNION ALL

  SELECT
    'development_profile_identity',
    CASE
      WHEN count(*) = 1
       AND min(role) IN ('cashier', 'super_admin') THEN 'PASS'
      ELSE 'BLOCKER'
    END,
    CASE
      WHEN count(*) = 1
       AND min(role) IN ('cashier', 'super_admin') THEN 0
      ELSE 1
    END,
    jsonb_build_object(
      'expected', 1,
      'profileRows', count(*),
      'roles', coalesce(jsonb_agg(role), '[]'::jsonb)
    )
  FROM target_profile

  UNION ALL

  SELECT
    'development_company_scope',
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*) - 1)::bigint,
    jsonb_build_object('expected', 1, 'activeCompanies', count(*))
  FROM public.companies
  WHERE status = 'ACTIVE'
)
SELECT check_name, status, violation_rows, details
FROM results
ORDER BY check_name;
