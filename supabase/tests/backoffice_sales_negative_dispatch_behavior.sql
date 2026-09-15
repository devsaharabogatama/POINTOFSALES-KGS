-- Authenticated, self-contained, rollback-only behavior for Warehouse-authorized
-- Backoffice shortage Dispatch. Never run on production.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_today date;v_original_negative boolean;
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;
  v_order uuid;v_delivery uuid;v_delivery_line uuid;v_version bigint;
  v_transit uuid;v_transfer jsonb;v_failed boolean;v_allocation uuid;
  v_provisional numeric(20,4);v_actual numeric(20,4);v_replenishment_batch uuid:=gen_random_uuid();
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911140000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260911140000 required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,customer.id,product_uom.id,
    product_uom.product_id,(clock_timestamp() AT TIME ZONE company.timezone)::date,
    warehouse.allow_negative_stock
  INTO v_company,v_store,v_warehouse,v_customer,v_product_uom,v_product,v_today,
    v_original_negative
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
    AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
    AND NOT EXISTS(SELECT 1 FROM public.negative_stock_sale_allocations allocation
      WHERE allocation.company_id=company.id AND allocation.stock_product_id=product.id
        AND allocation.warehouse_id=warehouse.id AND allocation.reconciled_at IS NULL)
    AND NOT EXISTS(SELECT 1 FROM public.backoffice_negative_stock_allocations allocation
      WHERE allocation.company_id=company.id AND allocation.product_id=product.id
        AND allocation.source_warehouse_id=warehouse.id AND allocation.reconciled_at IS NULL)
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='STOCK_TRANSFER'
        AND category.is_active AND category.is_system_default)
    AND (SELECT count(DISTINCT rule.account_function_key)
      FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
       AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id
        AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
        AND rule.account_function_key IN('COGS','INVENTORY_ASSET'))=2
  ORDER BY company.id,store.id,warehouse.id,customer.is_system_customer DESC,
    customer.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Backoffice sales fixture master missing';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET
    company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;

  -- Unit 45 makes Company mode authoritative for new Office roots. Prepare
  -- that prerequisite only inside the enclosing rollback-only transaction.
  -- Clear the setup marker BEFORE invoking any operational Sales RPC.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company sales process setting required'; END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(
    v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');

  -- Isolate one existing master Product without inventing invalid master rows.
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,0,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET stock_qty=0,updated_at=clock_timestamp();
  UPDATE public.product_batches SET qty_remaining=0
  WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
      'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
      'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
      'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object(
        'productUomId',v_product_uom,'quantity',1))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT line.id INTO v_delivery_line FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery;
  SELECT master_version INTO v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;

  -- Warehouse is re-read at Dispatch: OFF must fail without any Dispatch effect.
  UPDATE public.warehouses SET allow_negative_stock=false
  WHERE company_id=v_company AND id=v_warehouse;
  v_failed:=false;
  BEGIN
    PERFORM public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,
        'quantityUom',1)),'Warehouse OFF denial');
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%INSUFFICIENT_STOCK%'; END;
  IF NOT v_failed OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_dispatches
      WHERE company_id=v_company AND delivery_order_id=v_delivery) THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse OFF shortage was not atomic';
  END IF;

  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,
      'quantityUom',1)),'Warehouse ON shortage');
  v_transit:=(v_dispatched->>'transitWarehouseId')::uuid;
  SELECT allocation.id,allocation.provisional_unit_cost
    INTO v_allocation,v_provisional
  FROM public.backoffice_negative_stock_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.delivery_order_id=v_delivery;
  IF v_dispatched->>'deliveryStatus'<>'IN_TRANSIT' OR v_allocation IS NULL
    OR (SELECT stock_qty FROM public.product_stocks WHERE company_id=v_company
      AND product_id=v_product AND warehouse_id=v_warehouse)<>-1
    OR (SELECT stock_qty FROM public.product_stocks WHERE company_id=v_company
      AND product_id=v_product AND warehouse_id=v_transit)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse ON shortage Dispatch shape invalid %',v_dispatched;
  END IF;

  -- Manual/ordinary transfer must remain strict even when Warehouse is enabled.
  v_transfer:=private.save_stock_transfer_document(NULL,NULL,v_warehouse,v_transit,v_today,
    'Ordinary transfer denial fixture',jsonb_build_array(jsonb_build_object(
      'productId',v_product,'quantityBase',1,'notes','Must remain blocked')));
  v_failed:=false;
  BEGIN
    PERFORM private.post_stock_transfer((v_transfer->>'documentId')::uuid,
      (v_transfer->>'masterVersion')::bigint,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%INSUFFICIENT_STOCK%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: ordinary Stock Transfer accepted shortage'; END IF;

  -- Customer may receive before replenishment; COGS is provisional at this point.
  SELECT master_version INTO v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,
    gen_random_uuid(),v_today,'Receipt before replenishment');
  IF v_received->>'deliveryStatus'<>'COMPLETED'
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_receipt_fifo_allocations receipt_fifo
      JOIN public.backoffice_negative_stock_allocations allocation
        ON allocation.company_id=receipt_fifo.company_id
       AND allocation.transit_batch_id=receipt_fifo.transit_batch_id
      WHERE allocation.company_id=v_company AND allocation.id=v_allocation
        AND receipt_fifo.unit_cost=v_provisional) THEN
    RAISE EXCEPTION 'TEST_FAILED: receipt before replenishment did not consume provisional Transit FIFO';
  END IF;

  -- Simulate the Stock/FIFO part of a later canonical Goods Receipt. The insert
  -- trigger must consume the incoming batch against the shortage and retain no
  -- duplicate FIFO quantity at the source Warehouse.
  v_actual:=v_provisional+5;
  UPDATE public.product_stocks SET stock_qty=stock_qty+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  VALUES(v_replenishment_batch,v_product,v_warehouse,1,1,v_actual,v_company);
  IF (SELECT qty_remaining FROM public.product_batches WHERE company_id=v_company
      AND id=v_replenishment_batch)<>0
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_negative_stock_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.id=v_allocation
        AND allocation.replenished_base_qty=1 AND allocation.reconciled_at IS NOT NULL
        AND allocation.cogs_variance_total=5)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_negative_stock_replenishments replenishment
      WHERE replenishment.company_id=v_company
        AND replenishment.negative_allocation_id=v_allocation
        AND replenishment.replenished_base_qty=1
        AND replenishment.inventory_revaluation=0 AND replenishment.cogs_variance=5) THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice shortage replenishment/cost settlement invalid';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_negative_dispatch_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'Warehouse OFF atomic denial','Warehouse ON shortage Dispatch',
    'source negative plus outbound Transit positive','ordinary Transfer remains blocked',
    'customer receipt before replenishment','later replenishment closes shortage',
    'provisional-to-actual COGS variance','all fixture writes rolled back']) details;
