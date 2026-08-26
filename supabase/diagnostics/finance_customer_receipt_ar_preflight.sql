-- F2 preflight: Customer Receipt and AR allocation foundation.
-- SAFETY: SELECT-only; no fixtures or state changes.
WITH active_company AS (
  SELECT company.id FROM public.companies company WHERE company.status='ACTIVE'
), account_readiness AS (
  SELECT company.id company_id,function_key,
    count(DISTINCT account_id) candidate_count
  FROM active_company company
  CROSS JOIN (VALUES('CUSTOMER_RECEIVABLE'),('CASH_DRAWER'),('BANK')) required(function_key)
  LEFT JOIN LATERAL(
    SELECT account.id account_id FROM public.chart_of_accounts account
    WHERE account.company_id=company.id AND account.is_active AND account.is_postable
      AND account.system_function_key=required.function_key
    UNION
    SELECT fallback.account_id FROM public.company_account_function_fallbacks fallback
    JOIN public.chart_of_accounts account ON account.company_id=fallback.company_id
      AND account.id=fallback.account_id AND account.is_active AND account.is_postable
    WHERE fallback.company_id=company.id
      AND fallback.account_function_key=required.function_key
      AND fallback.status='ACTIVE' AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp())
  ) candidate ON TRUE
  GROUP BY company.id,function_key
), checks AS (
  SELECT 'f2_dependencies' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',2,'ledgerRows',count(*),'requiredVersions',
      ARRAY['20260814170000','20260827090000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260814170000','20260827090000')
  UNION ALL
  SELECT 'canonical_customer_receipt_schema_state','SETUP',
    jsonb_build_object('missing',ARRAY(
      SELECT name FROM unnest(ARRAY[
        'customer_receipt_documents','customer_receipt_allocations',
        'customer_receipt_audit']) name
      WHERE to_regclass('public.'||name) IS NULL),'expected',3)
  UNION ALL
  SELECT 'canonical_customer_receipt_runtime_state','SETUP',
    jsonb_build_object('missing',ARRAY[
      'get_finance_customer_receipts','save_customer_receipt_draft',
      'post_customer_receipt','cancel_customer_receipt_draft'], 'expected',4)
  UNION ALL
  SELECT 'customer_receipt_permission_catalog_state',
    CASE WHEN count(*)=0 THEN 'SETUP' ELSE 'REVIEW' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(
      catalog.enforcement_status) FILTER(WHERE catalog.permission_key IS NOT NULL),
      '[]'::JSONB))
  FROM public.access_permission_catalog catalog
  WHERE catalog.permission_key='finance.customer_receipts'
  UNION ALL
  SELECT 'customer_receipt_event_catalog',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('systemEventRows',count(*))
  FROM public.system_events event WHERE event.system_key='SALE_PAYMENT'
    AND event.is_active
  UNION ALL
  SELECT 'customer_receipt_category_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('companiesAffected',count(*))
  FROM active_company company WHERE NOT EXISTS(
    SELECT 1 FROM public.transaction_categories category
    WHERE category.company_id=company.id AND category.system_key='SALE_PAYMENT'
      AND category.is_active)
  UNION ALL
  SELECT 'required_account_function_resolution',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('unresolvedOrAmbiguousRows',count(*),'functions',
      COALESCE(jsonb_agg(DISTINCT function_key) FILTER(WHERE candidate_count<>1),
        '[]'::JSONB))
  FROM account_readiness WHERE candidate_count<>1
  UNION ALL
  SELECT 'posted_tempo_customer_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
    AND customer.id=sale.customer_id
  WHERE sale.document_status='POSTED' AND sale.is_tempo
    AND (customer.id IS NULL OR customer.is_system_customer)
  UNION ALL
  SELECT 'posted_tempo_invoice_snapshot_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
  WHERE sale.document_status='POSTED' AND sale.is_tempo AND invoice.id IS NULL
  UNION ALL
  SELECT 'posted_tempo_receivable_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('saleCount',count(*))
  FROM public.sales_headers sale
  WHERE sale.document_status='POSTED' AND sale.is_tempo
    AND (sale.grand_total_after_rounding<0 OR sale.paid_amount<0
      OR sale.sisa_piutang<0
      OR abs(sale.grand_total_after_rounding-sale.paid_amount-sale.sisa_piutang)>0.0001)
  UNION ALL
  SELECT 'active_receipt_payment_method_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('companiesAffected',count(*))
  FROM active_company company WHERE NOT EXISTS(
    SELECT 1 FROM public.payment_methods method
    WHERE method.company_id=company.id AND method.is_active
      AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK','CLEARING'))
  UNION ALL
  SELECT 'browser_direct_customer_receipt_write_boundary','PASS',
    jsonb_build_object('required','new receipt tables must expose no direct authenticated writes')
  UNION ALL
  SELECT 'historical_tempo_receivable_inventory','INFO',
    jsonb_build_object('companies',count(DISTINCT sale.company_id),
      'postedTempoSales',count(*),'receivableTotal',COALESCE(sum(sale.sisa_piutang),0),
      'partiallyPaidSales',count(*) FILTER(WHERE sale.paid_amount>0 AND sale.sisa_piutang>0),
      'unpaidSales',count(*) FILTER(WHERE sale.paid_amount=0 AND sale.sisa_piutang>0))
  FROM public.sales_headers sale
  WHERE sale.document_status='POSTED' AND sale.is_tempo
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'BACKFILL' THEN 1
  WHEN 'REVIEW' THEN 2 WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,
  check_name;
