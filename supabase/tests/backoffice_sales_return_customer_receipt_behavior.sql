-- Authenticated rollback-only behavior for Backoffice Customer Return Receipt.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_other_company uuid:=gen_random_uuid();v_store uuid;
  v_warehouse uuid;v_customer uuid;v_product_uom uuid;v_product uuid;v_today date;
  v_original_negative boolean;v_topup numeric;v_stock numeric;v_stock_before_return numeric;
  v_batch uuid:=gen_random_uuid();v_fixture_movement uuid:=gen_random_uuid();
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;
  v_order uuid;v_order_line uuid;v_delivery uuid;v_delivery_line uuid;v_version bigint;
  v_return_result jsonb;v_return uuid;v_return_line uuid;v_receipt jsonb;v_retry jsonb;
  v_operation uuid:=gen_random_uuid();v_payload jsonb;v_failed boolean;
  v_event_before bigint;v_journal_before bigint;v_invoice_before bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917122000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Customer Return Receipt reject-only audit guard forward-fix required';
  END IF;
  IF (SELECT count(*) FROM pg_trigger trigger_state
      WHERE trigger_state.tgrelid='public.backoffice_sales_return_receipt_audit'::regclass
        AND trigger_state.tgname='backoffice_sales_return_receipt_audit_immutable'
        AND NOT trigger_state.tgisinternal AND trigger_state.tgenabled='A'
        AND trigger_state.tgfoid=to_regprocedure(
          'private.trg_reject_backoffice_sales_return_receipt_history_mutation()'))<>1 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Return Receipt reject-only audit guard runtime drift';
  END IF;
  SELECT profile.id INTO STRICT v_actor FROM auth.users auth_user
  JOIN public.profiles profile ON profile.id=auth_user.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    customer.id,product_uom.id,product_uom.product_id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_company,v_store,v_warehouse,v_original_negative,v_customer,
    v_product_uom,v_product,v_today
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
    AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
      WHERE setting.company_id=company.id)
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

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  UPDATE public.warehouses SET allow_negative_stock=true
    WHERE company_id=v_company AND id=v_warehouse;

  SELECT COALESCE(stock_qty,0) INTO v_stock FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_stock:=COALESCE(v_stock,0);v_topup:=CASE WHEN v_stock<10 THEN 10-v_stock ELSE 10 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=clock_timestamp()
  RETURNING stock_qty INTO v_stock;
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch,v_product,v_warehouse,v_topup,v_topup,GREATEST(COALESCE(product.cogs,1),1),v_company
  FROM public.products product WHERE product.company_id=v_company AND product.id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_fixture_movement,v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_RETURN_RECEIPT_TEST',v_batch,
    v_company,product.uom_id,uom.name,v_stock,v_actor,clock_timestamp(),
    'POSTED',v_batch,'Rollback-only Return receipt fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_product;

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,'quantity',4)));
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id,sales_order_line_id INTO STRICT v_delivery_line,v_order_line
  FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery;
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery,v_version,
    gen_random_uuid(),jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line,'quantityUom',4)),'Return fixture Dispatch');
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,
    gen_random_uuid(),v_today,'Return fixture Customer accepted');

  v_return_result:=public.save_backoffice_sales_return_draft(NULL,NULL,
    gen_random_uuid(),v_order,jsonb_build_object('reason','Customer Return Receipt test',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',2,'reason','Split disposition test'))));
  v_return:=(v_return_result->'data'->>'id')::uuid;
  v_return_result:=public.submit_backoffice_sales_return(v_return,
    (v_return_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_return_result:=public.approve_backoffice_sales_return(v_return,
    (v_return_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
  WHERE company_id=v_company AND return_id=v_return;

  SELECT stock_qty INTO STRICT v_stock_before_return FROM public.product_stocks
  WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;
  SELECT count(*) INTO v_invoice_before FROM public.backoffice_sales_invoices;

  v_failed:=false;
  BEGIN
    PERFORM public.post_backoffice_sales_return_receipt(v_return,
      (v_return_result->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today,
      jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,
        'quantityUom',1,'warehouseId',v_warehouse,'disposition','DESTROY')),NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%BACKOFFICE_SALES_RETURN_RECEIPT_LINE_INVALID%';
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: DESTROY without note accepted'; END IF;

  v_failed:=false;
  BEGIN
    PERFORM public.post_backoffice_sales_return_receipt(v_return,
      (v_return_result->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today+1,
      jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,
        'quantityUom',1,'warehouseId',v_warehouse,'disposition','RESTOCK')),NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%BACKOFFICE_SALES_RETURN_RECEIPT_DATE_FUTURE%';
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: future receipt date accepted'; END IF;

  v_receipt:=public.post_backoffice_sales_return_receipt(v_return,
    (v_return_result->'data'->>'masterVersion')::bigint,v_operation,v_today,
    jsonb_build_array(
      jsonb_build_object('returnLineId',v_return_line,'quantityUom',1,
        'warehouseId',v_warehouse,'disposition','RESTOCK','notes','Layak dijual kembali'),
      jsonb_build_object('returnLineId',v_return_line,'quantityUom',1,
        'warehouseId',v_warehouse,'disposition','DESTROY','notes','Rusak dan dihancurkan')),
    'Split disposition rollback-only test');
  v_retry:=public.post_backoffice_sales_return_receipt(v_return,
    (v_return_result->'data'->>'masterVersion')::bigint,v_operation,v_today,
    jsonb_build_array(
      jsonb_build_object('returnLineId',v_return_line,'quantityUom',1,
        'warehouseId',v_warehouse,'disposition','RESTOCK','notes','Layak dijual kembali'),
      jsonb_build_object('returnLineId',v_return_line,'quantityUom',1,
        'warehouseId',v_warehouse,'disposition','DESTROY','notes','Rusak dan dihancurkan')),
    'Split disposition rollback-only test');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR v_retry->>'receiptId'<>v_receipt->>'receiptId' THEN
    RAISE EXCEPTION 'TEST_FAILED: receipt exact retry changed identity';
  END IF;

  SELECT stock_qty INTO STRICT v_stock FROM public.product_stocks
  WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;
  IF v_stock<>v_stock_before_return+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: split disposition On Hand invalid % -> %',v_stock_before_return,v_stock;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_returns document
      WHERE document.company_id=v_company AND document.id=v_return
        AND document.status='RECEIVED' AND document.total_received_base_qty=2
        AND document.total_restocked_base_qty=1 AND document.total_destroyed_base_qty=1)
    OR (SELECT count(*) FROM public.backoffice_sales_return_receipt_lines line
      WHERE line.company_id=v_company AND line.receipt_id=(v_receipt->>'receiptId')::uuid)<>2
    OR (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='backoffice_sales_return_receipts'
        AND movement.reference_id=(v_receipt->>'receiptId')::uuid)<>1
    OR (SELECT sum(restoration.quantity_base)
      FROM public.backoffice_sales_return_receipt_fifo_restorations restoration
      WHERE restoration.company_id=v_company
        AND restoration.receipt_id=(v_receipt->>'receiptId')::uuid)<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: Return Receipt reconciliation invalid';
  END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before
    OR (SELECT count(*) FROM public.backoffice_sales_invoices)<>v_invoice_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Step 2 changed Invoice or Finance';
  END IF;

  v_failed:=false;
  BEGIN
    PERFORM public.post_backoffice_sales_return_receipt(v_return,
      (v_return_result->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today,
      jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,
        'quantityUom',1,'warehouseId',v_warehouse,'disposition','RESTOCK')),NULL);
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale receipt version accepted'; END IF;

  INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
  VALUES(v_other_company,'CRR'||left(replace(v_other_company::text,'-',''),8),
    'Rollback Customer Return Tenant','crr-'||replace(v_other_company::text,'-',''),'ACTIVE');
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_other_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  UPDATE public.user_active_company_contexts SET company_id=v_other_company,
    selected_at=clock_timestamp(),updated_at=clock_timestamp() WHERE user_id=v_actor;
  v_failed:=false;
  BEGIN
    PERFORM public.post_backoffice_sales_return_receipt(v_return,1,gen_random_uuid(),v_today,
      jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,
        'quantityUom',1,'warehouseId',v_warehouse,'disposition','RESTOCK')),NULL);
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%BACKOFFICE_SALES_RETURN_NOT_FOUND%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company Return receipt accepted'; END IF;
  UPDATE public.user_active_company_contexts SET company_id=v_company,
    selected_at=clock_timestamp(),updated_at=clock_timestamp() WHERE user_id=v_actor;

  IF (SELECT count(*) FROM public.backoffice_sales_return_receipt_audit
      WHERE company_id=v_company AND receipt_id=(v_receipt->>'receiptId')::uuid)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Return Receipt audit row missing or duplicated';
  END IF;
  v_failed:=false;
  BEGIN
    UPDATE public.backoffice_sales_return_receipt_audit SET after_state='{}'::jsonb
    WHERE company_id=v_company AND receipt_id=(v_receipt->>'receiptId')::uuid;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%BACKOFFICE_SALES_RETURN_RECEIPT_HISTORY_IMMUTABLE%' THEN
      v_failed:=true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: Return Receipt audit mutable'; END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_return_customer_receipt_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical SO Dispatch and Customer acceptance','approved Return source',
    'split RESTOCK and DESTROY on one Product','DESTROY note required and no photo/second approval',
    'original Customer Receipt FIFO lineage','RESTOCK-only On Hand increase',
    'future date and stale version rejection','exact retry','cross-Company denial',
    'immutable audit','zero Invoice, Financial Event and Journal effect',
    'all fixture writes rolled back']) details;
