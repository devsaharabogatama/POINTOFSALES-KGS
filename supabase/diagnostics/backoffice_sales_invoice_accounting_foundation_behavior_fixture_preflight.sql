-- SELECT-only fixture inventory for Invoice Accounting foundation behavior.
WITH eligible AS (
  SELECT DISTINCT company.id
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base>0
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
  WHERE company.status='ACTIVE'
), checks AS (
  SELECT 'canonical_super_admin_fixture'::text check_name,
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('rows',count(*)) details
  FROM auth.users user_row JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  UNION ALL
  SELECT 'canonical_invoice_foundation_company_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*)) FROM eligible
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
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
