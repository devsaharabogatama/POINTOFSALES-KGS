-- SELECT-only gate. Run on isolated Development before 20260912140000.
WITH routines AS (
  SELECT to_regprocedure('private.backoffice_sales_order_invoice_summary(uuid,uuid)') summary,
    to_regprocedure('public.get_backoffice_sales_orders_v3(text,text,text,text,date,date,text,integer)') reader
), checks AS (
  SELECT 'so_invoice_status_dependency_ledger'::text check_name,
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END status,5-count(*) violation_rows,
    jsonb_build_object('present',count(*),'expected',5) details
  FROM private.kgs_schema_migrations WHERE version IN(
    '20260909142000','20260909152000','20260910150000','20260912123000','20260912137000')
  UNION ALL
  SELECT 'so_invoice_status_routine_collision',
    CASE WHEN summary IS NULL AND reader IS NULL THEN 'PASS' ELSE 'BLOCKER' END,
    (summary IS NOT NULL)::integer+(reader IS NOT NULL)::integer,
    jsonb_build_object('summaryExists',summary IS NOT NULL,'readerExists',reader IS NOT NULL)
  FROM routines
  UNION ALL
  SELECT 'so_invoice_status_quantity_ledger_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.to_invoice_base_qty<0 OR line.net_delivered_base_qty<0
  UNION ALL
  SELECT 'so_invoice_status_overage_ledger_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.overage_to_invoice_base_qty<0 OR line.accepted_overage_base_qty<0
  UNION ALL
  SELECT 'so_invoice_status_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'so_invoice_status_runtime_inventory','INFO',0,jsonb_build_object(
    'salesOrders',(SELECT count(*) FROM public.backoffice_sales_orders WHERE order_no IS NOT NULL),
    'activeDraftInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='DRAFT'),
    'postedInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='POSTED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
