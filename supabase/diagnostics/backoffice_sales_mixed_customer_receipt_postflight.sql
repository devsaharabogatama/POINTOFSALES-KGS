-- SELECT-only postflight for Step 4/6.3.
WITH invoice_definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)')) body
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911166000'
  UNION ALL
  SELECT 'mixed_receipt_required_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*)),jsonb_build_object('routineRows',count(*),'expected',2)
  FROM pg_proc proc WHERE proc.oid IN(
    to_regprocedure('private.receive_backoffice_sales_delivery_disposition_core(uuid,bigint,uuid,date,jsonb,text)'),
    to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)'))
  UNION ALL
  SELECT 'mixed_receipt_security_contract',
    CASE WHEN count(*)=1 AND bool_and(proc.prosecdef)
      AND bool_and('search_path=public, pg_temp'=ANY(proc.proconfig))
      AND bool_and('statement_timeout=30s'=ANY(proc.proconfig))
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(proc.prosecdef)
      AND bool_and('search_path=public, pg_temp'=ANY(proc.proconfig))
      AND bool_and('statement_timeout=30s'=ANY(proc.proconfig))
      THEN 0 ELSE 1 END,
    jsonb_build_object('privateCoreRows',count(*),'securityDefiner',bool_and(proc.prosecdef),
      'config',max(proc.proconfig::text))
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private'
    AND proc.oid=to_regprocedure(
      'private.receive_backoffice_sales_delivery_disposition_core(uuid,bigint,uuid,date,jsonb,text)')
  UNION ALL
  SELECT 'mixed_receipt_private_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('browserExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE routine_schema='private' AND grantee IN('PUBLIC','anon','authenticated')
    AND routine_name='receive_backoffice_sales_delivery_disposition_core'
  UNION ALL
  SELECT 'mixed_receipt_rpc_boundary',
    CASE WHEN has_function_privilege('authenticated',
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      AND NOT has_function_privilege('anon',
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('authenticatedExecute',has_function_privilege('authenticated',
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)','EXECUTE'),
      'anonExecute',has_function_privilege('anon',
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)','EXECUTE'))
  UNION ALL
  SELECT 'mixed_receipt_invoice_gate',
    CASE WHEN body LIKE '%fulfillment_status=''IN_TRANSIT''%'
      AND body LIKE '%to_invoice_base_qty>0%'
      AND body LIKE '%invoiceType%REGULAR%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%fulfillment_status=''IN_TRANSIT''%'
      AND body LIKE '%to_invoice_base_qty>0%'
      AND body LIKE '%invoiceType%REGULAR%' THEN 0 ELSE 1 END,
    jsonb_build_object('inTransitRegularGate',body LIKE '%fulfillment_status=''IN_TRANSIT''%',
      'positiveQtyGate',body LIKE '%to_invoice_base_qty>0%')
  FROM invoice_definition
  UNION ALL
  SELECT 'mixed_receipt_header_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_receipts receipt
  WHERE receipt.total_received_base_qty<0 OR receipt.total_fifo_cost<0
    OR (receipt.total_received_base_qty=0
      AND (receipt.total_fifo_cost<>0 OR receipt.financial_event_id IS NOT NULL))
    OR (receipt.total_received_base_qty>0 AND receipt.financial_event_id IS NULL)
  UNION ALL
  SELECT 'mixed_receipt_discrepancy_lineage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancies discrepancy
  LEFT JOIN public.backoffice_sales_delivery_receipts receipt
    ON receipt.company_id=discrepancy.company_id AND receipt.id=discrepancy.receipt_id
  WHERE receipt.id IS NULL OR receipt.delivery_order_id<>discrepancy.delivery_order_id
    OR receipt.sales_order_id<>discrepancy.sales_order_id
  UNION ALL
  SELECT 'mixed_receipt_quantity_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_receipts receipt
  WHERE receipt.total_received_base_qty<>COALESCE((SELECT sum(line.received_base_qty)
    FROM public.backoffice_sales_delivery_receipt_lines line
    WHERE line.company_id=receipt.company_id AND line.receipt_id=receipt.id),0)
  UNION ALL
  SELECT 'mixed_receipt_clean_wrapper_compatibility',
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NULL
      THEN 1 ELSE 0 END,
    jsonb_build_object('legacyWrapperPreserved',true)
  UNION ALL
  SELECT 'mixed_receipt_runtime_inventory','INFO',0,
    jsonb_build_object('receipts',count(DISTINCT receipt.id),
      'mixedReceipts',count(DISTINCT discrepancy.receipt_id),
      'openDiscrepancies',count(DISTINCT discrepancy.id) FILTER(
        WHERE discrepancy.status NOT IN('RESOLVED','CANCELED')))
  FROM public.backoffice_sales_delivery_receipts receipt
  LEFT JOIN public.backoffice_sales_delivery_discrepancies discrepancy
    ON discrepancy.company_id=receipt.company_id AND discrepancy.receipt_id=receipt.id
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;

