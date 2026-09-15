-- Read-only fixture preflight for backoffice_sales_delivery_fee_parity_behavior.sql.
-- Run only after migrations 20260910150000 and 20260910151000.
WITH actor_fixture AS (
  SELECT profile.id
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id
  LIMIT 1
), company_fixture AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS (
      SELECT 1
      FROM public.stores store
      JOIN public.warehouses warehouse
        ON warehouse.company_id=store.company_id
       AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id
        AND store.status='ACTIVE'
        AND warehouse.is_active
        AND warehouse.is_sale_source
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
    AND EXISTS (
      SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id
        AND period.status IN('OPEN','REOPENED')
        AND current_date BETWEEN period.start_date AND period.end_date
    )
    AND EXISTS (
      SELECT 1
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule
        ON rule.company_id=category.company_id
       AND rule.transaction_category_id=category.id
      WHERE category.company_id=company.id
        AND category.is_active
        AND category.system_key='BACKOFFICE_SALES_INVOICE'
        AND rule.system_key='BACKOFFICE_SALES_INVOICE'
        AND rule.account_function_key='DELIVERY_FEE_REVENUE'
        AND rule.status='ACTIVE'
    )
  ORDER BY company.id
), checks AS (
  SELECT 'delivery_fee_behavior_actor_fixture'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('linkedSuperAdminRows',count(*)) details
  FROM actor_fixture
  UNION ALL
  SELECT 'delivery_fee_behavior_company_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*))
  FROM company_fixture
  UNION ALL
  SELECT 'delivery_fee_behavior_dependency_ledger',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(2-count(*))::bigint,
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations
  WHERE version IN('20260910150000','20260910151000')
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 ELSE 1 END,check_name;
