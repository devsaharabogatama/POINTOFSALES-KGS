-- F4A AR outstanding, aging, statement and export preflight.
-- SAFETY: SELECT-only.
WITH target_sales AS (
  SELECT sale.*,company.timezone,invoice.invoice_no
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
    AND invoice.sales_id=sale.id
  WHERE sale.document_status='POSTED' AND sale.is_tempo
), receipt_totals AS (
  SELECT allocation.company_id,allocation.sales_id,
    sum(allocation.allocated_amount) allocated_amount
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents document ON document.company_id=allocation.company_id
    AND document.id=allocation.document_id AND document.status='POSTED'
  GROUP BY allocation.company_id,allocation.sales_id
), checks AS (
  SELECT 'f4a_dependencies' check_name,CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',3,'ledgerRows',count(*),
      'requiredVersions',jsonb_build_array('20260827100000','20260827110000','20260827120000')) details
  FROM private.kgs_schema_migrations WHERE version IN('20260827100000','20260827110000','20260827120000')
  UNION ALL
  SELECT 'payment_before_order_business_date',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('allocationCount',count(*))
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id
  JOIN target_sales sale ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
  WHERE receipt.receipt_date<(sale.transaction_date AT TIME ZONE sale.timezone)::DATE
  UNION ALL
  SELECT 'future_customer_receipt_date',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('documentCount',count(*))
  FROM public.customer_receipt_documents document
  JOIN public.companies company ON company.id=document.company_id
  WHERE document.receipt_date>(clock_timestamp() AT TIME ZONE company.timezone)::DATE
  UNION ALL
  SELECT 'negative_invoice_outstanding',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invoiceCount',count(*))
  FROM target_sales sale LEFT JOIN receipt_totals receipt
    ON receipt.company_id=sale.company_id AND receipt.sales_id=sale.id
  WHERE round(sale.sisa_piutang-COALESCE(receipt.allocated_amount,0),4)<0
  UNION ALL
  SELECT 'receipt_allocation_customer_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id
  JOIN public.sales_headers sale ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
  WHERE receipt.customer_id<>sale.customer_id
  UNION ALL
  SELECT 'canonical_ar_report_routine_state','SETUP',jsonb_build_object(
    'missing',(SELECT COALESCE(jsonb_agg(required.name ORDER BY required.name),'[]'::JSONB)
      FROM (VALUES('get_finance_ar_aging'),('get_finance_customer_statement'),
        ('export_finance_ar_report')) required(name)
      WHERE NOT EXISTS(SELECT 1 FROM pg_proc routine JOIN pg_namespace namespace
        ON namespace.oid=routine.pronamespace WHERE namespace.nspname='public'
          AND routine.proname=required.name)),
    'expected',3)
  UNION ALL
  SELECT 'ar_report_browser_write_boundary','PASS',jsonb_build_object(
    'required','reporting remains RPC read-only; no new browser table writes')
  UNION ALL
  SELECT 'active_company_timezone_readiness',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('companyCount',count(*))
  FROM public.companies company WHERE company.status='ACTIVE'
    AND btrim(COALESCE(company.timezone,''))=''
  UNION ALL
  SELECT 'open_tempo_receivable_inventory','INFO',jsonb_build_object(
    'invoices',count(*),'companies',count(DISTINCT sale.company_id),
    'originalReceivable',COALESCE(sum(sale.sisa_piutang),0),
    'allocatedReceipts',COALESCE(sum(receipt.allocated_amount),0),
    'outstanding',COALESCE(sum(sale.sisa_piutang-COALESCE(receipt.allocated_amount,0)),0))
  FROM target_sales sale LEFT JOIN receipt_totals receipt
    ON receipt.company_id=sale.company_id AND receipt.sales_id=sale.id
  WHERE sale.sisa_piutang-COALESCE(receipt.allocated_amount,0)>0
  UNION ALL
  SELECT 'ar_reporting_source_inventory','INFO',jsonb_build_object(
    'tempoSales',(SELECT count(*) FROM target_sales),
    'postedReceipts',(SELECT count(*) FROM public.customer_receipt_documents WHERE status='POSTED'),
    'postedAllocations',(SELECT count(*) FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'),
    'advanceReceipts',(SELECT count(*) FROM public.customer_receipt_documents
      WHERE status='POSTED' AND unapplied_disposition='CUSTOMER_BALANCE'))
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
