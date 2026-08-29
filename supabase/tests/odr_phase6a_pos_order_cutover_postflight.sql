-- ODR-6A POS Order cutover closing postflight. SELECT-only.
-- Run after authenticated POS smoke on a dummy Company in CONTROLLED mode.
WITH odr_orders AS (
  SELECT sale.company_id,sale.id sales_id,sale.is_tempo,
    sale.grand_total_after_rounding,sale.order_runtime_status,
    sale.document_status,reservation.id reservation_id,
    reservation.status reservation_status,
    reservation.total_reserved_base_qty,
    reservation.total_released_base_qty,
    reservation.total_dispatched_base_qty
  FROM public.sales_stock_reservations reservation
  JOIN public.sales_headers sale ON sale.company_id=reservation.company_id
    AND sale.id=reservation.sales_id
),checks AS (
  SELECT 'odr6a_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*),'requiredVersion','20260828280000') details
  FROM private.kgs_schema_migrations WHERE version='20260828280000'

  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

  UNION ALL
  SELECT 'automatic_posting_remains_closed',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('automaticCompanies',count(*))
  FROM public.finance_company_policies WHERE posting_mode='AUTOMATIC'

  UNION ALL
  SELECT 'order_reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('reservationCount',count(*))
  FROM (SELECT reservation.id
    FROM public.sales_stock_reservations reservation
    LEFT JOIN public.sales_stock_reservation_lines line
      ON line.company_id=reservation.company_id
     AND line.reservation_id=reservation.id
    GROUP BY reservation.id,reservation.total_reserved_base_qty,
      reservation.total_released_base_qty,reservation.total_dispatched_base_qty
    HAVING round(COALESCE(sum(line.reserved_base_qty),0),6)<>
        round(reservation.total_reserved_base_qty,6)
      OR round(COALESCE(sum(line.released_base_qty),0),6)<>
        round(reservation.total_released_base_qty,6)
      OR round(COALESCE(sum(line.dispatched_base_qty),0),6)<>
        round(reservation.total_dispatched_base_qty,6)) invalid

  UNION ALL
  SELECT 'confirmed_order_document_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM odr_orders sale
  LEFT JOIN public.sales_invoice_snapshots invoice
    ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.sales_id
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.sales_id
   AND delivery.reservation_id=sale.reservation_id
  WHERE invoice.id IS NULL OR delivery.id IS NULL

  UNION ALL
  SELECT 'confirmed_order_final_invoice_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_invoice_snapshots invoice
  JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
    AND sale.id=invoice.sales_id
  LEFT JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=invoice.company_id
   AND delivery.invoice_snapshot_id=invoice.id
  WHERE invoice.snapshot_provenance='ORDER_CONFIRM'
    AND (invoice.invoice_no!~'^INV-[0-9]{8}-[0-9]{10}$'
      OR sale.invoice_no IS DISTINCT FROM invoice.invoice_no
      OR invoice.snapshot_payload->>'invoiceNo' IS DISTINCT FROM invoice.invoice_no
      OR (delivery.id IS NOT NULL AND
        delivery.snapshot_payload->>'invoiceNo' IS DISTINCT FROM invoice.invoice_no))

  UNION ALL
  SELECT 'confirmed_order_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM odr_orders sale
  WHERE sale.document_status='DRAFT' AND (
    EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=sale.company_id
        AND movement.reference_id=sale.sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_dispatch_allocations allocation
      WHERE allocation.company_id=sale.company_id
        AND allocation.sales_id=sale.sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects effect
      WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.sales_id))

  UNION ALL
  SELECT 'confirmed_order_payment_request_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('orderCount',count(*))
  FROM (SELECT sale.company_id,sale.sales_id,sale.is_tempo,
      sale.grand_total_after_rounding,
      COALESCE(sum(request.amount),0) request_total
    FROM odr_orders sale
    LEFT JOIN public.sales_payment_verification_requests request
      ON request.company_id=sale.company_id AND request.sales_id=sale.sales_id
    WHERE sale.reservation_status IN('OPEN','PARTIALLY_DISPATCHED')
    GROUP BY sale.company_id,sale.sales_id,sale.is_tempo,
      sale.grand_total_after_rounding) payment
  WHERE (NOT payment.is_tempo
      AND payment.request_total<>payment.grand_total_after_rounding)
    OR (payment.is_tempo
      AND payment.request_total>payment.grand_total_after_rounding)

  UNION ALL
  SELECT 'cash_payment_drawer_once_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=request.company_id
   AND movement.id=request.cash_drawer_movement_id
  WHERE (request.settlement_route_snapshot='CASH_DRAWER' AND (
      movement.id IS NULL OR movement.direction<>'IN'
      OR movement.movement_type<>'SALE_PAYMENT_INTENT'
      OR movement.amount<>request.amount
      OR movement.source_table<>'sales_payment_verification_requests'
      OR movement.source_id<>request.id))
    OR (request.settlement_route_snapshot<>'CASH_DRAWER'
      AND request.cash_drawer_movement_id IS NOT NULL)

  UNION ALL
  SELECT 'canceled_order_reservation_release',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('reservationCount',count(*))
  FROM odr_orders sale
  WHERE sale.order_runtime_status='CANCELED' AND (
    sale.reservation_status<>'RELEASED'
    OR sale.total_released_base_qty<>
      sale.total_reserved_base_qty-sale.total_dispatched_base_qty)

  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
),inventory AS (
  SELECT 'odr6a_pos_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'orders',(SELECT count(*) FROM odr_orders),
      'scheduledOrders',(SELECT count(*) FROM public.sales_headers sale
        JOIN public.sales_stock_reservations reservation
          ON reservation.company_id=sale.company_id
         AND reservation.sales_id=sale.id
        WHERE sale.order_timing_mode='SCHEDULED'),
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='OPEN'),
      'releasedReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='RELEASED'),
      'pendingPaymentRequests',(SELECT count(*)
        FROM public.sales_payment_verification_requests WHERE status='PENDING'),
      'linkedDeliveries',(SELECT count(*) FROM public.sales_delivery_documents
        WHERE reservation_id IS NOT NULL),
      'dispatchAllocations',(SELECT count(*) FROM public.sales_dispatch_allocations),
      'odrEvents',(SELECT count(*) FROM public.financial_events
        WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED'))
    ) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
