-- SELECT-only fixture inventory for Backoffice Sales Pricelist behavior.
WITH eligible_companies AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status = 'ACTIVE'
    AND EXISTS (SELECT 1 FROM public.stores store
      WHERE store.company_id = company.id AND store.status = 'ACTIVE')
    AND EXISTS (SELECT 1 FROM public.customers customer
      WHERE customer.company_id = company.id AND customer.is_active)
    AND (SELECT count(*) FROM public.pricelists pricelist
      WHERE pricelist.company_id = company.id
        AND pricelist.scope = 'GLOBAL'
        AND pricelist.is_default AND pricelist.is_active) = 1
), checks AS (
  SELECT 'canonical_super_admin_fixture'::text AS check_name,
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    jsonb_build_object('rows', count(*)) AS details
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id = user_row.id
   AND profile.role = 'super_admin'::public.user_role

  UNION ALL

  SELECT 'canonical_pricelist_company_fixture',
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('eligibleCompanies', count(*))
  FROM eligible_companies

  UNION ALL

  SELECT 'required_backoffice_platform_feature',
    CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected', 1, 'rows', count(*))
  FROM public.platform_features feature
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
