-- ODR-2B atomic reservation runtime postflight. SAFETY: SELECT-only.
WITH routine AS (
  SELECT procedure.oid,namespace.nspname schema_name,procedure.proname,
    pg_get_function_identity_arguments(procedure.oid) arguments,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','confirm_pos_sales_order'),('public','cancel_pos_sales_order'),
    ('public','get_pos_sales_orders'),('private','confirm_pos_sales_order_core'),
    ('private','cancel_pos_sales_order_core'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828110000'
  UNION ALL
  SELECT 'required_sales_order_reservation_routines',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,abs(5-count(*)),
    jsonb_build_object('expected',5,'routineRows',count(*)) FROM routine
  UNION ALL
  SELECT 'browser_sales_order_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE schema_name='public' AND
        has_function_privilege('authenticated',oid,'EXECUTE'))=3
      AND count(*) FILTER(WHERE schema_name='public' AND
        has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE schema_name='public' AND
      has_function_privilege('anon',oid,'EXECUTE')),
    jsonb_build_object('authenticatedRows',count(*) FILTER(WHERE schema_name='public' AND
      has_function_privilege('authenticated',oid,'EXECUTE')),
      'anonRows',count(*) FILTER(WHERE schema_name='public' AND
      has_function_privilege('anon',oid,'EXECUTE')))
  FROM routine
  UNION ALL
  SELECT 'private_sales_order_core_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('authenticatedExecutableRows',count(*)) FROM routine
  WHERE schema_name='private' AND has_function_privilege('authenticated',oid,'EXECUTE')
  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('reservationCount',count(*))
  FROM public.sales_stock_reservations reservation
  WHERE reservation.total_reserved_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.reserved_base_qty) FROM public.sales_stock_reservation_lines line
      WHERE line.company_id=reservation.company_id AND line.reservation_id=reservation.id),0)
     OR reservation.total_released_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.released_base_qty) FROM public.sales_stock_reservation_lines line
      WHERE line.company_id=reservation.company_id AND line.reservation_id=reservation.id),0)
     OR reservation.total_dispatched_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.dispatched_base_qty) FROM public.sales_stock_reservation_lines line
      WHERE line.company_id=reservation.company_id AND line.reservation_id=reservation.id),0)
  UNION ALL
  SELECT 'active_reservation_order_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
  WHERE (reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
      AND sale.order_runtime_status NOT IN('CONFIRMED','RESERVED','PARTIALLY_DISPATCHED'))
     OR (reservation.status='RELEASED' AND sale.order_runtime_status<>'CANCELED')
  UNION ALL
  SELECT 'reserved_order_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*)) FROM public.sales_headers sale
  WHERE sale.order_runtime_status IN('CONFIRMED','RESERVED') AND (
    EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=sale.company_id AND movement.reference_id=sale.id)
    OR EXISTS(SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=sale.company_id AND payment.sales_id=sale.id)
    OR EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=sale.company_id AND event.source_id=sale.id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=sale.company_id AND invoice.sales_id=sale.id)
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id))
  UNION ALL
  SELECT 'reservation_audit_operation_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('duplicateGroups',count(*)) FROM (
      SELECT company_id,action,idempotency_key FROM public.sales_stock_reservation_audit
      GROUP BY company_id,action,idempotency_key HAVING count(*)>1) duplicate
  UNION ALL
  SELECT 'atomic_runtime_definition_contract',
    CASE WHEN count(*)=2 AND bool_and(definition LIKE '%pg_advisory_xact_lock%'
      OR proname='cancel_pos_sales_order_core')
      AND bool_and(definition NOT LIKE '%INSERT INTO public.stock_movements%'
        AND definition NOT LIKE '%UPDATE public.product_stocks%'
        AND definition NOT LIKE '%INSERT INTO public.financial_events%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 THEN 0 ELSE abs(2-count(*)) END,
    jsonb_build_object('coreRows',count(*)) FROM routine WHERE schema_name='private'
  UNION ALL
  SELECT 'reservation_runtime_inventory','INFO',0,jsonb_build_object(
    'reservations',count(*),'open',count(*) FILTER(WHERE status='OPEN'),
    'released',count(*) FILTER(WHERE status='RELEASED'),
    'reservedBaseQty',COALESCE(sum(total_reserved_base_qty),0),
    'releasedBaseQty',COALESCE(sum(total_released_base_qty),0))
  FROM public.sales_stock_reservations
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
