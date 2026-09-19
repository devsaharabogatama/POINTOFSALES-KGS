-- Read-only verification for 20260919130000.
WITH definition AS (
  SELECT pg_get_functiondef('public.export_sales_documents(date,date)'::regprocedure) body
), ledger AS (
  SELECT count(*) rows FROM private.kgs_schema_migrations WHERE version='20260919130000'
), invalid_office_line AS (
  SELECT line.id FROM public.backoffice_sales_invoice_lines line
  JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=line.company_id
    AND invoice.id=line.invoice_id
  WHERE line.line_type='PRODUCT' AND (line.product_id IS NULL OR line.uom_id IS NULL
    OR line.quantity_uom IS NULL OR line.quantity_uom<=0)
)
SELECT 'sales_invoice_export_union_ledger' check_name,
  CASE WHEN rows=1 THEN 'PASS' ELSE 'FAIL' END status,
  abs(rows-1) violation_rows,jsonb_build_object('ledgerRows',rows) details FROM ledger
UNION ALL
SELECT 'sales_invoice_export_union_runtime',
  CASE WHEN position('sales_invoice_snapshots' IN body)>0
    AND position('backoffice_sales_invoices' IN body)>0
    AND position('sourceKind' IN body)>0 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN position('sales_invoice_snapshots' IN body)>0
    AND position('backoffice_sales_invoices' IN body)>0
    AND position('sourceKind' IN body)>0 THEN 0 ELSE 1 END,
  jsonb_build_object('retailSource',position('sales_invoice_snapshots' IN body)>0,
    'backofficeSource',position('backoffice_sales_invoices' IN body)>0,
    'sourceIdentity',position('sourceKind' IN body)>0) FROM definition
UNION ALL
SELECT 'sales_invoice_export_office_product_shape',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
  jsonb_build_object('invalidRows',count(*)) FROM invalid_office_line
UNION ALL
SELECT 'sales_invoice_export_permission_contract',
  CASE WHEN has_function_privilege('authenticated','public.export_sales_documents(date,date)','EXECUTE')
    AND has_function_privilege('service_role','public.export_sales_documents(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon','public.export_sales_documents(date,date)','EXECUTE')
    THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN has_function_privilege('authenticated','public.export_sales_documents(date,date)','EXECUTE')
    AND has_function_privilege('service_role','public.export_sales_documents(date,date)','EXECUTE')
    AND NOT has_function_privilege('anon','public.export_sales_documents(date,date)','EXECUTE')
    THEN 0 ELSE 1 END,jsonb_build_object('authenticated',
      has_function_privilege('authenticated','public.export_sales_documents(date,date)','EXECUTE'));

