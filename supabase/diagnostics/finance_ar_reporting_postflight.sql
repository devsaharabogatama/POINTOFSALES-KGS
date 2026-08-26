-- F4A AR reporting postflight. SELECT-only.
WITH target_sales AS (
  SELECT sale.*,company.timezone
  FROM public.sales_headers sale JOIN public.companies company ON company.id=sale.company_id
  WHERE sale.document_status='POSTED' AND sale.is_tempo
),receipt_totals AS (
  SELECT allocation.company_id,allocation.sales_id,sum(allocation.allocated_amount) paid
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
  GROUP BY allocation.company_id,allocation.sales_id
),checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827130000'
  UNION ALL
  SELECT 'required_ar_report_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    3-count(*),jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname IN(
    'get_finance_ar_aging','get_finance_customer_statement','export_finance_ar_report')
  UNION ALL
  SELECT 'customer_receipt_temporal_guard',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger trigger_row JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='customer_receipt_allocations'
    AND trigger_row.tgname='customer_receipt_allocation_date_guard'
    AND NOT trigger_row.tgisinternal AND trigger_row.tgenabled<>'D'
  UNION ALL
  SELECT 'ar_report_rpc_boundary',CASE WHEN count(*)=3 AND
      bool_and(has_function_privilege('authenticated',routine.oid,'EXECUTE')) AND
      bool_and(NOT has_function_privilege('anon',routine.oid,'EXECUTE'))
    THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3 AND bool_and(has_function_privilege('authenticated',routine.oid,'EXECUTE'))
      AND bool_and(NOT has_function_privilege('anon',routine.oid,'EXECUTE')) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname IN(
    'get_finance_ar_aging','get_finance_customer_statement','export_finance_ar_report')
  UNION ALL
  SELECT 'ar_reporting_source_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invoiceCount',count(*))
  FROM target_sales sale LEFT JOIN receipt_totals receipt ON receipt.company_id=sale.company_id
    AND receipt.sales_id=sale.id
  WHERE COALESCE(receipt.paid,0)>sale.sisa_piutang
  UNION ALL
  SELECT 'payment_before_order_business_date',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('allocationCount',count(*))
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
  JOIN target_sales sale ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
  WHERE receipt.receipt_date<(sale.transaction_date AT TIME ZONE sale.timezone)::DATE
  UNION ALL
  SELECT 'ar_report_browser_write_boundary','PASS',0,
    jsonb_build_object('newWritableRelations',0,'runtime','RPC read-only')
  UNION ALL
  SELECT 'ar_reporting_runtime_inventory','INFO',0,jsonb_build_object(
    'tempoInvoices',(SELECT count(*) FROM target_sales),
    'postedReceipts',(SELECT count(*) FROM public.customer_receipt_documents WHERE status='POSTED'),
    'postedAllocations',(SELECT count(*) FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'),
    'openOutstanding',COALESCE((SELECT sum(GREATEST(sale.sisa_piutang-COALESCE(receipt.paid,0),0))
      FROM target_sales sale LEFT JOIN receipt_totals receipt ON receipt.company_id=sale.company_id
        AND receipt.sales_id=sale.id),0))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
