-- Read-only postflight for 20260909154000.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,count(*)<>1 violation,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909154000'
  UNION ALL
  SELECT 'required_receipt_runtime_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>2,jsonb_build_object('routineRows',count(*),'expected',2)
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname||'.'||proc.proname IN(
    'private.receive_backoffice_sales_delivery_core',
    'public.receive_backoffice_sales_delivery')
  UNION ALL
  SELECT 'receipt_rpc_boundary',CASE WHEN bool_and(NOT anon_exec) AND bool_and(auth_exec)
      THEN 'PASS' ELSE 'FAIL' END,
    NOT(COALESCE(bool_and(NOT anon_exec),false) AND COALESCE(bool_and(auth_exec),false)),
    jsonb_build_object('anonExecute',bool_or(anon_exec),'authenticatedExecute',bool_or(auth_exec))
  FROM (SELECT has_function_privilege('anon',proc.oid,'EXECUTE') anon_exec,
      has_function_privilege('authenticated',proc.oid,'EXECUTE') auth_exec
    FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
    WHERE ns.nspname='public' AND proc.proname='receive_backoffice_sales_delivery') p
  UNION ALL
  SELECT 'receipt_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>0,jsonb_build_object('browserExecutableRows',count(*))
  FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
  WHERE ns.nspname='private' AND proc.proname='receive_backoffice_sales_delivery_core'
    AND (has_function_privilege('anon',proc.oid,'EXECUTE')
      OR has_function_privilege('authenticated',proc.oid,'EXECUTE'))
  UNION ALL
  SELECT 'receipt_stock_fifo_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>0,jsonb_build_object('invalidRows',count(*))
  FROM (SELECT receipt.id FROM public.backoffice_sales_delivery_receipts receipt
    LEFT JOIN public.backoffice_sales_delivery_receipt_lines line
      ON line.company_id=receipt.company_id AND line.receipt_id=receipt.id
    LEFT JOIN public.backoffice_sales_receipt_fifo_allocations allocation
      ON allocation.company_id=line.company_id AND allocation.receipt_line_id=line.id
    GROUP BY receipt.id,receipt.total_received_base_qty,receipt.total_fifo_cost
    HAVING COALESCE(sum(allocation.quantity_base),0)<>receipt.total_received_base_qty
      OR round(COALESCE(sum(allocation.total_cost),0),4)<>round(receipt.total_fifo_cost,4)) invalid
  UNION ALL
  SELECT 'receipt_quantity_to_invoice_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)<>0,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines line
  WHERE line.to_invoice_base_qty<0 OR line.net_delivered_base_qty<0
  UNION ALL
  SELECT 'receipt_runtime_inventory','INFO',false,jsonb_build_object(
    'receipts',(SELECT count(*) FROM public.backoffice_sales_delivery_receipts),
    'completedDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders WHERE status='COMPLETED'),
    'holdEvents',(SELECT count(*) FROM public.financial_events
      WHERE system_event_key='BACKOFFICE_CUSTOMER_RECEIPT' AND status='HOLD'))
)
SELECT check_name,status,CASE WHEN violation THEN 1 ELSE 0 END violation_rows,details
FROM checks ORDER BY check_name;
