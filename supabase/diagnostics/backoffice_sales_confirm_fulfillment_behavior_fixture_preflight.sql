-- SELECT-only fixture inventory for atomic Confirm fulfillment rollback behavior.
WITH eligible_companies AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS (
      SELECT 1
      FROM public.stores store
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND warehouse.is_active AND warehouse.is_sale_source
        AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE'
    )
    AND EXISTS (
      SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active
    )
    AND EXISTS (
      SELECT 1
      FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id
        AND product.is_active AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id
        AND product_uom.is_active AND product_uom.sales_allowed
        AND product_uom.factor_to_base>0
    )
), checks AS (
  SELECT 'canonical_super_admin_fixture'::text check_name,
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('rows',count(*)) details
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  UNION ALL
  SELECT 'canonical_confirm_fulfillment_company_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*))
  FROM eligible_companies
  UNION ALL
  SELECT 'required_backoffice_platform_feature',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*)-1)::bigint,
    jsonb_build_object('expected',1,'rows',count(*))
  FROM public.platform_features
  WHERE feature_code='backoffice_delivered_qty_sales_enabled'
  UNION ALL
  SELECT 'active_company_context_default_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(count(*)-1)::bigint,
    jsonb_build_object('rows',count(*),'columnDefault',max(column_default))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='user_active_company_contexts'
    AND column_name='selection_source' AND is_nullable='NO'
    AND column_default IS NOT NULL
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
