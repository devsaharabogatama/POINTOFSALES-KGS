-- Authenticated rollback-only behavior for Sales Admin overage approval.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_customer_category uuid;v_fixture_code text;v_product_uom uuid;v_product uuid;
  v_original_negative boolean;v_today date;v_topup numeric;v_stock numeric;
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;
  v_approved jsonb;v_retry jsonb;v_payload jsonb;v_disposition jsonb;
  v_order_id uuid;v_order_line_id uuid;v_delivery_id uuid;v_delivery_line_id uuid;
  v_discrepancy_id uuid;v_overage_line_id uuid;v_default_overage_line_id uuid;v_version bigint;
  v_operation uuid:=gen_random_uuid();v_approval_operation uuid:=gen_random_uuid();
  v_batch_id uuid:=gen_random_uuid();v_failed boolean:=false;
  v_event_before bigint;v_movement_before bigint;v_invoice_before bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912100000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: overage commercial approval migration required';
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
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Backoffice Sales fixture missing';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
    AND NOT customer.is_system_customer ORDER BY customer.id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT category.id INTO v_customer_category FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.is_system_category DESC,category.id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Customer Category required';
    END IF;
    v_fixture_code:='OVRAPP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_created:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
      'Overage Approval Rollback Customer',v_customer_category,NULL,NULL,NULL,
      'BUSINESS',0,NULL,'Rollback-only overage approval fixture',TRUE,NULL,NULL);
    v_customer:=(v_created->>'customerId')::uuid;
  END IF;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  -- Rollback-only setup; clear marker before exercising operational authority.
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
  SELECT COALESCE(stock_qty,0) INTO v_stock FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_stock:=COALESCE(v_stock,0);v_topup:=CASE WHEN v_stock<10 THEN 10-v_stock ELSE 10 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=clock_timestamp();
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch_id,v_product,v_warehouse,v_topup,v_topup,
    GREATEST(COALESCE(product.cogs,1),1),v_company
  FROM public.products product WHERE product.company_id=v_company AND product.id=v_product;

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
      'quantity',4,'overrideUnitPrice',50000,'lineDiscountType','PERCENT',
      'lineDiscountInput',10)));
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_order_id:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order_id,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery_id:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id,sales_order_line_id INTO STRICT v_delivery_line_id,v_order_line_id
  FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery_id;
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery_id;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,
    gen_random_uuid(),jsonb_build_array(jsonb_build_object(
      'deliveryLineId',v_delivery_line_id,'quantityUom',4)),'Overage approval test');
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery_id;
  v_disposition:=jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line_id,
    'acceptedBaseQty',3,'discrepancies',jsonb_build_array(
      jsonb_build_object('discrepancyType','SHORT','requestedResolution','BACKORDER',
        'physicalState','NOT_LOADED','quantityBase',1,'reason','Expected shortage'),
      jsonb_build_object('discrepancyType','OVERAGE','requestedResolution','ACCEPT_OVERAGE',
        'quantityBase',0.5,'reason','Default commercial half unit'),
      jsonb_build_object('discrepancyType','OVERAGE','requestedResolution','ACCEPT_OVERAGE',
        'quantityBase',0.5,'reason','Adjusted commercial half unit'))));
  v_received:=public.receive_backoffice_sales_delivery(v_delivery_id,v_version,
    v_operation,v_today,v_disposition,'Overage approval rollback test');
  v_discrepancy_id:=(v_received->>'discrepancyId')::uuid;
  IF v_received->>'discrepancyStatus'<>'PENDING_SALES_APPROVAL' THEN
    RAISE EXCEPTION 'TEST_FAILED: overage did not enter Sales approval %',v_received;
  END IF;
  SELECT id INTO STRICT v_overage_line_id
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE company_id=v_company AND discrepancy_id=v_discrepancy_id
    AND reason='Adjusted commercial half unit';
  SELECT id INTO STRICT v_default_overage_line_id
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE company_id=v_company AND discrepancy_id=v_discrepancy_id
    AND reason='Default commercial half unit';
  SELECT master_version INTO STRICT v_version
  FROM public.backoffice_sales_delivery_discrepancies
  WHERE company_id=v_company AND id=v_discrepancy_id;
  -- Baseline immediately before approval: the assertion below measures only
  -- approval effects and does not guess how many movements Dispatch/Receipt use.
  SELECT count(*) INTO v_event_before FROM public.financial_events;
  SELECT count(*) INTO v_movement_before FROM public.stock_movements;
  SELECT count(*) INTO v_invoice_before FROM public.backoffice_sales_invoices;
  BEGIN
    PERFORM public.approve_backoffice_sales_delivery_overage(v_discrepancy_id,
      v_version+1,gen_random_uuid(),jsonb_build_object('lines',jsonb_build_array(
        jsonb_build_object('discrepancyLineId',v_default_overage_line_id),
        jsonb_build_object('discrepancyLineId',v_overage_line_id,
          'unitPrice',60000,'discountAmount',5000,'taxApplied',false))),NULL);
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale approval version accepted'; END IF;
  v_failed:=false;

  v_approved:=public.approve_backoffice_sales_delivery_overage(v_discrepancy_id,
    v_version,v_approval_operation,jsonb_build_object('lines',jsonb_build_array(
      jsonb_build_object('discrepancyLineId',v_default_overage_line_id),
      jsonb_build_object('discrepancyLineId',v_overage_line_id,
        'unitPrice',60000,'discountAmount',5000,'taxApplied',false))),
    'Sales Admin adjusted the inherited commercial values');
  IF v_approved->>'status'<>'PENDING_WAREHOUSE_RESOLUTION'
    OR (v_approved->>'masterVersion')::bigint<>v_version+1
    OR (v_approved->>'approvedLineCount')::bigint<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: approval result invalid %',v_approved;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.id=v_overage_line_id
      AND line.commercial_approval_status='APPROVED'
      AND line.approved_unit_price=60000 AND line.approved_discount_amount=5000
      AND line.approved_tax_amount=0 AND line.approved_line_total=25000
      AND line.commercial_snapshot->>'defaultAuthority'='SALES_ORDER'
      AND (line.commercial_snapshot->>'adjustedBySalesAdmin')::boolean) THEN
    RAISE EXCEPTION 'TEST_FAILED: approved commercial snapshot invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.id=v_default_overage_line_id
      AND line.commercial_approval_status='APPROVED'
      AND line.approved_unit_price=50000 AND line.approved_discount_amount=2500
      AND line.approved_line_total=22500
      AND line.commercial_snapshot->>'defaultAuthority'='SALES_ORDER'
      AND NOT (line.commercial_snapshot->>'adjustedBySalesAdmin')::boolean) THEN
    RAISE EXCEPTION 'TEST_FAILED: SO-default commercial values were not preserved';
  END IF;
  v_retry:=public.approve_backoffice_sales_delivery_overage(v_discrepancy_id,
    v_version,v_approval_operation,jsonb_build_object('lines',jsonb_build_array(
      jsonb_build_object('discrepancyLineId',v_default_overage_line_id),
      jsonb_build_object('discrepancyLineId',v_overage_line_id,
        'unitPrice',60000,'discountAmount',5000,'taxApplied',false))),
    'Sales Admin adjusted the inherited commercial values');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: exact approval retry not recognized';
  END IF;
  v_failed:=false;
  BEGIN
    PERFORM public.approve_backoffice_sales_delivery_overage(v_discrepancy_id,
      v_version,v_approval_operation,jsonb_build_object('lines',jsonb_build_array(
        jsonb_build_object('discrepancyLineId',v_default_overage_line_id),
        jsonb_build_object('discrepancyLineId',v_overage_line_id,
          'unitPrice',61000,'discountAmount',5000,'taxApplied',false))),NULL);
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%IDEMPOTENCY_PAYLOAD_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: changed approval retry accepted'; END IF;
  IF (SELECT count(*) FROM public.financial_events)<>v_event_before
    OR (SELECT count(*) FROM public.stock_movements)<>v_movement_before
    OR (SELECT count(*) FROM public.backoffice_sales_invoices)<>v_invoice_before THEN
    RAISE EXCEPTION 'TEST_FAILED: approval created a physical, Invoice, or extra Finance effect';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_overage_commercial_approval_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'mixed shortage plus accepted overage','SO commercial defaults preserved',
    'Sales Admin explicit commercial adjustment','optimistic version','exact retry',
    'changed retry rejected','immutable operation/audit','zero approval Stock/Invoice/Finance effect',
    'all fixture writes rolled back']) details;
