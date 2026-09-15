-- SELECT-only preflight for formal SALES/SALES_ADMIN module authority.
WITH assignment_runtime AS (
  SELECT pg_get_functiondef(
    'public.save_user_company_access(uuid,uuid,text,uuid)'::regprocedure
  ) AS definition
), checks AS (
  SELECT 'sales_role_dependency_ledger'::text AS check_name,
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    abs(count(*) - 1)::bigint AS violation_rows,
    jsonb_build_object('requiredVersion', '20260909120000', 'rows', count(*)) AS details
  FROM private.kgs_schema_migrations
  WHERE version = '20260909120000'

  UNION ALL

  SELECT 'sales_role_migration_collision',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('version', '20260909130000', 'ledgerRows', count(*))
  FROM private.kgs_schema_migrations
  WHERE version = '20260909130000'

  UNION ALL

  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('runRows', count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN ('PREVIEWED', 'APPROVED', 'PROCESSING')

  UNION ALL

  SELECT 'sales_role_constraint_pre_migration_shape',
    CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*) - 2)::bigint,
    jsonb_build_object('expected', 2, 'rows', count(*))
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid = constraint_row.conrelid
  JOIN pg_namespace schema_row ON schema_row.oid = relation.relnamespace
  WHERE schema_row.nspname = 'public'
    AND (
      (relation.relname = 'company_memberships'
        AND constraint_row.conname = 'company_memberships_role_code_check')
      OR (relation.relname = 'store_memberships'
        AND constraint_row.conname = 'store_memberships_role_code_check')
    )
    AND pg_get_constraintdef(constraint_row.oid) NOT LIKE '%SALES_ADMIN%'
    AND pg_get_constraintdef(constraint_row.oid) NOT LIKE '%''SALES''%'

  UNION ALL

  SELECT 'sales_permission_catalog_inventory',
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*) > 0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('salesPermissionRows', count(*))
  FROM public.access_permission_catalog catalog
  WHERE catalog.module_key = 'SALES'

  UNION ALL

  SELECT 'sales_role_membership_collision',
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,
    jsonb_build_object('existingMembershipRows', count(*))
  FROM (
    SELECT company_membership.user_id
    FROM public.company_memberships company_membership
    WHERE company_membership.role_code IN ('SALES', 'SALES_ADMIN')
    UNION ALL
    SELECT store_membership.user_id
    FROM public.store_memberships store_membership
    WHERE store_membership.role_code IN ('SALES', 'SALES_ADMIN')
  ) collision

  UNION ALL

  SELECT 'assignment_role_validator_exact_marker',
    CASE WHEN marker_count = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(marker_count - 1)::bigint,
    jsonb_build_object('expected', 1, 'markerRows', marker_count)
  FROM (
    SELECT (length(definition) - length(replace(definition,
      '''STORE_MANAGER'',''WAREHOUSE_ADMIN'',''CASHIER''', '')))
      / length('''STORE_MANAGER'',''WAREHOUSE_ADMIN'',''CASHIER''') AS marker_count
    FROM assignment_runtime
  ) marker
)
SELECT check_name, status, violation_rows, details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
