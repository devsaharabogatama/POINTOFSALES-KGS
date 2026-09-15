-- SELECT-only verification of the exact master-data shape used by the
-- rollback-only Draft Invoice runtime behavior test.
WITH linked_actor AS (
  SELECT profile.id
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id
  LIMIT 1
), company_candidates AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS (
      SELECT 1
      FROM public.stores store
      JOIN public.warehouses warehouse
        ON warehouse.company_id=store.company_id
       AND warehouse.is_active
       AND warehouse.is_sale_source
       AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id
        AND store.status='ACTIVE'
    )
    AND EXISTS (
      SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active
    )
    AND EXISTS (
      SELECT 1
      FROM public.product_uoms product_uom
      JOIN public.products product
        ON product.company_id=product_uom.company_id
       AND product.id=product_uom.product_id
       AND product.is_active
       AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id
        AND product_uom.is_active
        AND product_uom.sales_allowed
        AND product_uom.factor_to_base>0
    )
), checks AS (
  SELECT 'draft_invoice_behavior_linked_actor'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('linkedSuperAdminRows',count(*)) details
  FROM linked_actor
  UNION ALL
  SELECT 'draft_invoice_behavior_company_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*),
      'required','Active Company with compatible active Store/Sales Warehouse, Customer, and positive-factor sales Product-UOM')
  FROM company_candidates
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
