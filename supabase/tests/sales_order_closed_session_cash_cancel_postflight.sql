-- Sales Order closed-session Cash cancellation postflight.
-- SAFETY: SELECT-only.
WITH definitions AS (
  SELECT proname,pg_get_functiondef(oid) definition
  FROM pg_proc
  WHERE oid IN(
    'private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)'::regprocedure,
    'public.get_sales_documents()'::regprocedure,
    'public.get_sales_invoice_document(uuid)'::regprocedure)
),checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260830120000'
  UNION ALL
  SELECT 'closed_session_cash_cancel_runtime',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM definitions WHERE proname='cancel_pending_sales_order_payments'
    AND definition~'SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION'
    AND definition~'session.cashier_id=p_actor_id'
    AND definition~'v_refund_session.id'
  UNION ALL
  SELECT 'backoffice_cancel_session_visibility',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 THEN 0 ELSE 2-count(*) END,
    jsonb_build_object('expected',2,'routineRows',count(*))
  FROM definitions WHERE proname IN('get_sales_documents','get_sales_invoice_document')
    AND definition~'session.cashier_id=v_actor'
  UNION ALL
  SELECT 'closed_cashier_session_immutable',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('unexpectedDefinitionRows',count(*))
  FROM definitions WHERE proname='cancel_pending_sales_order_payments'
    AND definition~'UPDATE public.cashier_sessions'
  UNION ALL
  SELECT 'duplicate_cash_reversal_source',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,source_table,source_id
    FROM public.cash_drawer_movements
    WHERE source_table='sales_payment_verification_reversal'
    GROUP BY company_id,source_table,source_id HAVING count(*)>1) duplicate
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
  SELECT 'cash_cancel_runtime_inventory','INFO',0,
    jsonb_build_object('pendingCash',count(*),
      'closedSourceSession',count(*) FILTER(WHERE session.status='CLOSED'),
      'openSourceSession',count(*) FILTER(WHERE session.status='OPEN'))
  FROM public.sales_payment_verification_requests request
  JOIN public.cashier_sessions session ON session.company_id=request.company_id
    AND session.id=request.cashier_session_id
  WHERE request.status='PENDING'
    AND request.settlement_route_snapshot='CASH_DRAWER'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
