-- Authenticated rollback-only behavior for atomic Backoffice Confirm fulfillment.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_factor numeric;v_on_hand numeric;
  v_pos_reserved numeric;v_bo_reserved numeric;v_available numeric;v_qty numeric;
  v_original_negative boolean;v_created jsonb;v_confirmed jsonb;v_retry jsonb;
  v_order_id uuid;v_expected_version bigint;v_confirm_operation uuid:=gen_random_uuid();
  v_payload jsonb;v_before jsonb;v_after jsonb;v_blocked boolean:=false;
  v_reservation public.backoffice_sales_reservations%rowtype;
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
BEGIN
  SELECT profile.id INTO STRICT v_actor
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND warehouse.is_active AND warehouse.is_sale_source
        AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.customers customer WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
       AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0)
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  SELECT store.id,warehouse.id,warehouse.allow_negative_stock
    INTO STRICT v_store,v_warehouse,v_original_negative
  FROM public.stores store
  JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  WHERE store.company_id=v_company AND store.status='ACTIVE'
  ORDER BY warehouse.store_id NULLS LAST,store.id,warehouse.id LIMIT 1;
  SELECT id INTO STRICT v_customer FROM public.customers WHERE company_id=v_company
    AND is_active ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT product_uom.id,product_uom.product_id,product_uom.factor_to_base
    INTO STRICT v_product_uom,v_product,v_factor
  FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.factor_to_base>0
  ORDER BY product_uom.id LIMIT 1;

  SELECT COALESCE(stock_qty,0) INTO v_on_hand FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_on_hand:=COALESCE(v_on_hand,0);
  SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-line.dispatched_base_qty),0)
    INTO v_pos_reserved FROM public.sales_stock_reservation_lines line
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
    AND line.stock_product_id=v_product AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED');
  SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-line.in_transit_base_qty-line.completed_base_qty),0)
    INTO v_bo_reserved FROM public.backoffice_sales_reservation_lines line
  JOIN public.backoffice_sales_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
    AND line.product_id=v_product AND reservation.status<>'RELEASED';
  v_available:=v_on_hand-v_pos_reserved-v_bo_reserved;
  v_qty:=(GREATEST(v_available,0)+v_factor)/v_factor;

  SELECT jsonb_build_object(
    'retailReservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'retailDeliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events),
    'backofficeReservations',(SELECT count(*) FROM public.backoffice_sales_reservations),
    'backofficeDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders)) INTO v_before;
  v_payload:=jsonb_build_object(
    'storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
    'selectedPricelistId',NULL,'orderDate',current_date,
    'plannedDeliveryDate',current_date+1,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,'quantity',v_qty)));
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_order_id:=(v_created->'data'->>'id')::uuid;
  v_expected_version:=(v_created->'data'->>'masterVersion')::bigint;

  UPDATE public.warehouses SET allow_negative_stock=false WHERE company_id=v_company AND id=v_warehouse;
  BEGIN
    PERFORM public.confirm_backoffice_sales_order(v_order_id,v_expected_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%BACKOFFICE_SALES_NEGATIVE_RESERVATION_REQUIRES_WAREHOUSE_OPT_IN%';
  END;
  IF NOT v_blocked OR EXISTS(SELECT 1 FROM public.backoffice_sales_reservations
      WHERE company_id=v_company AND sales_order_id=v_order_id)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders
      WHERE company_id=v_company AND id=v_order_id AND status='DRAFT'
        AND master_version=v_expected_version) THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse negative reservation denial was not atomic';
  END IF;

  UPDATE public.warehouses SET allow_negative_stock=true WHERE company_id=v_company AND id=v_warehouse;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order_id,v_expected_version,v_confirm_operation);
  SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations
    WHERE company_id=v_company AND sales_order_id=v_order_id;
  SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders
    WHERE company_id=v_company AND sales_order_id=v_order_id AND delivery_kind='INITIAL';
  IF v_confirmed->'data'->>'status'<>'CONFIRMED'
    OR v_confirmed->'data'->>'fulfillmentStatus'<>'PREPARING'
    OR v_confirmed->'fulfillment'->>'deliveryStatus'<>'READY'
    OR v_reservation.total_reserved_base_qty<>v_reservation.total_ordered_base_qty
    OR v_reservation.shortage_base_qty<=0
    OR v_delivery.status<>'READY' OR v_delivery.parent_delivery_order_id IS NOT NULL
    OR (SELECT count(*) FROM public.backoffice_sales_reservation_lines
      WHERE company_id=v_company AND reservation_id=v_reservation.id)<>1
    OR (SELECT count(*) FROM public.backoffice_sales_delivery_order_lines
      WHERE company_id=v_company AND delivery_order_id=v_delivery.id)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic Confirm fulfillment result invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_fulfillment_audit
      WHERE company_id=v_company AND sales_order_id=v_order_id
        AND reservation_id=v_reservation.id AND action='RESERVE'
        AND operation_id=v_confirm_operation)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_fulfillment_audit
      WHERE company_id=v_company AND sales_order_id=v_order_id
        AND delivery_order_id=v_delivery.id AND action='CREATE_DELIVERY'
        AND after_state->>'confirmOperationId'=v_confirm_operation::text) THEN
    RAISE EXCEPTION 'TEST_FAILED: Confirm fulfillment audit coverage missing';
  END IF;

  v_retry:=public.confirm_backoffice_sales_order(v_order_id,v_expected_version,v_confirm_operation);
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR v_retry->'fulfillment'->>'reservationId'<>v_reservation.id::text
    OR v_retry->'fulfillment'->>'deliveryOrderId'<>v_delivery.id::text
    OR (SELECT count(*) FROM public.backoffice_sales_reservations
      WHERE company_id=v_company AND sales_order_id=v_order_id)<>1
    OR (SELECT count(*) FROM public.backoffice_sales_delivery_orders
      WHERE company_id=v_company AND sales_order_id=v_order_id)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Confirm exact retry duplicated fulfillment';
  END IF;

  SELECT jsonb_build_object(
    'retailReservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'retailDeliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events),
    'backofficeReservations',(SELECT count(*) FROM public.backoffice_sales_reservations)-1,
    'backofficeDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders)-1) INTO v_after;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Confirm created premature or duplicate downstream effect % -> %',v_before,v_after;
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
