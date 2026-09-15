-- SELECT-only preflight for 20260911162000. Run the entire file.
WITH checks AS (
  SELECT 'dependency_ledger'::text check_name,
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    3-count(*) violation_rows,
    jsonb_build_object('expected',3,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260911150000','20260911160000','20260911161000')
  UNION ALL
  SELECT 'payment_ui_object_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existing',count(*))
  FROM (SELECT to_regclass('public.backoffice_sales_invoice_payment_operations')::text value
    UNION ALL SELECT to_regprocedure('public.get_backoffice_sales_invoice_payment_context(uuid)')::text
    UNION ALL SELECT to_regprocedure('public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)')::text) found
  WHERE value IS NOT NULL
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'canonical_payment_method_inventory','INFO',0,
    jsonb_build_object('activeMethods',count(*),'companies',count(DISTINCT company_id))
  FROM public.payment_methods WHERE is_active AND settlement_route IN('CASH_DRAWER','DIRECT_BANK')
  UNION ALL
  SELECT 'posted_invoice_runtime_inventory','INFO',0,
    jsonb_build_object('postedInvoices',count(*))
  FROM public.backoffice_sales_invoices WHERE status='POSTED'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
