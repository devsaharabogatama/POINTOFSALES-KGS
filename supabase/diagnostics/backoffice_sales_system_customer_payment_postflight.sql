-- SELECT-only verification for 20260912139000.
WITH function_contract AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)')) definition
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912139000'

  UNION ALL
  SELECT 'system_customer_allocated_only_contract',
    CASE WHEN definition LIKE '%BACKOFFICE_SYSTEM_CUSTOMER_ALLOCATED_ONLY%'
      AND definition LIKE '%<>''BACKOFFICE_SALES_INVOICE''%'
      AND definition NOT LIKE '%customer.is_active AND NOT customer.is_system_customer FOR SHARE;%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition LIKE '%BACKOFFICE_SYSTEM_CUSTOMER_ALLOCATED_ONLY%'
      AND definition LIKE '%<>''BACKOFFICE_SALES_INVOICE''%'
      AND definition NOT LIKE '%customer.is_active AND NOT customer.is_system_customer FOR SHARE;%'
      THEN 0 ELSE 1 END,
    jsonb_build_object('markerPresent',definition LIKE '%BACKOFFICE_SYSTEM_CUSTOMER_ALLOCATED_ONLY%',
      'backofficeOnlyGuardPresent',definition LIKE '%<>''BACKOFFICE_SALES_INVOICE''%')
  FROM function_contract

  UNION ALL
  SELECT 'system_customer_receipt_history_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.customer_receipt_documents receipt
  JOIN public.customers customer ON customer.company_id=receipt.company_id
    AND customer.id=receipt.customer_id AND customer.is_system_customer
  WHERE receipt.unapplied_disposition<>'NONE'
    OR EXISTS(SELECT 1 FROM public.customer_receipt_allocations allocation
      WHERE allocation.company_id=receipt.company_id AND allocation.document_id=receipt.id)

  UNION ALL
  SELECT 'system_customer_balance_invariant',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.customers customer
  WHERE customer.is_system_customer AND customer.current_balance<>0

  UNION ALL
  SELECT 'system_customer_payment_rpc_boundary',
    CASE WHEN bool_and(NOT has_function_privilege('anon',signature,'EXECUTE'))
      AND bool_and(has_function_privilege('authenticated',signature,'EXECUTE'))
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_function_privilege('anon',signature,'EXECUTE')
      OR NOT has_function_privilege('authenticated',signature,'EXECUTE')),
    jsonb_build_object('routineRows',count(*))
  FROM (VALUES
    ('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'::text),
    ('public.register_backoffice_sales_invoice_payment(uuid,uuid,date,uuid,numeric,text,text,text)'::text)
  ) required(signature)

  UNION ALL
  SELECT 'system_customer_payment_runtime_inventory','INFO',0,
    jsonb_build_object('postedSystemCustomerReceipts',count(*))
  FROM public.customer_receipt_documents receipt
  JOIN public.customers customer ON customer.company_id=receipt.company_id
    AND customer.id=receipt.customer_id AND customer.is_system_customer
  WHERE receipt.status='POSTED'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'FAIL' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,
  check_name;
