-- SELECT-only verification of the exact master-data shape used by the
-- rollback-only Invoice tax-breakdown behavior test.
WITH linked_actor AS (
  SELECT profile.id
  FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1
), company_candidates AS (
  SELECT company.id
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS (
      SELECT 1 FROM public.stores store
      JOIN public.warehouses warehouse
        ON warehouse.company_id=store.company_id
       AND warehouse.is_active AND warehouse.is_sale_source
       AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE'
    )
    AND EXISTS (SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS (
      SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product
        ON product.company_id=product_uom.company_id
       AND product.id=product_uom.product_id
       AND product.is_active AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0
    )
    AND EXISTS (
      SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=company.id AND account.is_active AND account.is_postable
        AND account.is_system_account AND account.system_function_key='OUTPUT_TAX'
      UNION ALL
      SELECT 1 FROM public.company_account_function_fallbacks fallback
      JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
        AND account.id=fallback.account_id AND account.is_active AND account.is_postable
      WHERE fallback.company_id=company.id AND fallback.account_function_key='OUTPUT_TAX'
        AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
        AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
      UNION ALL
      SELECT 1 FROM public.transaction_account_rules rule
      JOIN public.transaction_categories category ON category.company_id=rule.company_id
        AND category.id=rule.transaction_category_id AND category.is_active
      JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
        AND account.id=rule.account_id AND account.is_active AND account.is_postable
      WHERE rule.company_id=company.id AND rule.system_key='SALE_POSTED'
        AND category.system_key='SALE_POSTED' AND rule.account_function_key='OUTPUT_TAX'
        AND rule.status='ACTIVE' AND rule.effective_from<=clock_timestamp()
        AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
    )
), checks AS (
  SELECT 'invoice_tax_behavior_linked_actor'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('linkedSuperAdminRows',count(*)) details FROM linked_actor
  UNION ALL
  SELECT 'invoice_tax_behavior_company_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*),
      'required','Compatible Store/Sales Warehouse, Customer, positive-factor Product-UOM, and OUTPUT_TAX account source')
  FROM company_candidates
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 ELSE 2 END,check_name;
