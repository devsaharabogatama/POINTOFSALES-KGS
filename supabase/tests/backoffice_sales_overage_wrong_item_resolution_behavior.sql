-- Authenticated rollback-only behavior for Step 4/6.5C3.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_customer_category uuid;v_fixture_code text;v_today date;v_original_negative boolean;
  v_category uuid;v_uom uuid;v_master_result jsonb;v_suffix text;
  v_pu uuid[]:='{}';v_products uuid[]:='{}';v_uoms uuid[]:='{}';v_item record;
  v_topup numeric;v_stock numeric;v_batch uuid;v_movement uuid;
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;
  v_approved jsonb;v_resolved jsonb;v_retry jsonb;v_payload jsonb;v_disposition jsonb;
  v_order uuid;v_delivery uuid;v_line_a uuid;v_line_b uuid;v_order_line_a uuid;
  v_discrepancy uuid;v_accept_line uuid;v_return_line uuid;v_wrong_line uuid;
  v_version bigint;v_event_before bigint;v_operation uuid:=gen_random_uuid();
  v_failed boolean:=false;v_line_no integer;v_split boolean;v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912132000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: C3 kind/catalog forward-fixes required';
  END IF;
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912137000') INTO v_split;
  SELECT pg_get_functiondef('private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'::regprocedure)
    INTO v_definition;
  IF (position('accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now' in v_definition)>0)
    IS DISTINCT FROM (NOT v_split) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: resolver ledger stage differs from installed migration';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_original_negative,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='STOCK_TRANSFER'
        AND category.is_active AND category.is_system_default)
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='SALE_POSTED'
        AND category.is_active)
  ORDER BY company.id,store.id,warehouse.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Company, Store and sale Warehouse required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  -- Rollback-only Office setup; never keep the setup marker across runtime RPCs.
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
  v_suffix:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  SELECT category.id INTO v_category FROM public.product_categories category
  WHERE category.company_id=v_company AND category.is_active ORDER BY category.id LIMIT 1;
  IF v_category IS NULL THEN
    v_master_result:=public.save_inventory_product_category(NULL,NULL,
      ('C3 Rollback Category '||v_suffix)::text,true);
    v_category:=(v_master_result->'data'->>'id')::uuid;
  END IF;
  v_master_result:=public.save_inventory_uom(NULL::uuid,NULL::bigint,
    ('C3 Unit '||v_suffix)::text,'UNIT'::text,false,0::smallint,true);
  v_uom:=(v_master_result->'data'->>'id')::uuid;
  FOR v_line_no IN 1..3 LOOP
    v_master_result:=public.save_product_with_uoms(NULL::uuid,NULL::bigint,
      ('C3-'||v_suffix||'-'||v_line_no)::text,
      ('C3 Rollback Product '||v_line_no)::text,v_category,v_uom,v_uom,
      1::numeric,false,NULL::text,true,jsonb_build_array(jsonb_build_object(
        'uomId',v_uom,'factorToBase',1,'purchaseAllowed',true,'salesAllowed',true,
        'purchasePrice',10000*v_line_no,'salePrice',15000*v_line_no,'isActive',true)));
    v_products:=array_append(v_products,(v_master_result->>'productId')::uuid);
    SELECT product_uom.id INTO STRICT v_batch FROM public.product_uoms product_uom
    WHERE product_uom.company_id=v_company
      AND product_uom.product_id=(v_master_result->>'productId')::uuid
      AND product_uom.uom_id=v_uom;
    v_pu:=array_append(v_pu,v_batch);v_uoms:=array_append(v_uoms,v_uom);
  END LOOP;
  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active AND NOT customer.is_system_customer
  ORDER BY customer.id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT category.id INTO v_customer_category FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.is_system_category DESC,category.id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Customer Category required';
    END IF;
    v_fixture_code:='C3-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_created:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
      'C3 Rollback Customer',v_customer_category,NULL,NULL,NULL,'BUSINESS',0,NULL,
      'Rollback-only C3 fixture',TRUE,NULL,NULL);
    v_customer:=(v_created->>'customerId')::uuid;
  END IF;

  FOR v_item IN SELECT product_id FROM unnest(v_products) AS product(product_id) LOOP
    SELECT COALESCE(stock.stock_qty,0) INTO v_stock FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND stock.warehouse_id=v_warehouse
      AND stock.product_id=v_item.product_id;
    v_stock:=COALESCE(v_stock,0);v_topup:=CASE WHEN v_stock<20 THEN 20-v_stock ELSE 10 END;
    INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
    VALUES(v_item.product_id,v_warehouse,v_topup,v_company)
    ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
      stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=clock_timestamp();
    v_batch:=gen_random_uuid();v_movement:=gen_random_uuid();
    INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
      qty_remaining,cogs_unit,company_id)
    SELECT v_batch,v_item.product_id,v_warehouse,v_topup,v_topup,
      GREATEST(COALESCE(product.cogs,1),1),v_company
    FROM public.products product WHERE product.company_id=v_company AND product.id=v_item.product_id;
    SELECT stock_qty INTO STRICT v_stock FROM public.product_stocks
    WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_item.product_id;
    INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    SELECT v_movement,v_item.product_id,v_warehouse,v_topup,
      'PURCHASE'::public.stock_movement_type,'BACKOFFICE_C3_TEST',v_batch,v_company,
      product.uom_id,uom.name,v_stock,v_actor,clock_timestamp(),'POSTED',v_batch,
      'Rollback-only C3 stock fixture'
    FROM public.products product JOIN public.uoms uom
      ON uom.company_id=product.company_id AND uom.id=product.uom_id
    WHERE product.company_id=v_company AND product.id=v_item.product_id;
  END LOOP;

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(
      jsonb_build_object('productUomId',v_pu[1],'quantity',4,'overrideUnitPrice',50000),
      jsonb_build_object('productUomId',v_pu[2],'quantity',2,'overrideUnitPrice',30000)));
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT delivery_line.id,delivery_line.sales_order_line_id INTO STRICT v_line_a,v_order_line_a
  FROM public.backoffice_sales_delivery_order_lines delivery_line
  WHERE delivery_line.company_id=v_company AND delivery_line.delivery_order_id=v_delivery
    AND delivery_line.product_id=v_products[1];
  SELECT delivery_line.id INTO STRICT v_line_b
  FROM public.backoffice_sales_delivery_order_lines delivery_line
  WHERE delivery_line.company_id=v_company AND delivery_line.delivery_order_id=v_delivery
    AND delivery_line.product_id=v_products[2];
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_line_a,'quantityUom',4),
      jsonb_build_object('deliveryLineId',v_line_b,'quantityUom',2)),'C3 rollback Dispatch');
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_disposition:=jsonb_build_array(
    jsonb_build_object('deliveryLineId',v_line_a,'acceptedBaseQty',4,
      'discrepancies',jsonb_build_array(
        jsonb_build_object('discrepancyType','OVERAGE','requestedResolution','ACCEPT_OVERAGE',
          'quantityBase',1,'reason','C3 accepted extra'),
        jsonb_build_object('discrepancyType','OVERAGE','requestedResolution','RETURN_OVERAGE',
          'quantityBase',1,'reason','C3 returned extra'))),
    jsonb_build_object('deliveryLineId',v_line_b,'acceptedBaseQty',1,
      'discrepancies',jsonb_build_array(
        jsonb_build_object('discrepancyType','WRONG_ITEM',
          'requestedResolution','REPLACE_WRONG_ITEM','quantityBase',1,
          'actualProductId',v_products[3],'actualUomId',v_uoms[3],
          'actualQuantityUom',1,'actualQuantityBase',1,'reason','C3 wrong item'))));
  v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,
    gen_random_uuid(),v_today,v_disposition,'C3 mixed receipt');
  v_discrepancy:=(v_received->>'discrepancyId')::uuid;
  IF v_received->>'discrepancyStatus'<>'PENDING_SALES_APPROVAL' THEN
    RAISE EXCEPTION 'TEST_FAILED: mixed C3 case did not require Sales approval %',v_received;
  END IF;
  SELECT id INTO STRICT v_accept_line FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE company_id=v_company AND discrepancy_id=v_discrepancy
    AND requested_resolution='ACCEPT_OVERAGE';
  SELECT id INTO STRICT v_return_line FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE company_id=v_company AND discrepancy_id=v_discrepancy
    AND requested_resolution='RETURN_OVERAGE';
  SELECT id INTO STRICT v_wrong_line FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE company_id=v_company AND discrepancy_id=v_discrepancy
    AND requested_resolution='REPLACE_WRONG_ITEM';
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_discrepancies
  WHERE company_id=v_company AND id=v_discrepancy;
  v_approved:=public.approve_backoffice_sales_delivery_overage(v_discrepancy,v_version,
    gen_random_uuid(),jsonb_build_object('lines',jsonb_build_array(
      jsonb_build_object('discrepancyLineId',v_accept_line))),
    'C3 default SO commercial approval');
  v_version:=(v_approved->>'masterVersion')::bigint;
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  BEGIN
    PERFORM public.resolve_backoffice_sales_overage_wrong_item(v_discrepancy,
      v_version+1,gen_random_uuid(),NULL,'C3 stale version');
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale C3 version accepted'; END IF;
  v_resolved:=public.resolve_backoffice_sales_overage_wrong_item(v_discrepancy,
    v_version,v_operation,NULL,'C3 Warehouse resolution');
  IF v_resolved->>'status'<>'RESOLVED'
    OR COALESCE((v_resolved->>'correctionCreated')::boolean,false) IS NOT TRUE
    OR v_resolved->>'replacementScheduledDate'<>v_today::text
    OR v_resolved->>'salesOrderFulfillmentStatus'<>'PREPARING' THEN
    RAISE EXCEPTION 'TEST_FAILED: C3 result invalid %',v_resolved;
  END IF;
  v_retry:=public.resolve_backoffice_sales_overage_wrong_item(v_discrepancy,
    v_version,v_operation,NULL,'C3 Warehouse resolution');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR v_retry->>'correctionDeliveryOrderId'<>v_resolved->>'correctionDeliveryOrderId' THEN
    RAISE EXCEPTION 'TEST_FAILED: exact C3 retry changed identity';
  END IF;
  v_failed:=false;
  BEGIN
    PERFORM public.resolve_backoffice_sales_overage_wrong_item(v_discrepancy,
      v_version,v_operation,v_today+1,'Changed C3 payload');
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%IDEMPOTENCY_PAYLOAD_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: changed C3 retry accepted'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
      WHERE line.company_id=v_company AND line.id=v_accept_line
        AND line.warehouse_resolution_status='RESOLVED'
        AND line.accepted_overage_base_qty=1 AND line.overage_to_invoice_base_qty=1)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=v_company AND line.id=v_order_line_a
        AND line.accepted_base_qty=CASE WHEN v_split THEN 4 ELSE 5 END
        AND line.approved_overage_base_qty=1
        AND line.to_invoice_base_qty=CASE WHEN v_split THEN 4 ELSE 5 END)
    OR (SELECT line.to_invoice_base_qty+discrepancy.overage_to_invoice_base_qty
        FROM public.backoffice_sales_order_lines line
        JOIN public.backoffice_sales_delivery_discrepancy_lines discrepancy
          ON discrepancy.company_id=line.company_id
         AND discrepancy.sales_order_line_id=line.id
        WHERE line.company_id=v_company AND line.id=v_order_line_a
          AND discrepancy.id=v_accept_line)<>(CASE WHEN v_split THEN 5 ELSE 6 END) THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted overage ledger does not match installed stage';
  END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before+1
    OR NOT EXISTS(SELECT 1 FROM public.financial_events event
      JOIN public.transaction_categories category
        ON category.company_id=event.company_id AND category.id=event.transaction_category_id
      JOIN public.posting_rule_sets rule_set ON rule_set.company_id=event.company_id
        AND rule_set.transaction_category_id=event.transaction_category_id
        AND rule_set.system_key=event.system_event_key
        AND rule_set.rule_set_version=event.transaction_rule_version
      WHERE event.company_id=v_company AND event.system_event_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
        AND category.system_key='BACKOFFICE_ACCEPTED_OVERAGE_COGS'
        AND event.source_table='backoffice_sales_discrepancy_stock_effects'
        AND event.status='HOLD'::public.event_status
        AND event.amounts->>'discrepancyLineId'=v_accept_line::text) THEN
    RAISE EXCEPTION 'TEST_FAILED: separate accepted-overage COGS event invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=v_company AND effect.discrepancy_line_id=v_return_line
        AND effect.effect_type='OVERAGE_TO_TRANSIT')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=v_company AND effect.discrepancy_line_id=v_return_line
        AND effect.effect_type='OVERAGE_RETURN_TO_SOURCE') THEN
    RAISE EXCEPTION 'TEST_FAILED: return-overage Stock lineage incomplete';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=v_company AND effect.discrepancy_line_id=v_wrong_line
        AND effect.effect_type='ACTUAL_TO_TRANSIT')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=v_company AND effect.discrepancy_line_id=v_wrong_line
        AND effect.effect_type='ACTUAL_RETURN_TO_SOURCE')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=v_company AND effect.discrepancy_line_id=v_wrong_line
        AND effect.effect_type='EXPECTED_RETURN_TO_SOURCE')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_backorder_lines child
      JOIN public.backoffice_sales_discrepancy_backorders header
        ON header.company_id=child.company_id AND header.id=child.backorder_id
      JOIN public.backoffice_sales_delivery_orders delivery
        ON delivery.company_id=header.company_id AND delivery.id=header.backorder_delivery_order_id
      WHERE child.company_id=v_company AND child.discrepancy_line_id=v_wrong_line
        AND child.quantity_base=1 AND header.resolution_kind='WRONG_ITEM_CORRECTION'
        AND delivery.delivery_kind='BACKORDER' AND delivery.status='READY'
        AND delivery.scheduled_date=v_today) THEN
    RAISE EXCEPTION 'TEST_FAILED: Wrong Item correction lineage incomplete';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
    JOIN public.backoffice_sales_discrepancy_stock_effects effect
      ON effect.company_id=allocation.company_id AND effect.id=allocation.stock_effect_id
    JOIN public.backoffice_sales_delivery_discrepancy_lines line
      ON line.company_id=effect.company_id AND line.id=effect.discrepancy_line_id
    WHERE effect.company_id=v_company
      AND effect.discrepancy_line_id IN(v_return_line,v_wrong_line)
      AND effect.effect_type IN('OVERAGE_RETURN_TO_SOURCE','ACTUAL_RETURN_TO_SOURCE',
        'EXPECTED_RETURN_TO_SOURCE')
      AND NOT EXISTS(
        SELECT 1 FROM public.stock_transfer_fifo_allocations source_allocation
        JOIN public.stock_transfer_lines source_line
          ON source_line.company_id=source_allocation.company_id
         AND source_line.id=source_allocation.line_id
        WHERE source_allocation.company_id=allocation.company_id
          AND source_allocation.destination_batch_id=allocation.source_batch_id
          AND ((effect.effect_type='OVERAGE_RETURN_TO_SOURCE'
                AND source_line.document_id=(SELECT source_effect.stock_transfer_document_id
                  FROM public.backoffice_sales_discrepancy_stock_effects source_effect
                  WHERE source_effect.company_id=effect.company_id
                    AND source_effect.discrepancy_line_id=effect.discrepancy_line_id
                    AND source_effect.effect_type='OVERAGE_TO_TRANSIT'))
            OR (effect.effect_type='ACTUAL_RETURN_TO_SOURCE'
                AND source_line.document_id=(SELECT source_effect.stock_transfer_document_id
                  FROM public.backoffice_sales_discrepancy_stock_effects source_effect
                  WHERE source_effect.company_id=effect.company_id
                    AND source_effect.discrepancy_line_id=effect.discrepancy_line_id
                    AND source_effect.effect_type='ACTUAL_TO_TRANSIT'))
            OR (effect.effect_type='EXPECTED_RETURN_TO_SOURCE'
                AND source_line.document_id IN(SELECT dispatch.stock_transfer_document_id
                  FROM public.backoffice_sales_delivery_dispatches dispatch
                  WHERE dispatch.company_id=line.company_id
                    AND dispatch.delivery_order_id=line.delivery_order_id))))) THEN
    RAISE EXCEPTION 'TEST_FAILED: C3 Return consumed FIFO from another source transfer';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=v_company AND delivery.id=v_delivery AND delivery.status='COMPLETED')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancies discrepancy
      WHERE discrepancy.company_id=v_company AND discrepancy.id=v_discrepancy
        AND discrepancy.status='RESOLVED') THEN
    RAISE EXCEPTION 'TEST_FAILED: source DO/discrepancy final state invalid';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912137000')
  THEN 'backoffice_sales_overage_wrong_item_resolution_behavior'
  ELSE 'backoffice_sales_overage_wrong_item_historical_pre_split_behavior' END check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical two-line SO and full Dispatch','mixed Customer receipt',
    'Sales approval default commercial snapshot','stale version rejected',
    'accepted overage becomes separate Qty To Invoice','separate COGS event remains HOLD',
    'return overage reconstructs and returns exact Stock','Wrong Item actual and expected Stock corrected',
    'Wrong Item creates linked correction DO/SJ','Company-date default',
    'exact retry and changed-payload conflict','all fixture writes rolled back'],
    'finalLedgerSplitVerified',EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912137000'),
    'historicalBoundary','Pre-split PASS is physical resolution evidence only, NOT final Invoice ledger compatibility') details;
