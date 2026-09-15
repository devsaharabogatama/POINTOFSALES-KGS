-- SELECT-only verification for 20260912140000.
WITH routines AS (
  SELECT to_regprocedure('private.backoffice_sales_order_invoice_summary(uuid,uuid)') summary,
    to_regprocedure('public.get_backoffice_sales_orders_v3(text,text,text,text,date,date,text,integer)') reader
), summaries AS (
  SELECT document.id,private.backoffice_sales_order_invoice_summary(document.company_id,document.id) value
  FROM public.backoffice_sales_orders document WHERE document.order_no IS NOT NULL
), checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912140000'
  UNION ALL
  SELECT 'so_invoice_status_required_routines',CASE WHEN summary IS NOT NULL AND reader IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
    (summary IS NULL)::integer+(reader IS NULL)::integer,jsonb_build_object('summaryExists',summary IS NOT NULL,'readerExists',reader IS NOT NULL) FROM routines
  UNION ALL
  SELECT 'so_invoice_status_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('invalidRows',count(*))
  FROM summaries WHERE value IS NULL OR value->>'invoiceStatus' NOT IN('NOT_READY','READY','DRAFT','PARTIALLY_INVOICED','INVOICED')
    OR jsonb_typeof(value->'activeInvoiceCount')<>'number' OR jsonb_typeof(value->'postedInvoiceCount')<>'number'
  UNION ALL
  SELECT 'so_invoice_status_draft_link',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('invalidRows',count(*))
  FROM summaries WHERE (value->>'invoiceStatus'='DRAFT')<>(value->>'draftInvoiceId' IS NOT NULL)
  UNION ALL
  SELECT 'so_invoice_status_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges WHERE specific_schema='private'
    AND routine_name='backoffice_sales_order_invoice_summary' AND grantee='authenticated' AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'so_invoice_status_runtime_inventory','INFO',0,jsonb_build_object(
    'notReady',(SELECT count(*) FROM summaries WHERE value->>'invoiceStatus'='NOT_READY'),
    'ready',(SELECT count(*) FROM summaries WHERE value->>'invoiceStatus'='READY'),
    'draft',(SELECT count(*) FROM summaries WHERE value->>'invoiceStatus'='DRAFT'),
    'partial',(SELECT count(*) FROM summaries WHERE value->>'invoiceStatus'='PARTIALLY_INVOICED'),
    'invoiced',(SELECT count(*) FROM summaries WHERE value->>'invoiceStatus'='INVOICED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
