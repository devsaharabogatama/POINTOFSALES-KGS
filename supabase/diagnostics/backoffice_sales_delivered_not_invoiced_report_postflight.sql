-- SELECT-only postflight for Step 5/6.3 Delivered Not Invoiced report.
WITH definitions AS (
  SELECT namespace.nspname schema_name,routine.proname,
    pg_get_functiondef(routine.oid) definition,routine.prosecdef,routine.provolatile,
    routine.proconfig
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE (namespace.nspname='private' AND routine.proname='classify_backoffice_sales_dni')
     OR (namespace.nspname='public' AND routine.proname='get_finance_delivered_not_invoiced')
), checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912138000'
  UNION ALL
  SELECT 'dni_required_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*)),jsonb_build_object('routineRows',count(*),'expected',2) FROM definitions
  UNION ALL
  SELECT 'dni_security_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('validRows',count(*)) FROM definitions
  WHERE schema_name='public' AND prosecdef AND provolatile='s'
    AND proconfig @> ARRAY['search_path=public, pg_temp','statement_timeout=15s']
  UNION ALL
  SELECT 'dni_rpc_boundary',CASE WHEN anon_rows=0 AND authenticated_rows=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN anon_rows=0 AND authenticated_rows=1 THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',anon_rows,'authenticatedExecute',authenticated_rows)
  FROM (SELECT
    count(*) FILTER(WHERE grantee='anon') anon_rows,
    count(*) FILTER(WHERE grantee='authenticated') authenticated_rows
    FROM information_schema.routine_privileges
    WHERE specific_schema='public' AND routine_name='get_finance_delivered_not_invoiced'
      AND privilege_type='EXECUTE') boundary
  UNION ALL
  SELECT 'dni_definition_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('validRows',count(*)) FROM definitions
  WHERE schema_name='public' AND definition~'invoice\.status\s*=\s*''POSTED'''
    AND definition~'invoice\.status\s*=\s*''DRAFT'''
    AND position('OVERAGE_ACCEPTED_SALE' in definition)>0
    AND position('DELIVERY_FEE' in definition)>0
    AND position('delivery_fee_amount' in definition)>0
    AND position('measureKind' in definition)>0
    AND position('private.classify_backoffice_sales_dni' in definition)>0
    AND position('financialStatementIncluded' in definition)>0
    AND position('finance.journals_reports' in definition)>0
  UNION ALL
  SELECT 'dni_regular_source_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.accepted_base_qty<line.invoiced_base_qty+line.draft_invoice_allocated_base_qty
    +line.returned_before_invoice_base_qty
  UNION ALL
  SELECT 'dni_overage_source_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.accepted_overage_base_qty
    <line.invoiced_overage_base_qty+line.draft_overage_invoice_allocated_base_qty
  UNION ALL
  SELECT 'dni_runtime_inventory','INFO',0,jsonb_build_object(
    'receiptLines',(SELECT count(*) FROM public.backoffice_sales_delivery_receipt_lines),
    'acceptedOverageLines',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancy_lines WHERE accepted_overage_base_qty>0),
    'ordersWithDeliveryFee',(SELECT count(*) FROM public.backoffice_sales_orders WHERE delivery_fee_amount>0),
    'draftInvoiceAllocations',(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations WHERE status='HELD'),
    'postedInvoiceAllocations',(SELECT count(*) FROM public.backoffice_sales_invoice_quantity_allocations WHERE status='POSTED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
