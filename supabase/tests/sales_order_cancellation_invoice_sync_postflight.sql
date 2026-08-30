-- Sales Order cancellation and Invoice projection postflight.
-- SAFETY: SELECT-only.

WITH routine_definitions AS (
  SELECT proname,pg_get_functiondef(oid) definition
  FROM pg_proc
  WHERE oid IN(
    to_regprocedure('public.cancel_pos_sales_order(uuid,bigint,uuid,text)'),
    to_regprocedure('public.cancel_sales_order_from_backoffice(uuid,bigint,uuid,text)'),
    to_regprocedure('public.get_sales_documents()'),
    to_regprocedure('public.get_sales_invoice_document(uuid)'),
    to_regprocedure('public.export_sales_documents()'))
),checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260830110000'
  UNION ALL
  SELECT 'required_cancellation_routines',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=5 THEN 0 ELSE 1 END,jsonb_build_object('expected',5,'routineRows',count(*))
  FROM routine_definitions
  UNION ALL
  SELECT 'canonical_cancel_composition',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 THEN 0 ELSE 1 END,jsonb_build_object('routineRows',count(*))
  FROM routine_definitions WHERE (proname='cancel_pos_sales_order'
      AND definition~'cancel_pending_sales_order_payments'
      AND definition~'odr6a_cancel_pos_sales_order_legacy')
    OR (proname='cancel_sales_order_from_backoffice'
      AND definition~'sales.sales_orders' AND definition~'CANCEL_FINAL')
  UNION ALL
  SELECT 'invoice_cancellation_projection',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3 THEN 0 ELSE 1 END,jsonb_build_object('routineRows',count(*))
  FROM routine_definitions WHERE proname IN('get_sales_documents',
    'get_sales_invoice_document','export_sales_documents')
    AND definition~'invoiceStatus' AND definition~'cancelReason'
  UNION ALL
  SELECT 'canceled_order_reservation_release',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  WHERE sale.order_runtime_status='CANCELED'
    AND (reservation.status<>'RELEASED'
      OR reservation.total_dispatched_base_qty<>0)
  UNION ALL
  SELECT 'canceled_linked_delivery_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_headers sale
  JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
  WHERE sale.order_runtime_status='CANCELED' AND delivery.status<>'CANCELED'
  UNION ALL
  SELECT 'canceled_order_payment_resolution',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('unresolvedRows',count(*))
  FROM public.sales_payment_verification_requests request
  JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  WHERE sale.order_runtime_status='CANCELED'
    AND request.status IN('PENDING','VERIFIED')
  UNION ALL
  SELECT 'browser_cancellation_rpc_boundary',
    CASE WHEN has_function_privilege('anon',
      'public.cancel_sales_order_from_backoffice(uuid,bigint,uuid,text)','EXECUTE')
      OR NOT has_function_privilege('authenticated',
      'public.cancel_sales_order_from_backoffice(uuid,bigint,uuid,text)','EXECUTE')
      THEN 'FAIL' ELSE 'PASS' END,
    CASE WHEN has_function_privilege('anon',
      'public.cancel_sales_order_from_backoffice(uuid,bigint,uuid,text)','EXECUTE')
      OR NOT has_function_privilege('authenticated',
      'public.cancel_sales_order_from_backoffice(uuid,bigint,uuid,text)','EXECUTE')
      THEN 1 ELSE 0 END,
    jsonb_build_object('anonExecute',has_function_privilege('anon',
      'public.cancel_sales_order_from_backoffice(uuid,bigint,uuid,text)','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
      'public.cancel_sales_order_from_backoffice(uuid,bigint,uuid,text)','EXECUTE'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
