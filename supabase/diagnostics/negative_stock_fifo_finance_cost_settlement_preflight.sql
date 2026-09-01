-- Negative Stock FIFO / Finance cost-settlement preflight.
-- SAFETY: SELECT-only. This file performs no data or schema mutation.

WITH required_migrations(version) AS (
  VALUES
    ('20260805220000'::TEXT),
    ('20260814140000'::TEXT),
    ('20260814143000'::TEXT),
    ('20260828260000'::TEXT)
), dependency AS (
  SELECT array_agg(required.version ORDER BY required.version)
    FILTER (WHERE applied.version IS NULL) missing
  FROM required_migrations required
  LEFT JOIN private.kgs_schema_migrations applied
    ON applied.version=required.version
), active_queue AS (
  SELECT count(*)::BIGINT run_count
  FROM public.finance_posting_queue_runs run
  WHERE run.status IN ('PREVIEWED','APPROVED','PROCESSING')
), negative_inventory AS (
  SELECT count(*)::BIGINT allocation_count,
    count(*) FILTER (WHERE allocation.reconciled_at IS NULL)::BIGINT open_count,
    COALESCE(sum(allocation.shortage_base_qty),0) shortage_base_qty,
    COALESCE(sum(allocation.replenished_base_qty),0) replenished_base_qty,
    COALESCE(sum(allocation.provisional_cost_total),0) provisional_cost_total,
    COALESCE(sum(allocation.actual_cost_total),0) actual_cost_total,
    COALESCE(sum(allocation.cost_variance_total),0) cost_variance_total
  FROM public.negative_stock_sale_allocations allocation
), replenishment_scope AS (
  SELECT receipt.company_id,receipt.id receipt_id,receipt.receipt_no,
    receipt.financial_event_id,event.status::TEXT event_status,
    count(replenishment.id)::BIGINT settlement_rows,
    COALESCE(sum(replenishment.replenished_base_qty),0) replenished_base_qty,
    COALESCE(sum(replenishment.cost_variance_total),0) cost_variance_total
  FROM public.negative_stock_replenishment_allocations replenishment
  JOIN public.product_batches batch
    ON batch.company_id=replenishment.company_id
   AND batch.id=replenishment.product_batch_id
  JOIN public.goods_receipt_lines receipt_line
    ON receipt_line.company_id=batch.company_id
   AND receipt_line.id=batch.goods_receipt_line_id
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id
  LEFT JOIN public.financial_events event
    ON event.company_id=receipt.company_id
   AND event.id=receipt.financial_event_id
  GROUP BY receipt.company_id,receipt.id,receipt.receipt_no,
    receipt.financial_event_id,event.status
), invoice_scope AS (
  SELECT invoice.company_id,invoice.id invoice_id,invoice.invoice_no,
    event.status::TEXT event_status,
    count(allocation.id)::BIGINT allocation_rows,
    COALESCE(sum(allocation.allocated_base_qty),0) allocated_base_qty,
    COALESCE(sum(allocation.price_variance),0) price_variance
  FROM public.supplier_invoice_documents invoice
  JOIN public.supplier_invoice_allocations allocation
    ON allocation.company_id=invoice.company_id
   AND allocation.document_id=invoice.id
  LEFT JOIN public.financial_events event
    ON event.company_id=invoice.company_id
   AND event.id=invoice.financial_event_id
  WHERE invoice.status='VALIDATED'
  GROUP BY invoice.company_id,invoice.id,invoice.invoice_no,event.status
), mapping_requirements(system_event_key,function_key) AS (
  VALUES
    ('GOODS_RECEIPT'::TEXT,'INVENTORY_ASSET'::TEXT),
    ('GOODS_RECEIPT'::TEXT,'COGS'::TEXT),
    ('SUPPLIER_INVOICE'::TEXT,'INVENTORY_ASSET'::TEXT),
    ('SUPPLIER_INVOICE'::TEXT,'COGS'::TEXT),
    ('SUPPLIER_INVOICE'::TEXT,'PURCHASE_PRICE_VARIANCE'::TEXT)
), active_companies AS (
  SELECT company.id company_id,company.company_code
  FROM public.companies company
  WHERE COALESCE(company.status,'ACTIVE')='ACTIVE'
), mapping_resolution AS (
  SELECT company.company_id,company.company_code,
    required.system_event_key,required.function_key,
    CASE
      WHEN rule_state.candidate_count=1 THEN 'TRANSACTION_RULE'
      WHEN rule_state.candidate_count>1 THEN 'AMBIGUOUS_TRANSACTION_RULE'
      WHEN fallback_state.candidate_count=1 THEN 'COMPANY_FALLBACK'
      WHEN fallback_state.candidate_count>1 THEN 'AMBIGUOUS_COMPANY_FALLBACK'
      WHEN system_state.candidate_count=1 THEN 'SYSTEM_ACCOUNT'
      WHEN system_state.candidate_count>1 THEN 'AMBIGUOUS_SYSTEM_ACCOUNT'
      ELSE 'MISSING'
    END resolution
  FROM active_companies company
  CROSS JOIN mapping_requirements required
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT rule.account_id)::BIGINT candidate_count
    FROM public.transaction_account_rules rule
    JOIN public.transaction_categories category
      ON category.company_id=rule.company_id
     AND category.id=rule.transaction_category_id
     AND category.system_key=required.system_event_key
     AND category.is_active
    JOIN public.chart_of_accounts account
      ON account.company_id=rule.company_id AND account.id=rule.account_id
     AND account.is_active AND account.is_postable
    WHERE rule.company_id=company.company_id
      AND rule.account_function_key=required.function_key
      AND rule.status='ACTIVE'
      AND rule.effective_from<=clock_timestamp()
      AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp())
  ) rule_state ON TRUE
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT fallback.account_id)::BIGINT candidate_count
    FROM public.company_account_function_fallbacks fallback
    JOIN public.chart_of_accounts account
      ON account.company_id=fallback.company_id
     AND account.id=fallback.account_id
     AND account.is_active AND account.is_postable
    WHERE fallback.company_id=company.company_id
      AND fallback.account_function_key=required.function_key
      AND fallback.status='ACTIVE'
      AND fallback.effective_from<=clock_timestamp()
      AND (fallback.effective_to IS NULL
        OR fallback.effective_to>clock_timestamp())
  ) fallback_state ON TRUE
  LEFT JOIN LATERAL (
    SELECT count(*)::BIGINT candidate_count
    FROM public.chart_of_accounts account
    WHERE account.company_id=company.company_id
      AND account.system_function_key=required.function_key
      AND account.is_active AND account.is_postable
  ) system_state ON TRUE
), invalid_mapping AS (
  SELECT count(*)::BIGINT invalid_rows,
    COALESCE(jsonb_agg(jsonb_build_object(
      'companyCode',mapping.company_code,
      'systemEventKey',mapping.system_event_key,
      'functionKey',mapping.function_key,
      'resolution',mapping.resolution
    ) ORDER BY mapping.company_code,mapping.system_event_key,
      mapping.function_key)
      FILTER (WHERE mapping.resolution='MISSING'
        OR mapping.resolution LIKE 'AMBIGUOUS%'),'[]'::JSONB) details
  FROM mapping_resolution mapping
  WHERE mapping.resolution='MISSING'
     OR mapping.resolution LIKE 'AMBIGUOUS%'
), checks AS (
  SELECT 'nsc_migration_dependencies' check_name,
    CASE WHEN COALESCE(cardinality(dependency.missing),0)=0
      THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('missing',COALESCE(to_jsonb(dependency.missing),'[]'::JSONB),
      'expected',4) details
  FROM dependency

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN active_queue.run_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('runCount',active_queue.run_count)
  FROM active_queue

  UNION ALL
  SELECT 'negative_stock_cost_inventory','INFO',to_jsonb(negative_inventory)
  FROM negative_inventory

  UNION ALL
  SELECT 'negative_replenishment_finance_scope',
    CASE
      WHEN count(*) FILTER (WHERE scope.event_status IS NULL)>0 THEN 'BLOCKER'
      WHEN count(*) FILTER (WHERE scope.event_status='POSTED'
        AND scope.cost_variance_total<>0)>0 THEN 'BACKFILL'
      WHEN count(*) FILTER (WHERE scope.event_status='HOLD'
        AND scope.cost_variance_total<>0)>0 THEN 'SETUP'
      ELSE 'PASS'
    END,
    jsonb_build_object(
      'receiptCount',count(*),
      'postedVarianceReceipts',count(*) FILTER(
        WHERE scope.event_status='POSTED' AND scope.cost_variance_total<>0),
      'holdVarianceReceipts',count(*) FILTER(
        WHERE scope.event_status='HOLD' AND scope.cost_variance_total<>0),
      'varianceTotal',COALESCE(sum(scope.cost_variance_total),0))
  FROM replenishment_scope scope

  UNION ALL
  SELECT 'supplier_invoice_batch_revaluation_scope',
    CASE
      WHEN count(*) FILTER (WHERE scope.event_status IS NULL)>0 THEN 'BLOCKER'
      WHEN count(*) FILTER (WHERE scope.event_status='POSTED'
        AND scope.price_variance<>0)>0 THEN 'BACKFILL'
      WHEN count(*) FILTER (WHERE scope.event_status='HOLD'
        AND scope.price_variance<>0)>0 THEN 'SETUP'
      ELSE 'PASS'
    END,
    jsonb_build_object(
      'invoiceCount',count(*),
      'postedVarianceInvoices',count(*) FILTER(
        WHERE scope.event_status='POSTED' AND scope.price_variance<>0),
      'holdVarianceInvoices',count(*) FILTER(
        WHERE scope.event_status='HOLD' AND scope.price_variance<>0),
      'priceVarianceTotal',COALESCE(sum(scope.price_variance),0))
  FROM invoice_scope scope

  UNION ALL
  SELECT 'cost_variance_account_resolution',
    CASE WHEN invalid_mapping.invalid_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',invalid_mapping.invalid_rows,
      'details',invalid_mapping.details)
  FROM invalid_mapping

  UNION ALL
  SELECT 'nsc_foundation_schema_state',
    CASE WHEN to_regclass('public.supplier_invoice_batch_cost_allocations')
      IS NULL THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('batchCostAllocationExists',
      to_regclass('public.supplier_invoice_batch_cost_allocations') IS NOT NULL,
      'costAdjustmentSourceExists',
      to_regclass('public.inventory_cost_adjustment_sources') IS NOT NULL)
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
