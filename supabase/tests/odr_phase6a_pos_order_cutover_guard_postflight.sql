-- ODR-6A cancellation guard postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828270000'
  UNION ALL
  SELECT 'guarded_order_cancel_definition',
    CASE WHEN definition~'SALES_ORDER_PAYMENT_RESOLUTION_REQUIRED'
      AND definition~'odr6a_cancel_pos_sales_order_legacy'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'SALES_ORDER_PAYMENT_RESOLUTION_REQUIRED'
      AND definition~'odr6a_cancel_pos_sales_order_legacy' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'public.cancel_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure
  ) definition) runtime
  UNION ALL
  SELECT 'private_order_cancel_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private'
    AND privilege.routine_name='odr6a_cancel_pos_sales_order_legacy'
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
    AND privilege.privilege_type='EXECUTE'
  UNION ALL
  SELECT 'canceled_order_unresolved_payment',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('requestRows',count(*))
  FROM public.sales_payment_verification_requests request
  JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  WHERE sale.order_runtime_status='CANCELED'
    AND request.status IN('PENDING','VERIFIED')
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
),inventory AS (
  SELECT 'order_cancel_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'openOrders',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
      'pendingPaymentRequests',(SELECT count(*)
        FROM public.sales_payment_verification_requests WHERE status='PENDING'),
      'verifiedPaymentRequests',(SELECT count(*)
        FROM public.sales_payment_verification_requests WHERE status='VERIFIED'),
      'rejectedPaymentRequests',(SELECT count(*)
        FROM public.sales_payment_verification_requests WHERE status='REJECTED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
