-- ODR-2A rollback-safe schema behavior test.
BEGIN;
DO $test$
DECLARE v_sale public.sales_headers%ROWTYPE;v_requirement RECORD;
  v_reservation UUID;v_total NUMERIC;v_stock_before NUMERIC;v_stock_after NUMERIC;
  v_key UUID:=gen_random_uuid();v_guarded BOOLEAN:=FALSE;
BEGIN
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.document_status='DRAFT' AND sale.order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
    AND EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=sale.company_id AND requirement.sales_id=sale.id)
  ORDER BY sale.created_at,sale.id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: eligible Draft required'; END IF;
  SELECT sum(quantity_base) INTO v_total FROM public.sale_stock_requirements
  WHERE company_id=v_sale.company_id AND sales_id=v_sale.id;
  SELECT COALESCE(sum(stock_qty),0) INTO v_stock_before FROM public.product_stocks
  WHERE company_id=v_sale.company_id;
  INSERT INTO public.sales_stock_reservations(company_id,sales_id,warehouse_id,
    total_reserved_base_qty,confirmation_idempotency_key,confirmed_by)
  VALUES(v_sale.company_id,v_sale.id,COALESCE(v_sale.sales_warehouse_id,
    (SELECT sales_warehouse_id FROM public.cashier_sessions WHERE company_id=v_sale.company_id
      AND id=v_sale.session_id)),v_total,v_key,v_sale.created_by) RETURNING id INTO v_reservation;
  FOR v_requirement IN SELECT * FROM public.sale_stock_requirements
    WHERE company_id=v_sale.company_id AND sales_id=v_sale.id LOOP
    INSERT INTO public.sales_stock_reservation_lines(company_id,reservation_id,sales_id,
      sales_detail_id,stock_requirement_id,stock_product_id,warehouse_id,
      requested_base_qty,reserved_base_qty,available_base_qty_snapshot)
    VALUES(v_sale.company_id,v_reservation,v_sale.id,v_requirement.sales_detail_id,
      v_requirement.id,v_requirement.stock_product_id,
      COALESCE(v_sale.sales_warehouse_id,(SELECT sales_warehouse_id
        FROM public.cashier_sessions WHERE company_id=v_sale.company_id AND id=v_sale.session_id)),
      v_requirement.quantity_base,v_requirement.quantity_base,v_requirement.quantity_base);
  END LOOP;
  INSERT INTO public.sales_stock_reservation_audit(company_id,reservation_id,sales_id,
    action,actor_id,idempotency_key,after_state)
  VALUES(v_sale.company_id,v_reservation,v_sale.id,'CONFIRM',v_sale.created_by,v_key,
    jsonb_build_object('test',TRUE));
  BEGIN UPDATE public.sales_stock_reservation_audit SET after_state='{}'::JSONB
    WHERE reservation_id=v_reservation;
  EXCEPTION WHEN raise_exception THEN
    v_guarded:=SQLERRM='SALES_STOCK_RESERVATION_AUDIT_IMMUTABLE';
  END;
  IF NOT v_guarded THEN RAISE EXCEPTION 'TEST_FAILED: audit immutability'; END IF;
  SELECT COALESCE(sum(stock_qty),0) INTO v_stock_after FROM public.product_stocks
  WHERE company_id=v_sale.company_id;
  IF v_stock_after<>v_stock_before THEN RAISE EXCEPTION 'TEST_FAILED: Stock changed'; END IF;
END
$test$;
ROLLBACK;
