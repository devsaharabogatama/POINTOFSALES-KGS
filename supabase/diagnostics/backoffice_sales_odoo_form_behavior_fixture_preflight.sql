-- SELECT-only fixture inventory for the Odoo-form rollback behavior.
WITH checks AS (
  SELECT 'exact_localadmin_fixture'::text AS check_name,
    'INFO'::text AS status,
    jsonb_build_object('rows', count(*)) AS details
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id = user_row.id
   AND profile.role = 'super_admin'::public.user_role
  WHERE lower(user_row.email) = lower('localadmin@local.com')

  UNION ALL

  SELECT 'canonical_super_admin_fixture',
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows', count(*))
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id = user_row.id
   AND profile.role = 'super_admin'::public.user_role

  UNION ALL

  SELECT 'company_store_sale_warehouse_fixture',
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows', count(*))
  FROM public.companies company
  WHERE company.status = 'ACTIVE'
    AND EXISTS (
      SELECT 1 FROM public.stores store
      WHERE store.company_id = company.id AND store.status = 'ACTIVE'
    )
    AND EXISTS (
      SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id = company.id
        AND warehouse.is_active AND warehouse.is_sale_source
    )

  UNION ALL

  SELECT 'existing_backoffice_company_feature_inventory',
    'INFO',
    jsonb_build_object('rows', count(*))
  FROM public.company_features feature
  WHERE feature.feature_code = 'backoffice_delivered_qty_sales_enabled'

  UNION ALL

  SELECT 'active_company_context_source_contract',
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object(
      'rows', count(*),
      'definition', max(pg_get_constraintdef(constraint_row.oid)))
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid = constraint_row.conrelid
  JOIN pg_namespace schema_row ON schema_row.oid = relation.relnamespace
  WHERE schema_row.nspname = 'public'
    AND relation.relname = 'user_active_company_contexts'
    AND constraint_row.conname = 'user_active_company_contexts_source_check'
)
SELECT check_name, status, details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
