-- SELECT-only postflight for 20260911163000. Run the entire file.
WITH routine_contract AS (
  SELECT procedure.proname,procedure.prosecdef,procedure.provolatile,
    array_to_string(procedure.proconfig,',') config,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.oid IN(
    'public.get_finance_customer_receipts()'::regprocedure,
    'public.get_finance_ar_aging(date,uuid,uuid)'::regprocedure,
    'public.get_finance_customer_statement(uuid,date,date,uuid)'::regprocedure,
    'public.post_customer_receipt_unified(uuid,bigint,uuid)'::regprocedure)
),checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911163000'
  UNION ALL
  SELECT 'required_unified_reporting_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*))::bigint,jsonb_build_object('expected',4,'routineRows',count(*)) FROM routine_contract
  UNION ALL
  SELECT 'unified_reporting_security_contract',
    CASE WHEN count(*)=4 AND bool_and(prosecdef) AND bool_and(config ILIKE '%search_path=public, pg_temp%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=4 AND bool_and(prosecdef) AND bool_and(config ILIKE '%search_path=public, pg_temp%')
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',bool_and(prosecdef),
      'searchPath',bool_and(config ILIKE '%search_path=public, pg_temp%')) FROM routine_contract
  UNION ALL
  SELECT 'reader_source_contract',CASE WHEN count(*)=3 AND bool_and(valid) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3 AND bool_and(valid) THEN 0 ELSE 1 END,
    jsonb_build_object('readerRows',count(*),'contractsValid',bool_and(valid))
  FROM (SELECT proname,CASE proname
      WHEN 'get_finance_customer_receipts' THEN definition ILIKE '%customer_receipt_allocations%'
        AND definition ILIKE '%customer_receipt_backoffice_invoice_allocations%'
      WHEN 'get_finance_ar_aging' THEN definition ILIKE '%customer_receipt_allocations%'
        AND definition ILIKE '%backoffice_sales_invoice_receivable_schedules%'
      WHEN 'get_finance_customer_statement' THEN definition ILIKE '%customer_receipt_allocations%'
        AND definition ILIKE '%customer_receipt_backoffice_invoice_allocations%'
      ELSE false END valid
    FROM routine_contract WHERE proname IN('get_finance_customer_receipts','get_finance_ar_aging','get_finance_customer_statement')) reader
  UNION ALL
  SELECT 'unified_post_rpc_boundary',
    CASE WHEN has_function_privilege('anon','public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE')=false
      AND has_function_privilege('authenticated','public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('anon','public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE')=false
      AND has_function_privilege('authenticated','public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',has_function_privilege('anon','public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated','public.post_customer_receipt_unified(uuid,bigint,uuid)','EXECUTE'))
  UNION ALL
  SELECT 'unified_post_dispatch_contract',
    CASE WHEN definition ILIKE '%post_customer_receipt_allocated%'
      AND definition ILIKE '%post_customer_receipt_with_disposition%'
      AND definition ILIKE '%customer_receipt_backoffice_invoice_allocations%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition ILIKE '%post_customer_receipt_allocated%'
      AND definition ILIKE '%post_customer_receipt_with_disposition%'
      AND definition ILIKE '%customer_receipt_backoffice_invoice_allocations%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('allocatedAndAdvanceBranches',
      definition ILIKE '%post_customer_receipt_allocated%'
      AND definition ILIKE '%post_customer_receipt_with_disposition%')
  FROM routine_contract WHERE proname='post_customer_receipt_unified'
  UNION ALL
  SELECT 'posted_backoffice_schedule_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidInvoices',count(*))
  FROM (SELECT invoice.company_id,invoice.id
    FROM public.backoffice_sales_invoices invoice
    JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    WHERE invoice.status='POSTED'
    GROUP BY invoice.company_id,invoice.id,invoice.grand_total
    HAVING round(sum(schedule.amount_due),4)<>round(invoice.grand_total,4)
      OR bool_or(schedule.allocated_payment_amount<0 OR schedule.allocated_payment_amount>schedule.amount_due)
  ) invalid
  UNION ALL
  SELECT 'cross_source_receipt_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidReceipts',count(*))
  FROM (SELECT document.company_id,document.id,document.total_amount,
      COALESCE(retail.allocated,0)+COALESCE(backoffice.allocated,0) allocated
    FROM public.customer_receipt_documents document
    LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) allocated
      FROM public.customer_receipt_allocations allocation
      WHERE allocation.company_id=document.company_id AND allocation.document_id=document.id) retail ON true
    LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) allocated
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      WHERE allocation.company_id=document.company_id AND allocation.document_id=document.id) backoffice ON true
    WHERE document.unapplied_disposition='NONE'
      AND round(document.total_amount,4)<>round(COALESCE(retail.allocated,0)+COALESCE(backoffice.allocated,0),4)
  ) invalid
  UNION ALL
  SELECT 'unified_reporting_runtime_inventory','INFO',0::bigint,
    jsonb_build_object('retailAllocations',(SELECT count(*) FROM public.customer_receipt_allocations),
      'backofficeAllocations',(SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations),
      'postedBackofficeInvoices',(SELECT count(*) FROM public.backoffice_sales_invoices WHERE status='POSTED'))
)
SELECT * FROM checks ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'BLOCKER' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
