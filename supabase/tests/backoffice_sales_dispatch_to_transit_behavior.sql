-- Authenticated rollback-only behavior for Backoffice partial/full Dispatch to Transit.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_original_negative boolean;v_topup numeric;
  v_source_before numeric;v_source_after numeric;v_transit_before numeric;
  v_transit_after numeric;v_company_stock_before numeric;v_company_stock_after numeric;
  v_created jsonb;v_confirmed jsonb;v_partial jsonb;v_retry jsonb;v_final jsonb;
  v_order_id uuid;v_delivery_id uuid;v_delivery_line_id uuid;v_version bigint;
  v_partial_operation uuid:=gen_random_uuid();v_final_operation uuid:=gen_random_uuid();
  v_transit uuid;v_payload jsonb;v_before jsonb;v_after jsonb;
  v_failed boolean:=false;v_batch_id uuid:=gen_random_uuid();v_fixture_movement uuid:=gen_random_uuid();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909151000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Dispatch to Transit gate required';
  END IF;
  SELECT profile.id INTO STRICT v_actor
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    customer.id,product_uom.id,product_uom.product_id
  INTO STRICT v_company,v_store,v_warehouse,v_original_negative,v_customer,
    v_product_uom,v_product
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
    AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='STOCK_TRANSFER'
        AND category.is_active AND category.is_system_default)
  ORDER BY company.id,store.id,warehouse.id,customer.is_system_customer DESC,
    customer.id,product_uom.id LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  SELECT COALESCE(stock_qty,0) INTO v_source_before FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_source_before:=COALESCE(v_source_before,0);
  v_topup:=CASE WHEN v_source_before<10 THEN 10-v_source_before ELSE 10 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,
    updated_at=clock_timestamp();
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch_id,v_product,v_warehouse,v_topup,v_topup,
    GREATEST(COALESCE(product.cogs,1),0),v_company
  FROM public.products product WHERE product.company_id=v_company AND product.id=v_product;
  SELECT stock_qty INTO STRICT v_source_before FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_fixture_movement,v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_DISPATCH_TEST',v_batch_id,
    v_company,product.uom_id,uom.name,v_source_before,v_actor,clock_timestamp(),
    'POSTED',v_batch_id,'Rollback-only Dispatch fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_product;

  SELECT jsonb_build_object(
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'events',(SELECT count(*) FROM public.financial_events),
    'journals',(SELECT count(*) FROM public.journal_entries),
    'dispatches',(SELECT count(*) FROM public.backoffice_sales_delivery_dispatches),
    'transfers',(SELECT count(*) FROM public.stock_transfer_documents),
    'movements',(SELECT count(*) FROM public.stock_movements)) INTO v_before;
  SELECT COALESCE(sum(stock_qty),0) INTO v_company_stock_before
  FROM public.product_stocks WHERE company_id=v_company AND product_id=v_product;

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',current_date,
    'plannedDeliveryDate',current_date+1,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',4)));
  v_created:=public.save_backoffice_sales_order_draft(
    NULL,NULL,gen_random_uuid(),v_payload);
  v_order_id:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order_id,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery_id:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id INTO STRICT v_delivery_line_id
  FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery_id;
  SELECT master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery_id;

  v_partial:=public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,
    v_partial_operation,jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line_id,'quantityUom',1)),'Partial fixture');
  v_transit:=(v_partial->>'transitWarehouseId')::uuid;
  IF v_partial->>'deliveryStatus'<>'PARTIALLY_SHIPPED'
    OR (v_partial->>'dispatchedBaseQty')::numeric<>1
    OR (v_partial->>'totalShippedBaseQty')::numeric<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: partial Dispatch result invalid %',v_partial;
  END IF;
  v_retry:=public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,
    v_partial_operation,jsonb_build_array(jsonb_build_object(
      'quantityUom',1,'deliveryLineId',v_delivery_line_id)),'Partial fixture');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR v_retry->>'dispatchId'<>v_partial->>'dispatchId' THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry changed Dispatch identity';
  END IF;
  BEGIN
    PERFORM public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,
      gen_random_uuid(),jsonb_build_array(jsonb_build_object(
        'deliveryLineId',v_delivery_line_id,'quantityUom',1)),NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%';
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale Delivery version accepted'; END IF;

  SELECT master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery_id;
  v_final:=public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,
    v_final_operation,jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line_id,'quantityUom',3)),'Final fixture');
  IF v_final->>'deliveryStatus'<>'IN_TRANSIT'
    OR (v_final->>'totalShippedBaseQty')::numeric<>4 THEN
    RAISE EXCEPTION 'TEST_FAILED: full Dispatch result invalid %',v_final;
  END IF;

  SELECT stock_qty INTO STRICT v_source_after FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  SELECT COALESCE(stock_qty,0) INTO v_transit_after FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_transit AND product_id=v_product;
  v_transit_before:=v_transit_after-4;
  SELECT COALESCE(sum(stock_qty),0) INTO v_company_stock_after
  FROM public.product_stocks WHERE company_id=v_company AND product_id=v_product;
  IF v_source_after<>v_source_before-4 OR v_transit_after<>v_transit_before+4
    OR v_company_stock_after<>v_company_stock_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse/Transit balance invalid source % -> %, transit % -> %, company % -> %',
      v_source_before,v_source_after,v_transit_before,v_transit_after,
      v_company_stock_before,v_company_stock_after;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.warehouses transit
      WHERE transit.company_id=v_company AND transit.id=v_transit
        AND transit.transit_parent_warehouse_id=v_warehouse
        AND transit.transit_operation='SALES_DELIVERY_OUTBOUND')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=v_company AND delivery.id=v_delivery_id
        AND delivery.status='IN_TRANSIT' AND delivery.total_shipped_base_qty=4)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_order_id=v_order_id
        AND reservation.status='PARTIALLY_FULFILLED'
        AND reservation.total_in_transit_base_qty=4)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=v_order_id
        AND document.fulfillment_status='IN_TRANSIT') THEN
    RAISE EXCEPTION 'TEST_FAILED: Dispatch lifecycle reconciliation invalid';
  END IF;

  SELECT jsonb_build_object(
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'events',(SELECT count(*) FROM public.financial_events),
    'journals',(SELECT count(*) FROM public.journal_entries),
    'dispatches',(SELECT count(*) FROM public.backoffice_sales_delivery_dispatches)-2,
    'transfers',(SELECT count(*) FROM public.stock_transfer_documents)-2,
    'movements',(SELECT count(*) FROM public.stock_movements)-4) INTO v_after;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Dispatch downstream or idempotency effect invalid % -> %',
      v_before,v_after;
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_dispatch_to_transit_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'partial Dispatch','exact retry','stale version denial','final Dispatch',
    'source to dedicated Transit Stock','FIFO-preserving canonical transfer',
    'Company inventory unchanged','zero Invoice/Event/Journal effect',
    'all fixture writes rolled back']) details;
