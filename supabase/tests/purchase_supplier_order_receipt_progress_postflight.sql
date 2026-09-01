-- Supplier Order receipt-progress read model postflight.
-- SAFETY: SELECT-only.
WITH routine AS (
  SELECT procedure.oid,procedure.prosecdef,procedure.provolatile,
    procedure.proconfig,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='get_purchase_supplier_orders'
    AND pg_get_function_identity_arguments(procedure.oid)=''
),checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260831110000'

  UNION ALL
  SELECT 'supplier_order_receipt_progress_definition',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM routine WHERE definition ~
      'receipt\.status[[:space:]]*=[[:space:]]*''POSTED'''
    AND definition ~ 'received_ordered_qty'
    AND definition ~ 'remaining_ordered_qty'
    AND definition ~ 'receipt_progress'
    AND definition ~ 'over_received_base_qty'
    AND definition ~ 'supplierOrderReceiptProgressVersion'

  UNION ALL
  SELECT 'supplier_order_read_security_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',COALESCE(bool_or(prosecdef),FALSE),
      'volatility',max(provolatile::TEXT),
      'config',COALESCE(jsonb_agg(proconfig),'[]'::JSONB))
  FROM routine
  HAVING bool_and(prosecdef) AND bool_and(provolatile='s')
    AND bool_and(proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[])

  UNION ALL
  SELECT 'supplier_order_read_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_purchase_supplier_orders()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_purchase_supplier_orders()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_purchase_supplier_orders()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_purchase_supplier_orders()','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object(
      'anonExecute',has_function_privilege('anon',
        'public.get_purchase_supplier_orders()','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
        'public.get_purchase_supplier_orders()','EXECUTE'))

  UNION ALL
  SELECT 'posted_receipt_order_line_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.goods_receipt_lines receipt_line
  JOIN public.goods_receipt_documents receipt
    ON receipt.company_id=receipt_line.company_id
   AND receipt.id=receipt_line.document_id
   AND receipt.status='POSTED'
  LEFT JOIN public.supplier_order_lines order_line
    ON order_line.company_id=receipt_line.company_id
   AND order_line.id=receipt_line.supplier_order_line_id
  LEFT JOIN public.supplier_order_documents purchase_order
    ON purchase_order.company_id=order_line.company_id
   AND purchase_order.id=order_line.document_id
  WHERE order_line.id IS NULL OR purchase_order.id IS NULL
    OR receipt.supplier_order_id<>purchase_order.id
    OR receipt_line.product_id<>order_line.product_id

  UNION ALL
  SELECT 'supplier_order_receipt_progress_inventory','INFO',0,
    jsonb_build_object(
      'orders',(SELECT count(*) FROM public.supplier_order_documents),
      'orderLines',(SELECT count(*) FROM public.supplier_order_lines),
      'postedReceipts',(SELECT count(*) FROM public.goods_receipt_documents
        WHERE status='POSTED'),
      'partiallyReceivedOrders',(SELECT count(*)
        FROM public.supplier_order_documents WHERE status='PARTIALLY_RECEIVED'),
      'receivedOrders',(SELECT count(*)
        FROM public.supplier_order_documents WHERE status='RECEIVED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
