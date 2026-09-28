-- Read-only gate for 20260928100000_sales_export_ro_reconciliation.sql.
WITH required_migrations(version) AS (VALUES
  ('20260919130000'),('20260918120000'),('20260918130000'),('20260924100000')
), missing_migrations AS (
  SELECT required.version FROM required_migrations required
  WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations installed
    WHERE installed.version=required.version)
), required_relations(name) AS (VALUES
  ('backoffice_negative_stock_allocations'),('negative_stock_sale_allocations'),
  ('purchase_daily_batches'),('purchase_daily_batch_lines'),
  ('stock_request_documents'),('stock_request_lines'),
  ('supplier_order_documents'),('supplier_order_lines'),
  ('supplier_order_request_allocations'),('goods_receipt_documents'),
  ('goods_receipt_lines'),('sales_return_documents'),('sales_return_lines'),
  ('sales_return_fifo_restorations'),('backoffice_sales_returns'),
  ('backoffice_sales_return_receipts'),('backoffice_sales_return_receipt_lines'),
  ('backoffice_sales_delivery_dispatches'),('backoffice_sales_delivery_dispatch_lines'),
  ('backoffice_sales_delivery_order_lines')
), missing_relations AS (
  SELECT required.name FROM required_relations required
  WHERE to_regclass('public.'||required.name) IS NULL
), target_company AS (
  SELECT company.id,company.company_name,company.company_code,company.status
  FROM public.companies company
  WHERE company.company_name IN(
    'Khadijah Muda Sejahtera','Latorti Sari Median','Smart Muda Solusi')
), invalid_open_source AS (
  SELECT allocation.id FROM public.negative_stock_sale_allocations allocation
  WHERE allocation.shortage_base_qty>allocation.replenished_base_qty
    AND allocation.reconciled_at IS NULL AND allocation.reversed_at IS NOT NULL
), collision AS (
  SELECT jsonb_build_object(
    'migrationRows',(SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260928100000'),
    'privateRoutine',to_regprocedure(
      'private.get_sales_export_ro_reconciliation_core(uuid,date,date)') IS NOT NULL,
    'publicRoutine',to_regprocedure(
      'public.export_sales_stock_reconciliation(date,date)') IS NOT NULL,
    'workbookRoutine',to_regprocedure(
      'public.export_sales_documents_with_reconciliation(date,date)') IS NOT NULL) details
)
SELECT 'sales_export_reconciliation_dependency_ledger' check_name,
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*) violation_rows,
  jsonb_build_object('missing',coalesce(jsonb_agg(version)
    FILTER(WHERE version IS NOT NULL),'[]'::jsonb)) details
FROM missing_migrations
UNION ALL
SELECT 'sales_export_reconciliation_required_relations',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('missing',coalesce(jsonb_agg(name)
    FILTER(WHERE name IS NOT NULL),'[]'::jsonb)) FROM missing_relations
UNION ALL
SELECT 'sales_export_reconciliation_target_company_identity',
  CASE WHEN count(*)=3 AND count(*) FILTER(WHERE status='ACTIVE')=3
    THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN count(*)=3 AND count(*) FILTER(WHERE status='ACTIVE')=3 THEN 0 ELSE 1 END,
  jsonb_build_object('rows',count(*),'companies',coalesce(jsonb_agg(to_jsonb(target_company)
    ORDER BY company_name),'[]'::jsonb)) FROM target_company
UNION ALL
SELECT 'sales_export_reconciliation_object_collision',
  CASE WHEN (details->>'migrationRows')::bigint=0
      AND NOT (details->>'privateRoutine')::boolean
      AND NOT (details->>'publicRoutine')::boolean
      AND NOT (details->>'workbookRoutine')::boolean THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN (details->>'migrationRows')::bigint=0
      AND NOT (details->>'privateRoutine')::boolean
      AND NOT (details->>'publicRoutine')::boolean
      AND NOT (details->>'workbookRoutine')::boolean THEN 0 ELSE 1 END,details FROM collision
UNION ALL
SELECT 'sales_export_reconciliation_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('rows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
UNION ALL
SELECT 'sales_export_reconciliation_nonterminal_offline',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('rows',count(*)) FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
UNION ALL
SELECT 'sales_export_reconciliation_reversed_source_boundary',
  'PASS',0,jsonb_build_object('excludedOpenReversedRows',count(*),
    'rule','Rows with reversed_at are intentionally excluded from clean RO demand')
  FROM invalid_open_source
UNION ALL
SELECT 'sales_export_reconciliation_runtime_inventory','INFO',0,
  jsonb_build_object(
    'openRetailShortage',(SELECT count(*) FROM public.negative_stock_sale_allocations a
      JOIN target_company c ON c.id=a.company_id
      WHERE a.reconciled_at IS NULL AND a.reversed_at IS NULL
        AND a.shortage_base_qty>a.replenished_base_qty),
    'openBackofficeShortage',(SELECT count(*) FROM public.backoffice_negative_stock_allocations a
      JOIN target_company c ON c.id=a.company_id
      WHERE a.reconciled_at IS NULL
        AND a.shortage_base_qty>a.replenished_base_qty),
    'draftRo',(SELECT count(*) FROM public.purchase_daily_batches b
      JOIN target_company c ON c.id=b.company_id WHERE b.status='DRAFT'));
