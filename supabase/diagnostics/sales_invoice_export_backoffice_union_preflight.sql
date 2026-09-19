-- Read-only gate for 20260919130000_sales_invoice_export_backoffice_union.sql.
WITH required_relations(name) AS (VALUES
  ('sales_invoice_snapshots'),('sales_headers'),('backoffice_sales_invoices'),
  ('backoffice_sales_invoice_lines'),('backoffice_sales_orders'),
  ('backoffice_sales_order_lines'),('customer_receipt_backoffice_invoice_allocations')
), missing AS (
  SELECT name FROM required_relations
  WHERE to_regclass('public.'||name) IS NULL
), definition AS (
  SELECT pg_get_functiondef('public.export_sales_documents(date,date)'::regprocedure) body
)
SELECT 'sales_invoice_export_dependency_contract' check_name,
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*) violation_rows,
  jsonb_build_object('missing',COALESCE(jsonb_agg(name) FILTER(WHERE name IS NOT NULL),'[]'::jsonb)) details
FROM missing
UNION ALL
SELECT 'sales_invoice_export_runtime_anchor',
  CASE WHEN position('sales_invoice_snapshots' IN body)>0
    AND position('backoffice_sales_invoices' IN body)=0 THEN 'PASS' ELSE 'BLOCKER' END,
  CASE WHEN position('sales_invoice_snapshots' IN body)>0
    AND position('backoffice_sales_invoices' IN body)=0 THEN 0 ELSE 1 END,
  jsonb_build_object('retailAnchor',position('sales_invoice_snapshots' IN body)>0,
    'backofficeAlreadyPresent',position('backoffice_sales_invoices' IN body)>0)
FROM definition
UNION ALL
SELECT 'sales_invoice_export_migration_ledger',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
  jsonb_build_object('ledgerRows',count(*))
FROM private.kgs_schema_migrations WHERE version='20260919130000'
UNION ALL
SELECT 'sales_invoice_export_runtime_inventory','INFO',0,
  jsonb_build_object(
    'retailInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'backofficeInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices),
    'backofficeLines',(SELECT count(*) FROM public.backoffice_sales_invoice_lines),
    'backofficeStatuses',COALESCE((SELECT jsonb_agg(to_jsonb(item) ORDER BY item.status)
      FROM (SELECT status,count(*) rows FROM public.backoffice_sales_invoices GROUP BY status) item),'[]'::jsonb));

