-- SELECT-only fixture inventory for canonical Backoffice Sales tax behavior.
WITH eligible_companies AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status = 'ACTIVE'
    AND EXISTS (SELECT 1 FROM public.stores store
      WHERE store.company_id = company.id AND store.status = 'ACTIVE')
    AND EXISTS (SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id = company.id
        AND warehouse.is_active AND warehouse.is_sale_source)
    AND EXISTS (SELECT 1 FROM public.customers customer
      WHERE customer.company_id = company.id AND customer.is_active)
    AND EXISTS (
      SELECT 1
      FROM public.product_uoms product_uom
      JOIN public.products product
        ON product.company_id = product_uom.company_id
       AND product.id = product_uom.product_id
      WHERE product_uom.company_id = company.id
        AND product_uom.is_active AND product_uom.sales_allowed
        AND product.is_active
    )
    AND EXISTS (SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id = company.id AND account.is_active
        AND account.is_postable AND account.system_function_key = 'OUTPUT_TAX')
), checks AS (
  SELECT 'canonical_super_admin_fixture'::text AS check_name,
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'BLOCKER' END::text AS status,
    jsonb_build_object('rows', count(*)) AS details
  FROM public.profiles profile
  WHERE profile.role = 'super_admin'::public.user_role

  UNION ALL

  SELECT 'canonical_tax_company_fixture',
    CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('eligibleCompanies', count(*))
  FROM eligible_companies

  UNION ALL

  SELECT 'required_platform_features',
    CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected', 2, 'rows', count(*))
  FROM public.platform_features feature
  WHERE feature.feature_code IN (
    'tax_sales_enabled', 'backoffice_delivered_qty_sales_enabled'
  )

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
