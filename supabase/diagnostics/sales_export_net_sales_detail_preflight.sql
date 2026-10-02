-- Read-only gate for 20261002100000_sales_export_net_sales_detail.sql.
WITH required_migrations(version) AS (VALUES
  ('20260919130000'),('20260928100000')
), missing_migrations AS (
  SELECT required.version FROM required_migrations required
  WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations installed
    WHERE installed.version=required.version)
), required_relations(name) AS (VALUES
  ('sales_invoice_snapshots'),('sales_headers'),('sales_details'),
  ('sales_return_documents'),('sales_return_lines'),('stock_movements'),
  ('backoffice_sales_invoices'),('backoffice_sales_invoice_lines'),
  ('backoffice_sales_returns'),('backoffice_sales_return_receipt_lines'),
  ('backoffice_sales_return_invoice_allocations')
), missing_relations AS (
  SELECT required.name FROM required_relations required
  WHERE to_regclass('public.'||required.name) IS NULL
), collision AS (
  SELECT (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261002100000') ledger_rows,
    to_regprocedure('private.get_sales_export_net_detail_core(uuid,date,date)')
      IS NOT NULL routine_exists
), invalid_backoffice_lineage AS (
  SELECT allocation.id
  FROM public.backoffice_sales_return_invoice_allocations allocation
  LEFT JOIN public.backoffice_sales_invoice_lines invoice_line
    ON invoice_line.company_id=allocation.company_id
   AND invoice_line.id=allocation.invoice_line_id
  LEFT JOIN public.backoffice_sales_return_receipt_lines receipt_line
    ON receipt_line.company_id=allocation.company_id
   AND receipt_line.id=allocation.return_receipt_line_id
  WHERE allocation.source_kind='BACKOFFICE' AND allocation.invoice_id IS NOT NULL
    AND (invoice_line.id IS NULL OR receipt_line.id IS NULL)
)
SELECT 'sales_export_net_detail_dependency_ledger' check_name,
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*) violation_rows,
  jsonb_build_object('missing',coalesce(jsonb_agg(version)
    FILTER(WHERE version IS NOT NULL),'[]'::jsonb)) details
FROM missing_migrations
UNION ALL
SELECT 'sales_export_net_detail_required_relations',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('missing',coalesce(jsonb_agg(name)
    FILTER(WHERE name IS NOT NULL),'[]'::jsonb)) FROM missing_relations
UNION ALL
SELECT 'sales_export_net_detail_object_collision',
  CASE WHEN ledger_rows=0 AND NOT routine_exists THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN ledger_rows=0 AND NOT routine_exists THEN 0 ELSE 1 END,
  jsonb_build_object('ledgerRows',ledger_rows,'routineExists',routine_exists)
FROM collision
UNION ALL
SELECT 'sales_export_net_detail_backoffice_lineage',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('invalidRows',count(*)) FROM invalid_backoffice_lineage
UNION ALL
SELECT 'sales_export_net_detail_active_finance_queue',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('rows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
UNION ALL
SELECT 'sales_export_net_detail_nonterminal_offline',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('rows',count(*)) FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
UNION ALL
SELECT 'sales_export_net_detail_runtime_inventory','INFO',0,
  jsonb_build_object(
    'retailInvoiceLines',(SELECT count(*) FROM public.sales_details detail
      JOIN public.sales_invoice_snapshots snapshot
        ON snapshot.company_id=detail.company_id AND snapshot.sales_id=detail.sales_id),
    'backofficeInvoiceLines',(SELECT count(*) FROM public.backoffice_sales_invoice_lines
      WHERE line_type='PRODUCT' AND effect_type='CHARGE'),
    'postedNativeReturnLines',(SELECT count(*) FROM public.sales_return_lines line
      JOIN public.sales_return_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
      WHERE document.status='POSTED'),
    'receivedBackofficeReturnLines',(
      SELECT count(*) FROM public.backoffice_sales_return_receipt_lines));
