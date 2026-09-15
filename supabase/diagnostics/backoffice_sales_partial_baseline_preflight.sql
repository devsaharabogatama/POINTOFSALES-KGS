-- Partial baseline state after a stopped Development migration push. READ ONLY.
WITH results AS (
  SELECT
    'migration_ledger'::text AS check_name,
    'INFO'::text AS status,
    0::bigint AS violation_rows,
    jsonb_build_object(
      'ledgerRows', count(*),
      'latest', max(version)
    ) AS details
  FROM supabase_migrations.schema_migrations

  UNION ALL

  SELECT
    'bootstrap_identity_inventory',
    CASE
      WHEN (SELECT count(*) FROM auth.users) = 0
       AND (SELECT count(*) FROM public.profiles) = 0
        THEN 'SETUP'
      ELSE 'REVIEW'
    END,
    0,
    jsonb_build_object(
      'authUsers', (SELECT count(*) FROM auth.users),
      'profiles', (SELECT count(*) FROM public.profiles),
      'superAdminProfiles', (
        SELECT count(*) FROM public.profiles
        WHERE role::text = 'super_admin'
      ),
      'linkedSuperAdmins', (
        SELECT count(*)
        FROM public.profiles profile
        JOIN auth.users auth_user ON auth_user.id = profile.id
        WHERE profile.role::text = 'super_admin'
      )
    )

  UNION ALL

  SELECT
    'baseline_business_inventory',
    'INFO',
    0,
    jsonb_build_object(
      'companies', (SELECT count(*) FROM public.companies),
      'transactionCategories', (
        SELECT count(*) FROM public.transaction_categories
      ),
      'chartOfAccounts', (SELECT count(*) FROM public.chart_of_accounts),
      'systemEvents', (SELECT count(*) FROM public.system_events)
    )
)
SELECT check_name, status, violation_rows, details
FROM results
ORDER BY check_name;
