-- Authenticated rollback-only behavior for Step 4/6.5B SHORT resolution.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_customer_category uuid;v_fixture_code text;
  v_product_uom uuid;v_product uuid;v_original_negative boolean;v_today date;
  v_topup numeric;v_stock_before numeric;v_transit_before numeric;v_transit_after numeric;
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;v_retry jsonb;
  v_invoice jsonb;v_resolution jsonb;v_resolve_operation uuid:=gen_random_uuid();v_source_before_resolution numeric;v_source_after_resolution numeric;v_order_id uuid;v_order_line_id uuid;v_delivery_id uuid;
  v_delivery_line_id uuid;v_version bigint;v_transit uuid;v_payload jsonb;
  v_disposition jsonb;v_operation uuid:=gen_random_uuid();
  v_batch_id uuid:=gen_random_uuid();v_fixture_movement uuid:=gen_random_uuid();
  v_event_before bigint;v_journal_before bigint;v_invoice_before bigint;
  v_failed boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912120000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: shortage resolution runtime required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912121000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical shortage audit forward-fix required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    product_uom.id,product_uom.product_id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_original_negative,
    v_product_uom,v_product,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
    AND NOT product.is_bundle AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
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
  ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Company, Store, Warehouse, Product-UOM and Customer Receipt Finance mapping required';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  SELECT customer.id INTO v_customer
  FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
    AND NOT customer.is_system_customer
  ORDER BY customer.id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT category.id INTO v_customer_category
    FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.is_system_category DESC,category.id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical active Customer Category required';
    END IF;
    v_fixture_code:='MIXRCV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_created:=public.save_customer_with_pricelist(
      NULL,NULL,v_fixture_code,'Mixed Receipt Rollback Customer',
      v_customer_category,NULL,NULL,NULL,'BUSINESS',0,NULL,
      'Rollback-only mixed receipt fixture',TRUE,NULL,NULL);
    v_customer:=(v_created->>'customerId')::uuid;
    IF v_customer IS NULL OR NOT EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.id=v_customer
        AND customer.code=v_fixture_code AND customer.is_active
        AND NOT customer.is_system_customer) THEN
      RAISE EXCEPTION 'TEST_FAILED: canonical rollback Customer fixture was not created';
    END IF;
  END IF;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE
    SET is_enabled=true,updated_by=excluded.updated_by;
  -- Rollback-only preparation; operational RPCs retain their real mode authority.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company sales process setting required';
  END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(
    v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  SELECT COALESCE(stock_qty,0) INTO v_stock_before FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_stock_before:=COALESCE(v_stock_before,0);
  v_topup:=CASE WHEN v_stock_before<10 THEN 10-v_stock_before ELSE 10 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,
    updated_at=clock_timestamp();
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch_id,v_product,v_warehouse,v_topup,v_topup,
    GREATEST(COALESCE(product.cogs,1),1),v_company
  FROM public.products product
  WHERE product.company_id=v_company AND product.id=v_product;
  SELECT stock_qty INTO STRICT v_stock_before FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_fixture_movement,v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_MIXED_RECEIPT_TEST',v_batch_id,
    v_company,product.uom_id,uom.name,v_stock_before,v_actor,clock_timestamp(),
    'POSTED',v_batch_id,'Rollback-only mixed receipt fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_product;

  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;
  SELECT count(*) INTO v_invoice_before FROM public.backoffice_sales_invoices;
  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
      'quantity',4,'overrideUnitPrice',50000)));
  v_created:=public.save_backoffice_sales_order_draft(
    NULL,NULL,gen_random_uuid(),v_payload);
  v_order_id:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order_id,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery_id:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id,sales_order_line_id INTO STRICT v_delivery_line_id,v_order_line_id
  FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery_id;
  SELECT master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery_id;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,
    gen_random_uuid(),jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line_id,'quantityUom',4)),
    'Mixed receipt fixture Dispatch');
  v_transit:=(v_dispatched->>'transitWarehouseId')::uuid;
  SELECT stock_qty INTO STRICT v_transit_before FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_transit AND product_id=v_product;
  SELECT master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery_id;

  v_disposition:=jsonb_build_array(jsonb_build_object(
    'deliveryLineId',v_delivery_line_id,'acceptedBaseQty',3,
    'discrepancies',jsonb_build_array(jsonb_build_object(
      'discrepancyType','SHORT','requestedResolution','BACKORDER',
      'physicalState','NOT_LOADED','quantityBase',1,
      'reason','Satu unit tidak terangkut'))));
  v_received:=public.receive_backoffice_sales_delivery(v_delivery_id,v_version,
    v_operation,v_today,v_disposition,'Mixed receipt rollback test');
  IF v_received->>'deliveryStatus'<>'IN_TRANSIT'
    OR (v_received->>'receivedBaseQty')::numeric<>3
    OR v_received->>'discrepancyStatus'<>'PENDING_WAREHOUSE_RESOLUTION'
    OR v_received->>'financialEventStatus'<>'HOLD' THEN
    RAISE EXCEPTION 'TEST_FAILED: mixed receipt result invalid %',v_received;
  END IF;
  v_retry:=public.receive_backoffice_sales_delivery(v_delivery_id,v_version,
    v_operation,v_today,v_disposition,'Mixed receipt rollback test');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR v_retry->>'receiptId'<>v_received->>'receiptId'
    OR v_retry->>'discrepancyId'<>v_received->>'discrepancyId' THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry changed mixed receipt identity';
  END IF;
  BEGIN
    PERFORM public.receive_backoffice_sales_delivery(v_delivery_id,v_version,
      v_operation,v_today,v_disposition,'Different retry payload');
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%IDEMPOTENCY_PAYLOAD_CONFLICT%';
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: changed retry payload accepted'; END IF;

  SELECT stock_qty INTO STRICT v_transit_after FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_transit AND product_id=v_product;
  IF v_transit_after<>v_transit_before-3 THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted-only Transit sale-out invalid % -> %',
      v_transit_before,v_transit_after;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=v_company AND delivery.id=v_delivery_id
        AND delivery.status='IN_TRANSIT' AND delivery.total_received_base_qty=3)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_order_id=v_order_id
        AND reservation.status='PARTIALLY_FULFILLED'
        AND reservation.total_in_transit_base_qty=1
        AND reservation.total_completed_base_qty=3)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=v_company AND line.id=v_order_line_id
        AND line.accepted_base_qty=3 AND line.to_invoice_base_qty=3)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
      WHERE line.company_id=v_company
        AND line.discrepancy_id=(v_received->>'discrepancyId')::uuid
        AND line.discrepancy_type='SHORT' AND line.requested_resolution='BACKORDER'
        AND line.physical_state='NOT_LOADED' AND line.quantity_base=1
        AND line.warehouse_resolution_status='PENDING') THEN
    RAISE EXCEPTION 'TEST_FAILED: mixed receipt operational ledger invalid';
  END IF;
  IF (SELECT COALESCE(sum(batch.qty_remaining),0)
      FROM public.backoffice_sales_receipt_fifo_allocations allocation
      JOIN public.product_batches batch ON batch.company_id=allocation.company_id
        AND batch.id=allocation.transit_batch_id
      WHERE allocation.company_id=v_company
        AND allocation.receipt_id=(v_received->>'receiptId')::uuid)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: discrepancy Transit FIFO quantity not preserved';
  END IF;

  -- Accepted qty is invoiceable although SO remains IN_TRANSIT.
  v_invoice:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),
    v_order_id,jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,
      'lines',jsonb_build_array(jsonb_build_object(
        'salesOrderLineId',v_order_line_id,'quantityUom',3,
        'unitPrice',50000,'discountAmount',0,'taxApplied',false))));
  IF v_invoice->'data'->>'id' IS NULL
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=v_company AND line.id=v_order_line_id
        AND line.draft_invoice_allocated_base_qty=3 AND line.to_invoice_base_qty=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted qty was not invoiceable while discrepancy open';
  END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before+1
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before
    OR (SELECT count(*) FROM public.backoffice_sales_invoices)<>v_invoice_before+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: mixed receipt created unexpected final effect';
  END IF;
  SELECT stock_qty INTO STRICT v_source_before_resolution FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  SELECT master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_discrepancies
  WHERE company_id=v_company AND id=(v_received->>'discrepancyId')::uuid;
  v_resolution:=public.resolve_backoffice_sales_shortage(
    (v_received->>'discrepancyId')::uuid,v_version,v_resolve_operation,NULL,
    'Rollback-only shortage resolution');
  IF v_resolution->>'status'<>'RESOLVED'
    OR COALESCE((v_resolution->>'exactRetry')::boolean,true)
    OR COALESCE((v_resolution->>'backorderCreated')::boolean,false) IS NOT TRUE
    OR v_resolution->>'backorderDeliveryOrderId' IS NULL
    OR v_resolution->>'backorderDeliveryNo' IS NULL
    OR (v_resolution->>'backorderScheduledDate')::date<>v_today THEN
    RAISE EXCEPTION 'TEST_FAILED: shortage resolution result invalid %',v_resolution;
  END IF;
  SELECT stock_qty INTO STRICT v_source_after_resolution FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  IF v_source_after_resolution<>v_source_before_resolution+1
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders child
      WHERE child.company_id=v_company
        AND child.id=(v_resolution->>'backorderDeliveryOrderId')::uuid
        AND child.parent_delivery_order_id=v_delivery_id
        AND child.delivery_kind='BACKORDER' AND child.status='READY'
        AND child.scheduled_date=v_today AND child.total_planned_base_qty=1)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders source
      WHERE source.company_id=v_company AND source.id=v_delivery_id
        AND source.status='COMPLETED')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_order_id=v_order_id
        AND reservation.status='PARTIALLY_FULFILLED'
        AND reservation.total_in_transit_base_qty=0
        AND reservation.total_completed_base_qty=3)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=v_order_id
        AND document.fulfillment_status='PREPARING')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=v_company
        AND effect.discrepancy_id=(v_received->>'discrepancyId')::uuid
        AND effect.effect_type='EXPECTED_RETURN_TO_SOURCE'
        AND effect.quantity_base=1 AND effect.stock_transfer_document_id IS NOT NULL)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_backorders backorder
      JOIN public.backoffice_sales_discrepancy_backorder_lines backorder_line
        ON backorder_line.company_id=backorder.company_id
       AND backorder_line.backorder_id=backorder.id
      WHERE backorder.company_id=v_company
        AND backorder.discrepancy_id=(v_received->>'discrepancyId')::uuid
        AND backorder_line.quantity_base=1) THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic shortage resolution ledger invalid';
  END IF;
  v_retry:=public.resolve_backoffice_sales_shortage(
    (v_received->>'discrepancyId')::uuid,v_version,v_resolve_operation,NULL,
    'Rollback-only shortage resolution');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR v_retry->>'backorderDeliveryOrderId'<>v_resolution->>'backorderDeliveryOrderId' THEN
    RAISE EXCEPTION 'TEST_FAILED: shortage resolution exact retry changed identity';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_shortage_resolution_runtime_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical Confirm and full Dispatch','accepted 3 of shipped 4',
    'shortage 1 remains exact Transit FIFO','commercial and physical facts separated',
    'DO and SO remain IN_TRANSIT','accepted 3 becomes Qty To Invoice',
    'Regular Draft Invoice allowed only against accepted quantity',
    'single COGS HOLD event and zero synchronous Journal','exact retry',
    'changed retry payload rejected','SHORT NOT_LOADED returns exact Transit FIFO','Backorder DO linked to parent and same SO','blank date defaults to Company today','resolution exact retry','all fixture writes rolled back']) details;
