-- ODR-6B.2 Inventory Dispatch/Received UI smoke postflight.
-- SAFETY: SELECT-only.
WITH movement_totals AS (
  SELECT movement.company_id,movement.warehouse_id,movement.product_id,
    sum(movement.qty_change) movement_qty
  FROM public.stock_movements movement WHERE movement.movement_status='POSTED'
  GROUP BY movement.company_id,movement.warehouse_id,movement.product_id
),checks AS (
  SELECT 'active_finance_posting_queue'::TEXT check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END status,count(*) violation_rows,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'open_finance_posting_exception',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('exceptionRows',count(*))
  FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'

  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('reservationCount',count(*))
  FROM public.sales_stock_reservations reservation
  LEFT JOIN LATERAL (SELECT sum(line.reserved_base_qty) reserved,
      sum(line.released_base_qty) released,
      sum(line.dispatched_base_qty) dispatched
    FROM public.sales_stock_reservation_lines line
    WHERE line.company_id=reservation.company_id
      AND line.reservation_id=reservation.id) totals ON TRUE
  WHERE round(reservation.total_reserved_base_qty,6)<>
      round(COALESCE(totals.reserved,0),6)
    OR round(reservation.total_released_base_qty,6)<>
      round(COALESCE(totals.released,0),6)
    OR round(reservation.total_dispatched_base_qty,6)<>
      round(COALESCE(totals.dispatched,0),6)

  UNION ALL
  SELECT 'dispatch_allocation_reservation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('lineCount',count(*))
  FROM public.sales_stock_reservation_lines line
  LEFT JOIN LATERAL (SELECT sum(allocation.dispatched_base_qty) dispatched
    FROM public.sales_dispatch_allocations allocation
    WHERE allocation.company_id=line.company_id
      AND allocation.reservation_line_id=line.id) totals ON TRUE
  WHERE round(line.dispatched_base_qty,6)<>
    round(COALESCE(totals.dispatched,0),6)

  UNION ALL
  SELECT 'dispatch_allocation_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('movementCount',count(*))
  FROM (SELECT allocation.company_id,allocation.stock_movement_id,
      sum(allocation.dispatched_base_qty) dispatched
    FROM public.sales_dispatch_allocations allocation
    GROUP BY allocation.company_id,allocation.stock_movement_id) allocation
  LEFT JOIN public.stock_movements movement
    ON movement.company_id=allocation.company_id
   AND movement.id=allocation.stock_movement_id
  WHERE movement.id IS NULL OR round(abs(movement.qty_change),6)<>
    round(allocation.dispatched,6)

  UNION ALL
  SELECT 'linked_delivery_dispatch_quantity_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('documentCount',count(*))
  FROM public.sales_delivery_documents delivery
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=delivery.company_id
   AND reservation.id=delivery.reservation_id
  WHERE round(delivery.total_dispatched_base_qty,6)<>
      round(reservation.total_dispatched_base_qty,6)
    OR (delivery.status='READY' AND delivery.total_dispatched_base_qty<>0)
    OR (delivery.status='PARTIALLY_DISPATCHED' AND
      (delivery.total_dispatched_base_qty<=0
       OR reservation.status<>'PARTIALLY_DISPATCHED'))
    OR (delivery.status IN('DISPATCHED','DELIVERED')
      AND reservation.status<>'CONSUMED')

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock FULL JOIN movement_totals movement
    ON movement.company_id=stock.company_id
   AND movement.warehouse_id=stock.warehouse_id
   AND movement.product_id=stock.product_id
  WHERE round(COALESCE(stock.stock_qty,0),6)<>
    round(COALESCE(movement.movement_qty,0),6)

  UNION ALL
  SELECT 'positive_stock_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pairCount',count(*))
  FROM public.product_stocks stock
  LEFT JOIN LATERAL (SELECT COALESCE(sum(batch.qty_remaining),0) fifo_qty
    FROM public.product_batches batch WHERE batch.company_id=stock.company_id
      AND batch.warehouse_id=stock.warehouse_id
      AND batch.product_id=stock.product_id AND batch.qty_remaining>0) fifo ON TRUE
  WHERE stock.stock_qty>0 AND round(stock.stock_qty,6)<>
    round(fifo.fifo_qty,6)

  UNION ALL
  SELECT 'dispatch_operation_source_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('operationCount',count(*))
  FROM (SELECT allocation.company_id,allocation.delivery_document_id,
      allocation.dispatch_idempotency_key
    FROM public.sales_dispatch_allocations allocation
    GROUP BY allocation.company_id,allocation.delivery_document_id,
      allocation.dispatch_idempotency_key) operation
  LEFT JOIN public.sales_dispatch_financial_effects effect
    ON effect.company_id=operation.company_id
   AND effect.delivery_document_id=operation.delivery_document_id
   AND effect.dispatch_idempotency_key=operation.dispatch_idempotency_key
  WHERE effect.id IS NULL

  UNION ALL
  SELECT 'dispatch_event_source_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('effectCount',count(*))
  FROM public.sales_dispatch_financial_effects effect
  LEFT JOIN public.financial_events event
    ON event.company_id=effect.company_id AND event.id=effect.financial_event_id
  WHERE event.id IS NULL OR event.system_event_key<>'SALE_DISPATCHED'
    OR event.source_table<>'sales_dispatch_financial_effects'
    OR event.source_id<>effect.id OR event.status::TEXT NOT IN('HOLD','POSTED')

  UNION ALL
  SELECT 'dispatch_event_journal_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.financial_events event
  LEFT JOIN public.finance_journals journal
    ON journal.company_id=event.company_id
   AND journal.financial_event_id=event.id AND journal.status='POSTED'
  WHERE event.system_event_key='SALE_DISPATCHED'
    AND ((event.status::TEXT='POSTED' AND journal.id IS NULL)
      OR (event.status::TEXT='HOLD' AND journal.id IS NOT NULL))

  UNION ALL
  SELECT 'received_audit_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('documentCount',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE delivery.reservation_id IS NOT NULL AND delivery.status='DELIVERED'
    AND NOT EXISTS(SELECT 1 FROM public.sales_document_audit audit
      WHERE audit.company_id=delivery.company_id
        AND audit.document_id=delivery.id AND audit.action='DELIVER')

  UNION ALL
  SELECT 'duplicate_dispatch_operation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,delivery_document_id,dispatch_idempotency_key,
      count(DISTINCT financial_event_id) event_count
    FROM public.sales_dispatch_financial_effects
    GROUP BY company_id,delivery_document_id,dispatch_idempotency_key
    HAVING count(*)>1 OR count(DISTINCT financial_event_id)>1) duplicate
),inventory AS (
  SELECT 'inventory_dispatch_smoke_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'linkedReady',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='READY'),
      'linkedPartial',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='PARTIALLY_DISPATCHED'),
      'linkedDispatched',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='DISPATCHED'),
      'linkedDelivered',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL AND status='DELIVERED'),
      'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
      'dispatchEffects',(SELECT count(*) FROM public.sales_dispatch_financial_effects),
      'holdEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_DISPATCHED' AND status::TEXT='HOLD'),
      'postedEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key='SALE_DISPATCHED' AND status::TEXT='POSTED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
