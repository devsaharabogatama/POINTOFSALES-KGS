-- SELECT-only gate for the Backoffice system-customer Invoice payment fix.
-- Run only on isolated Development. This file performs no writes.
WITH function_contract AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)')) definition
), checks AS (
  SELECT 'system_customer_payment_dependency_ledger'::text check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    4-count(*) violation_rows,
    jsonb_build_object('present',count(*),'expected',4) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260911160000','20260911161000','20260911162000','20260912138000')

  UNION ALL
  SELECT 'system_customer_payment_function_contract',
    CASE WHEN definition LIKE '%AND customer.id=p_customer_id AND customer.is_active AND NOT customer.is_system_customer FOR SHARE;%'
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN definition LIKE '%AND customer.id=p_customer_id AND customer.is_active AND NOT customer.is_system_customer FOR SHARE;%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('legacyGuardPresent',definition LIKE '%AND customer.id=p_customer_id AND customer.is_active AND NOT customer.is_system_customer FOR SHARE;%',
      'alreadyPatched',definition LIKE '%BACKOFFICE_SYSTEM_CUSTOMER_ALLOCATED_ONLY%')
  FROM function_contract

  UNION ALL
  SELECT 'system_customer_payment_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'system_customer_payment_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')

  UNION ALL
  SELECT 'system_customer_payment_history_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidReceipts',count(*))
  FROM public.customer_receipt_documents receipt
  JOIN public.customers customer ON customer.company_id=receipt.company_id
    AND customer.id=receipt.customer_id AND customer.is_system_customer
  WHERE receipt.unapplied_disposition<>'NONE'
    OR EXISTS(SELECT 1 FROM public.customer_receipt_allocations allocation
      WHERE allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id)

  UNION ALL
  SELECT 'system_customer_payment_runtime_inventory','INFO',0,
    jsonb_build_object(
      'postedSystemCustomerInvoices',(SELECT count(*)
        FROM public.backoffice_sales_invoices invoice
        JOIN public.customers customer ON customer.company_id=invoice.company_id
          AND customer.id=invoice.customer_id
        WHERE invoice.status='POSTED' AND customer.is_active AND customer.is_system_customer),
      'unpaidSystemCustomerInvoices',(SELECT count(*) FROM (
        SELECT invoice.company_id,invoice.id,invoice.grand_total,
          COALESCE(sum(allocation.allocated_amount) FILTER(WHERE receipt.status='POSTED'),0) paid
        FROM public.backoffice_sales_invoices invoice
        JOIN public.customers customer ON customer.company_id=invoice.company_id
          AND customer.id=invoice.customer_id AND customer.is_active AND customer.is_system_customer
        LEFT JOIN public.customer_receipt_backoffice_invoice_allocations allocation
          ON allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id
        LEFT JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
        WHERE invoice.status='POSTED'
        GROUP BY invoice.company_id,invoice.id,invoice.grand_total
        HAVING invoice.grand_total>COALESCE(sum(allocation.allocated_amount)
          FILTER(WHERE receipt.status='POSTED'),0)
      ) open_invoice))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,
  check_name;
