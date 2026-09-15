-- Authenticated, self-contained, rollback-only client contract behavior.
-- Run only on the isolated Backoffice Sales development project.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_product uuid;v_today date;v_topup numeric;
  v_source_before numeric;v_batch_id uuid:=gen_random_uuid();
  v_fixture_movement uuid:=gen_random_uuid();
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;v_draft jsonb;
  v_workspace jsonb;v_detail jsonb;v_order uuid;v_order_line uuid;v_delivery uuid;
  v_delivery_line uuid;v_version bigint;v_due date;v_blocked boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911150000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260911150000 required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,customer.id,product_uom.id,product_uom.product_id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_customer,v_product_uom,v_product,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id AND warehouse.is_active
    AND warehouse.is_sale_source AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
    AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
    AND (SELECT count(DISTINCT rule.account_function_key)
      FROM public.transaction_categories category JOIN public.transaction_account_rules rule
        ON rule.company_id=category.company_id AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT'
        AND category.is_active AND rule.account_function_key IN('COGS','INVENTORY_ASSET'))=2
  ORDER BY company.id,store.id,warehouse.id,customer.is_system_customer DESC,customer.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Backoffice master fixture missing';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id) VALUES(v_actor,v_company)
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;

  -- Prepare Office mode only within this rollback-only fixture. Unit 45 gates
  -- new roots by Company mode; never bypass that gate for the Sales RPCs.
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

  -- The Invoice client contract does not depend on a shortage-free Product.
  -- Add a canonical FIFO layer inside this rollback-only transaction so an
  -- existing operational shortage allocation cannot invalidate the fixture.
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
    GREATEST(COALESCE(product.cogs,1),1),v_company
  FROM public.products product WHERE product.company_id=v_company AND product.id=v_product;
  SELECT stock_qty INTO STRICT v_source_before FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_fixture_movement,v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_INVOICE_CLIENT_TEST',v_batch_id,
    v_company,product.uom_id,uom.name,v_source_before,v_actor,clock_timestamp(),
    'POSTED',v_batch_id,'Rollback-only Invoice client fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_product;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),jsonb_build_object(
    'storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,'selectedPricelistId',NULL,
    'orderDate',v_today,'plannedDeliveryDate',v_today,'isTempo',true,'dueDate',v_today+21,
    'currencyCode','IDR','globalDiscount',0,'deliveryFeeAmount',12500,
    'roundingDirection','NONE','roundingIncrement',100,'lines',jsonb_build_array(
      jsonb_build_object('productUomId',v_product_uom,'quantity',1,'overrideUnitPrice',50000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO STRICT v_order_line FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND sales_order_id=v_order;

  -- A confirmed but not received SO must not be invoiceable.
  BEGIN
    PERFORM public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
      jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,'dueDate',v_today+21,
        'paymentTermId',NULL,'lines',jsonb_build_array(jsonb_build_object(
          'salesOrderLineId',v_order_line,'quantityUom',1,'unitPrice',50000))));
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%BACKOFFICE_SALES_ORDER_NOT_INVOICEABLE%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: non-completed SO became invoiceable'; END IF;

  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id INTO STRICT v_delivery_line FROM public.backoffice_sales_delivery_order_lines
    WHERE company_id=v_company AND delivery_order_id=v_delivery;
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
    WHERE company_id=v_company AND id=v_delivery;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,'quantityUom',1)),
    'Invoice client rollback fixture');
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
    WHERE company_id=v_company AND id=v_delivery;
  v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),v_today,
    'Invoice client rollback fixture');
  IF v_received->>'deliveryStatus'<>'COMPLETED' THEN RAISE EXCEPTION 'TEST_FAILED: receipt not completed'; END IF;

  v_due:=v_today+21;
  v_draft:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,'dueDate',v_due,
      'paymentTermId',NULL,'deliveryFeeAmount',12500,'notes','Client activation rollback test',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'unitPrice',50000,'discountAmount',2500,'taxApplied',false))));
  IF (v_draft->'data'->'schedules'->0->>'dueDate')::date<>v_due
    OR (v_draft->'data'->>'deliveryFeeAmount')::numeric<>12500 THEN
    RAISE EXCEPTION 'TEST_FAILED: explicit due date or delivery fee not preserved %',v_draft;
  END IF;
  v_workspace:=public.get_backoffice_sales_invoice_workspace(v_order,NULL,NULL,100);
  v_detail:=public.get_backoffice_sales_invoice_ui((v_draft->'data'->>'id')::uuid);
  IF (v_workspace->'sourceOrder'->>'fulfillmentStatus')<>'COMPLETED'
    OR (v_workspace->'sourceOrder'->>'totalToInvoiceBaseQty')::numeric<>0
    OR jsonb_array_length(v_workspace->'invoices')<>1
    OR v_detail->'data'->>'salesOrderNo' IS NULL
    OR v_detail->'data'->'lines'->0->>'productName' IS NULL
    OR (v_detail->'data'->>'dueDate')::date<>v_due THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice client read-model invalid';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_invoice_client_activation_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'non-completed SO blocked','completed receipt enables Invoice','explicit due date preserved',
    'delivery fee preserved','quantity held','workspace/detail enriched',
    'operational shortage independent','all fixture writes rolled back']) details;
