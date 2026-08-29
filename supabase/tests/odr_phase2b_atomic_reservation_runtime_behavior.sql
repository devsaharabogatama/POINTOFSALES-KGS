-- ODR-2B rollback-safe confirm/retry/cancel behavior.
BEGIN;
DO $test$
DECLARE v_sale public.sales_headers%ROWTYPE;v_sale_id UUID;v_actor UUID;
  v_confirm UUID:=gen_random_uuid();
  v_cancel UUID:=gen_random_uuid();v_result JSONB;v_retry JSONB;v_stock NUMERIC;
  v_stock_after NUMERIC;v_fifo NUMERIC;v_fifo_after NUMERIC;
  v_movement BIGINT;v_movement_after BIGINT;v_event BIGINT;
  v_event_after BIGINT;v_invoice BIGINT;v_invoice_after BIGINT;v_payment BIGINT;
  v_payment_after BIGINT;v_delivery BIGINT;v_delivery_after BIGINT;
  v_reservation public.sales_stock_reservations%ROWTYPE;v_guarded BOOLEAN:=FALSE;
BEGIN
  SELECT sale.id,session.cashier_id INTO v_sale_id,v_actor
  FROM public.sales_headers sale
  JOIN public.cashier_sessions source_session ON source_session.company_id=sale.company_id
    AND source_session.id=sale.session_id
  JOIN public.cashier_sessions session ON session.company_id=sale.company_id
    AND session.store_id=sale.store_id AND session.cashier_id=source_session.cashier_id
    AND session.status='OPEN'::public.session_status
  WHERE sale.document_status='DRAFT'
    AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
    AND EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=sale.company_id AND requirement.sales_id=sale.id)
  ORDER BY sale.created_at,sale.id LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: own open-session Draft required';
  END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale WHERE sale.id=v_sale_id;

  PERFORM set_config('request.jwt.claim.sub',v_actor::TEXT,TRUE);
  PERFORM set_config('request.jwt.claim.role','authenticated',TRUE);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_sale.company_id,'ODR2B_TEST') ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();

  SELECT COALESCE(sum(stock_qty),0) INTO v_stock FROM public.product_stocks
    WHERE company_id=v_sale.company_id;
  SELECT COALESCE(sum(qty_remaining),0) INTO v_fifo FROM public.product_batches
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_movement FROM public.stock_movements
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_event FROM public.financial_events
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_invoice FROM public.sales_invoice_snapshots
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_payment FROM public.sales_payments
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_delivery FROM public.sales_delivery_documents
    WHERE company_id=v_sale.company_id;

  v_result:=public.confirm_pos_sales_order(v_sale.id,v_sale.master_version,
    v_confirm,'ODR-2B rollback-safe test');
  v_retry:=public.confirm_pos_sales_order(v_sale.id,v_sale.master_version,
    v_confirm,'ODR-2B rollback-safe test');
  IF NOT COALESCE((v_retry->>'exactRetry')::BOOLEAN,FALSE)
     OR v_result->>'reservationId' IS DISTINCT FROM v_retry->>'reservationId' THEN
    RAISE EXCEPTION 'TEST_FAILED: confirmation exact retry';
  END IF;
  BEGIN
    PERFORM public.confirm_pos_sales_order(v_sale.id,v_sale.master_version,
      v_confirm,'DIFFERENT PAYLOAD');
  EXCEPTION WHEN raise_exception THEN
    v_guarded:=SQLERRM='IDEMPOTENCY_PAYLOAD_CONFLICT';
  END;
  IF NOT v_guarded THEN RAISE EXCEPTION 'TEST_FAILED: confirmation payload conflict'; END IF;
  SELECT reservation.* INTO v_reservation FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_sale.company_id AND reservation.sales_id=v_sale.id;
  IF NOT FOUND OR v_reservation.status<>'OPEN'
     OR v_reservation.total_reserved_base_qty<=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: reservation missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_lines line
    WHERE line.company_id=v_sale.company_id AND line.reservation_id=v_reservation.id
      AND line.reserved_base_qty<>line.requested_base_qty) THEN
    RAISE EXCEPTION 'TEST_FAILED: reservation quantity';
  END IF;

  v_result:=public.cancel_pos_sales_order(v_sale.id,(v_result->>'masterVersion')::BIGINT,
    v_cancel,'ODR-2B rollback-safe cancellation');
  v_retry:=public.cancel_pos_sales_order(v_sale.id,(v_result->>'masterVersion')::BIGINT-1,
    v_cancel,'ODR-2B rollback-safe cancellation');
  IF NOT COALESCE((v_retry->>'exactRetry')::BOOLEAN,FALSE) THEN
    RAISE EXCEPTION 'TEST_FAILED: cancellation exact retry';
  END IF;
  v_guarded:=FALSE;
  BEGIN
    PERFORM public.cancel_pos_sales_order(v_sale.id,
      (v_result->>'masterVersion')::BIGINT-1,v_cancel,'DIFFERENT PAYLOAD');
  EXCEPTION WHEN raise_exception THEN
    v_guarded:=SQLERRM='IDEMPOTENCY_PAYLOAD_CONFLICT';
  END;
  IF NOT v_guarded THEN RAISE EXCEPTION 'TEST_FAILED: cancellation payload conflict'; END IF;
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_lines line
    WHERE line.company_id=v_sale.company_id AND line.reservation_id=v_reservation.id
      AND line.released_base_qty+line.dispatched_base_qty<>line.reserved_base_qty) THEN
    RAISE EXCEPTION 'TEST_FAILED: reservation release';
  END IF;

  SELECT COALESCE(sum(stock_qty),0) INTO v_stock_after FROM public.product_stocks
    WHERE company_id=v_sale.company_id;
  SELECT COALESCE(sum(qty_remaining),0) INTO v_fifo_after FROM public.product_batches
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_movement_after FROM public.stock_movements
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_event_after FROM public.financial_events
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_invoice_after FROM public.sales_invoice_snapshots
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_payment_after FROM public.sales_payments
    WHERE company_id=v_sale.company_id;
  SELECT count(*) INTO v_delivery_after FROM public.sales_delivery_documents
    WHERE company_id=v_sale.company_id;
  IF v_stock_after<>v_stock OR v_fifo_after<>v_fifo
     OR v_movement_after<>v_movement OR v_event_after<>v_event
     OR v_invoice_after<>v_invoice OR v_payment_after<>v_payment
     OR v_delivery_after<>v_delivery THEN
    RAISE EXCEPTION 'TEST_FAILED: reservation created final effect';
  END IF;
END
$test$;
ROLLBACK;
