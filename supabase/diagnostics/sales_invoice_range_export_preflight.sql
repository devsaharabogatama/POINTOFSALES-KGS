-- Sales Invoice date-range XLSX export preflight. SELECT-only.
WITH checks(check_name,status,details,sort_order) AS (
  SELECT 'migration_dependency',
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260830110000') THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('requiredVersion','20260830110000','ledgerRows',(
      SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260830110000')),1
  UNION ALL
  SELECT 'compatible_sales_document_export_rpc',
    CASE WHEN to_regprocedure('public.export_sales_documents()') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('noArgumentRpcExists',
      to_regprocedure('public.export_sales_documents()') IS NOT NULL),2
  UNION ALL
  SELECT 'range_export_rpc_state',
    CASE WHEN to_regprocedure('public.export_sales_documents(date,date)') IS NULL
      THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('rangeRpcExists',
      to_regprocedure('public.export_sales_documents(date,date)') IS NOT NULL),3
  UNION ALL
  SELECT 'sales_document_export_permission',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(enforcement_status),'[]'::JSONB)),4
  FROM public.access_permission_catalog WHERE permission_key='sales.sales_documents'
  UNION ALL
  SELECT 'invoice_snapshot_line_shape',
    CASE WHEN count(*) FILTER(WHERE jsonb_typeof(snapshot_payload->'lines') IS DISTINCT FROM 'array')=0
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invoiceCount',count(*),'invalidRows',
      count(*) FILTER(WHERE jsonb_typeof(snapshot_payload->'lines') IS DISTINCT FROM 'array')),5
  FROM public.sales_invoice_snapshots
  UNION ALL
  SELECT 'duplicate_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicateGroups',count(*)),6
  FROM (SELECT company_id,invoice_no FROM public.sales_invoice_snapshots
    GROUP BY company_id,invoice_no HAVING count(*)>1) duplicate_row
  UNION ALL
  SELECT 'sales_invoice_export_inventory','INFO',jsonb_build_object(
    'companies',count(DISTINCT company_id),'invoices',count(*),
    'lineSnapshots',COALESCE(sum(CASE WHEN jsonb_typeof(snapshot_payload->'lines')='array'
      THEN jsonb_array_length(snapshot_payload->'lines') ELSE 0 END),0)),7
  FROM public.sales_invoice_snapshots
)
SELECT check_name,status,details FROM checks ORDER BY sort_order,check_name;
