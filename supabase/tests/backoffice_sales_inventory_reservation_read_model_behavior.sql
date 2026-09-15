-- Authenticated rollback-only behavior for combined POS + Backoffice Reserved Out.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_factor numeric;v_on_hand numeric;
  v_pos_reserved numeric;v_backoffice_reserved_before numeric;v_qty numeric:=1;
  v_qty_base numeric;v_created jsonb;v_confirmed jsonb;v_overview jsonb;
  v_order_id uuid;v_order_no text;v_delivery_id uuid;v_delivery_no text;
  v_balance jsonb;v_allocation jsonb;v_stock_after numeric;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909148000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: inventory reservation read model migration required';
  END IF;
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
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
       AND product.id=product_uom.product_id AND product.is_active
       AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0)
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),
      updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE
    SET is_enabled=true,updated_by=excluded.updated_by;
  SELECT store.id,warehouse.id INTO STRICT v_store,v_warehouse
  FROM public.stores store
  JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  WHERE store.company_id=v_company AND store.status='ACTIVE'
  ORDER BY warehouse.store_id NULLS LAST,store.id,warehouse.id LIMIT 1;
  SELECT id INTO STRICT v_customer FROM public.customers
  WHERE company_id=v_company AND is_active
  ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT product_uom.id,product_uom.product_id,product_uom.factor_to_base
    INTO STRICT v_product_uom,v_product,v_factor
  FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
    AND NOT product.is_bundle
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.factor_to_base>0
  ORDER BY product_uom.id LIMIT 1;
  v_qty_base:=v_qty*v_factor;
  SELECT COALESCE(stock.stock_qty,0) INTO v_on_hand
  FROM (SELECT 1) seed LEFT JOIN public.product_stocks stock
    ON stock.company_id=v_company AND stock.warehouse_id=v_warehouse
   AND stock.product_id=v_product;
  SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-
      line.dispatched_base_qty),0) INTO v_pos_reserved
  FROM public.sales_stock_reservation_lines line
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
    AND line.stock_product_id=v_product
    AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED');
  SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-
      line.in_transit_base_qty-line.completed_base_qty),0)
    INTO v_backoffice_reserved_before
  FROM public.backoffice_sales_reservation_lines line
  JOIN public.backoffice_sales_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
    AND line.product_id=v_product AND reservation.status<>'RELEASED';

  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
      'customerId',v_customer,'selectedPricelistId',NULL,
      'orderDate',current_date,'plannedDeliveryDate',current_date+1,
      'isTempo',false,'currencyCode','IDR','globalDiscount',0,
      'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object(
        'productUomId',v_product_uom,'quantity',v_qty))));
  v_order_id:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order_id,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_order_no:=v_confirmed->'data'->>'orderNo';
  v_delivery_id:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  v_delivery_no:=v_confirmed->'fulfillment'->>'deliveryNo';
  v_overview:=public.get_inventory_stock_overview();

  SELECT item INTO STRICT v_balance
  FROM jsonb_array_elements(v_overview->'balances') item
  WHERE item->>'product_id'=v_product::text
    AND item->>'warehouse_id'=v_warehouse::text;
  SELECT item INTO STRICT v_allocation
  FROM jsonb_array_elements(v_overview->'reservationAllocations') item
  WHERE item->>'source'='BACKOFFICE'
    AND item->>'sales_order_id'=v_order_id::text
    AND item->>'product_id'=v_product::text;

  IF (v_overview->>'reservationReadModelVersion')::integer<>2
    OR (v_balance->>'pos_reserved_out_base_qty')::numeric<>v_pos_reserved
    OR (v_balance->>'backoffice_reserved_out_base_qty')::numeric<>
      v_backoffice_reserved_before+v_qty_base
    OR (v_balance->>'reserved_out_base_qty')::numeric<>
      v_pos_reserved+v_backoffice_reserved_before+v_qty_base
    OR (v_balance->>'available_to_sell_base_qty')::numeric<>
      v_on_hand-v_pos_reserved-v_backoffice_reserved_before-v_qty_base THEN
    RAISE EXCEPTION 'TEST_FAILED: combined Stock Overview quantity invalid';
  END IF;
  IF v_allocation->>'sales_order_no'<>v_order_no
    OR (v_allocation->>'reserved_out_base_qty')::numeric<>v_qty_base
    OR v_allocation->>'scheduled_date'<>(current_date+1)::text
    OR NOT EXISTS(SELECT 1
      FROM jsonb_array_elements(v_allocation->'delivery_orders') delivery
      WHERE delivery->>'id'=v_delivery_id::text
        AND delivery->>'deliveryNo'=v_delivery_no
        AND delivery->>'status'='READY') THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice allocation lineage invalid';
  END IF;
  SELECT COALESCE(stock.stock_qty,0) INTO v_stock_after
  FROM (SELECT 1) seed LEFT JOIN public.product_stocks stock
    ON stock.company_id=v_company AND stock.warehouse_id=v_warehouse
   AND stock.product_id=v_product;
  IF v_stock_after<>v_on_hand THEN
    RAISE EXCEPTION 'TEST_FAILED: Stock Overview gate changed On Hand';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'backoffice_sales_inventory_reservation_read_model_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'authenticated canonical Confirm fixture','POS plus Backoffice source sum',
    'Available equals On Hand minus combined Reserved Out',
    'SO Customer Delivery lineage','On Hand unchanged',
    'all fixture writes rolled back'],'writesPersisted',false) details;
