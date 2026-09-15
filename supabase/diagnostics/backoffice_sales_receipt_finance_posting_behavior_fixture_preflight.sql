-- SELECT-only fixture inventory for Customer Receipt Finance posting behavior.
WITH eligible AS (
  SELECT DISTINCT company.id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date company_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
    AND NOT product.is_bundle AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
    AND EXISTS (SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='STOCK_TRANSFER'
        AND category.is_active AND category.is_system_default)
    AND (SELECT count(DISTINCT rule.account_function_key)
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
        AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id
        AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
        AND rule.account_function_key IN('COGS','INVENTORY_ASSET'))=2
), postable AS (
  SELECT eligible.id
  FROM eligible
  WHERE EXISTS (SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=eligible.id AND period.status IN('OPEN','REOPENED')
        AND period.end_date>=eligible.company_today)
    OR EXISTS (
      SELECT 1 FROM generate_series(date_trunc('month',eligible.company_today::timestamp),
        date_trunc('month',eligible.company_today::timestamp)+interval '10 years',
        interval '1 month') candidate(month_start)
      WHERE NOT EXISTS (SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=eligible.id
          AND daterange(period.start_date,period.end_date,'[]') && daterange(
            candidate.month_start::date,
            (candidate.month_start+interval '1 month'-interval '1 day')::date,'[]')))
), checks AS (
  SELECT 'canonical_super_admin_fixture'::text check_name,
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END::text status,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('rows',count(*)) details
  FROM auth.users user_row JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  UNION ALL
  SELECT 'canonical_receipt_finance_posting_fixture',
    CASE WHEN count(*)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)>0 THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('eligibleCompanies',count(*)) FROM postable
  UNION ALL
  SELECT 'cross_tenant_fixture',
    CASE WHEN count(*)>1 THEN 'PASS' ELSE 'INFO' END,
    0::bigint,jsonb_build_object('activeCompanies',count(*))
  FROM public.companies WHERE status='ACTIVE'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
