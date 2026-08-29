-- ODR-3C atomic Delivery Dispatch postflight. SELECT-only.
WITH movement_totals AS (
  SELECT movement.company_id,movement.warehouse_id,movement.product_id,
    sum(movement.qty_change) movement_qty
  FROM public.stock_movements movement WHERE movement.movement_status='POSTED'
  GROUP BY movement.company_id,movement.warehouse_id,movement.product_id
),checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828140000'
  UNION ALL
  SELECT 'required_dispatch_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname IN(
    'dispatch_sales_delivery','confirm_sales_delivery_received',
    'get_inventory_delivery_dispatch_workspace')
  UNION ALL
  SELECT 'private_dispatch_core_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges
  WHERE grantee='authenticated' AND specific_schema='private'
    AND routine_name='dispatch_sales_delivery_core' AND privilege_type='EXECUTE'
  UNION ALL
  SELECT 'canonical_dispatch_definition',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='dispatch_sales_delivery_core'
    AND pg_get_functiondef(routine.oid) LIKE '%UPDATE public.product_batches%'
    AND pg_get_functiondef(routine.oid) LIKE '%INSERT INTO public.product_stocks%'
    AND pg_get_functiondef(routine.oid) LIKE '%INSERT INTO public.stock_movements%'
    AND pg_get_functiondef(routine.oid) LIKE '%sales_stock_reservation_lines%'
    AND pg_get_functiondef(routine.oid) NOT LIKE '%INSERT INTO public.financial_events%'
  UNION ALL
  SELECT 'legacy_dispatch_and_deliver_bypass_quarantined',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private'
    AND routine.proname='acp5e_update_sales_delivery_status_core'
    AND pg_get_functiondef(routine.oid) LIKE '%IN(''DISPATCH'',''DELIVER'')%'
    AND pg_get_functiondef(routine.oid) LIKE '%USE_CANONICAL_DISPATCH_RUNTIME%'
  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('reservationCount',count(*))
  FROM public.sales_stock_reservations reservation
  LEFT JOIN LATERAL (SELECT sum(line.dispatched_base_qty) dispatched,
      sum(line.released_base_qty) released FROM public.sales_stock_reservation_lines line
    WHERE line.company_id=reservation.company_id
      AND line.reservation_id=reservation.id) totals ON TRUE
  WHERE reservation.total_reserved_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.reserved_base_qty) FROM public.sales_stock_reservation_lines line
      WHERE line.company_id=reservation.company_id
        AND line.reservation_id=reservation.id),0)
    OR reservation.total_dispatched_base_qty IS DISTINCT FROM COALESCE(totals.dispatched,0)
    OR reservation.total_released_base_qty IS DISTINCT FROM COALESCE(totals.released,0)
  UNION ALL
  SELECT 'dispatch_allocation_reservation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.sales_stock_reservation_lines reservation_line
  LEFT JOIN LATERAL (SELECT sum(allocation.dispatched_base_qty) dispatched
    FROM public.sales_dispatch_allocations allocation
    WHERE allocation.company_id=reservation_line.company_id
      AND allocation.reservation_line_id=reservation_line.id) totals ON TRUE
  WHERE reservation_line.dispatched_base_qty IS DISTINCT FROM COALESCE(totals.dispatched,0)
  UNION ALL
  SELECT 'dispatch_allocation_movement_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_dispatch_allocations allocation
  WHERE allocation.stock_movement_id IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.stock_movements movement
    WHERE movement.company_id=allocation.company_id
      AND movement.id=allocation.stock_movement_id
      AND movement.reference_table='sales_headers'
      AND movement.movement_type='SALE'::public.stock_movement_type)
  UNION ALL
  SELECT 'dispatch_movement_amount_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('movementCount',count(*))
  FROM public.stock_movements movement
  JOIN (SELECT allocation.company_id,allocation.stock_movement_id,
      sum(allocation.dispatched_base_qty) quantity
    FROM public.sales_dispatch_allocations allocation
    GROUP BY allocation.company_id,allocation.stock_movement_id) allocation
    ON allocation.company_id=movement.company_id
   AND allocation.stock_movement_id=movement.id
  WHERE movement.qty_change IS DISTINCT FROM -allocation.quantity
  UNION ALL
  SELECT 'linked_delivery_dispatch_quantity_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('documentCount',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=delivery.company_id AND reservation.id=delivery.reservation_id
  WHERE delivery.total_dispatched_base_qty IS DISTINCT FROM
    reservation.total_dispatched_base_qty
    OR (delivery.status='READY' AND delivery.total_dispatched_base_qty<>0)
    OR (delivery.status='PARTIALLY_DISPATCHED' AND
      (delivery.total_dispatched_base_qty<=0
       OR reservation.status<>'PARTIALLY_DISPATCHED'))
    OR (delivery.status IN('DISPATCHED','DELIVERED')
      AND reservation.status<>'CONSUMED')
  UNION ALL
  SELECT 'linked_dispatch_zero_finance_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('eventCount',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
    AND sale.id=delivery.sales_id
  JOIN public.financial_events event ON event.company_id=sale.company_id
    AND event.source_id=sale.id
  WHERE delivery.reservation_id IS NOT NULL
    AND sale.document_status='DRAFT'
  UNION ALL
  SELECT 'historical_delivery_dispatch_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('allocationRows',count(*))
  FROM public.sales_dispatch_allocations allocation
  JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=allocation.company_id
   AND delivery.id=allocation.delivery_document_id
  WHERE delivery.reservation_id IS NULL
  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock FULL JOIN movement_totals movement
    ON movement.company_id=stock.company_id
   AND movement.warehouse_id=stock.warehouse_id
   AND movement.product_id=stock.product_id
  WHERE COALESCE(stock.stock_qty,0) IS DISTINCT FROM COALESCE(movement.movement_qty,0)
  UNION ALL
  SELECT 'positive_stock_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock
  LEFT JOIN LATERAL (SELECT COALESCE(sum(batch.qty_remaining),0) fifo_qty
    FROM public.product_batches batch WHERE batch.company_id=stock.company_id
      AND batch.warehouse_id=stock.warehouse_id AND batch.product_id=stock.product_id
      AND batch.qty_remaining>0) fifo ON TRUE
  WHERE stock.stock_qty>0 AND stock.stock_qty IS DISTINCT FROM fifo.fifo_qty
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'dispatch_runtime_inventory','INFO',jsonb_build_object(
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'partialReservations',(SELECT count(*) FROM public.sales_stock_reservations
      WHERE status='PARTIALLY_DISPATCHED'),
    'consumedReservations',(SELECT count(*) FROM public.sales_stock_reservations
      WHERE status='CONSUMED'),
    'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
    'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
      WHERE reservation_id IS NOT NULL))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
