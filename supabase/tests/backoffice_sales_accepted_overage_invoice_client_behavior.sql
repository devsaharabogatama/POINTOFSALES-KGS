-- Authenticated rollback-only behavior for Step 4/6.5C2C.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_customer_category uuid;v_product_uom uuid;v_product uuid;v_uom uuid;v_factor numeric;
  v_today date;v_created jsonb;v_confirmed jsonb;v_invoice jsonb;v_workspace jsonb;v_detail jsonb;
  v_order uuid;v_order_line uuid;v_delivery uuid;v_delivery_line uuid;
  v_case uuid:=gen_random_uuid();v_case_line uuid:=gen_random_uuid();v_fixture_code text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912125000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: C2C client read-model required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,product_uom.id,product_uom.product_id,
    product_uom.uom_id,product_uom.factor_to_base,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_product_uom,v_product,v_uom,v_factor,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
        AND (clock_timestamp() AT TIME ZONE company.timezone)::date
          BETWEEN period.start_date AND period.end_date)
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      JOIN public.transaction_account_rules rule ON rule.company_id=category.company_id
        AND rule.transaction_category_id=category.id AND rule.status='ACTIVE'
      WHERE category.company_id=company.id AND category.is_active
        AND category.system_key='BACKOFFICE_SALES_INVOICE')
  ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Company/Sales/Finance fixture required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  -- Rollback-only setup; runtime root-creation guard remains active for RPCs.
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
  SELECT id INTO v_customer FROM public.customers
  WHERE company_id=v_company AND is_active ORDER BY is_system_customer,id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT id INTO v_customer_category FROM public.customer_categories
    WHERE company_id=v_company AND is_active ORDER BY is_system_category DESC,id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Customer Category required';
    END IF;
    v_fixture_code:='C2C-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_created:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
      'C2C Rollback Customer',v_customer_category,NULL,NULL,NULL,'BUSINESS',0,NULL,
      'Rollback-only accepted overage Invoice client fixture',TRUE,NULL,NULL);
    v_customer:=(v_created->>'customerId')::uuid;
  END IF;
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
      'selectedPricelistId',NULL,'orderDate',v_today,'plannedDeliveryDate',v_today,
      'isTempo',false,'currencyCode','IDR','globalDiscount',0,
      'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
        'quantity',1,'overrideUnitPrice',10000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id,sales_order_line_id INTO STRICT v_delivery_line,v_order_line
  FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery;
  -- Synthetic resolved source: read-model proof, NOT physical receipt/UI smoke.
  UPDATE public.backoffice_sales_orders SET fulfillment_status='COMPLETED'
  WHERE company_id=v_company AND id=v_order;
  INSERT INTO public.backoffice_sales_delivery_discrepancies(id,company_id,discrepancy_no,
    delivery_order_id,sales_order_id,status,total_discrepancy_base_qty,
    requires_sales_approval,requires_warehouse_resolution,created_by,updated_by,
    resolved_by,resolved_at)
  VALUES(v_case,v_company,'DSP-C2C-'||upper(substr(replace(v_case::text,'-',''),1,12)),
    v_delivery,v_order,'RESOLVED',3*v_factor,true,true,v_actor,v_actor,v_actor,clock_timestamp());
  INSERT INTO public.backoffice_sales_delivery_discrepancy_lines(id,company_id,discrepancy_id,
    delivery_order_id,sales_order_id,delivery_order_line_id,sales_order_line_id,
    expected_product_id,uom_id,discrepancy_type,requested_resolution,quantity_uom,
    quantity_base,commercial_approval_status,warehouse_resolution_status,reason,
    approved_unit_price,approved_discount_amount,approved_tax_amount,approved_line_total,
    commercial_snapshot,commercial_approved_by,commercial_approved_at,accepted_overage_base_qty)
  VALUES(v_case_line,v_company,v_case,v_delivery,v_order,v_delivery_line,v_order_line,
    v_product,v_uom,'OVERAGE','ACCEPT_OVERAGE',3,3*v_factor,'APPROVED','RESOLVED',
    'C2C rollback accepted overage',10000,1000,0,29000,
    jsonb_build_object('quantityUom',3,'quantityBase',3*v_factor,'unitPrice',10000,
      'grossAmount',30000,'discountAmount',1000,'tax',jsonb_build_object(
        'taxApplied',false,'source','SALES_ORDER'),'taxAmount',0,'lineTotal',29000,
      'defaultAuthority','SALES_ORDER','adjustedBySalesAdmin',false),
    v_actor,clock_timestamp(),3*v_factor);
  v_invoice:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,'dueDate',v_today,
      'lines',jsonb_build_array(),'acceptedOverageLines',jsonb_build_array(
        jsonb_build_object('discrepancyLineId',v_case_line,'quantityUom',1))));
  v_workspace:=public.get_backoffice_sales_invoice_workspace(v_order,NULL,NULL,100);
  v_detail:=private.backoffice_sales_invoice_ui_snapshot(v_company,
    (v_invoice->'data'->>'id')::uuid);
  IF jsonb_array_length(v_workspace->'sourceOrder'->'acceptedOverageLines')<>1
    OR v_workspace->'sourceOrder'->'acceptedOverageLines'->0->>'sourceKind'<>'ACCEPTED_OVERAGE'
    OR (v_workspace->'sourceOrder'->'acceptedOverageLines'->0->>'orderedQty')::numeric<>0
    OR (v_workspace->'sourceOrder'->'acceptedOverageLines'->0->>'acceptedQty')::numeric<>3
    OR (v_workspace->'sourceOrder'->'acceptedOverageLines'->0->>'toInvoiceQty')::numeric<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted-overage workspace source invalid';
  END IF;
  IF jsonb_array_length(v_detail->'lines')<>1
    OR v_detail->'lines'->0->>'sourceKind'<>'ACCEPTED_OVERAGE'
    OR v_detail->'lines'->0->>'discrepancyLineId'<>v_case_line::text
    OR v_detail->'lines'->0->>'description'<>'Kelebihan barang'
    OR (v_detail->'lines'->0->>'orderedQty')::numeric<>0
    OR (v_detail->'lines'->0->>'acceptedQty')::numeric<>3
    OR (v_detail->'lines'->0->>'quantityUom')::numeric<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted-overage Invoice detail invalid';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_accepted_overage_invoice_client_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'existing Invoice workspace','resolved accepted-overage source','Draft held remainder',
    'separate Kelebihan barang detail','Qty Order zero','Qty Diterima accepted overage',
    'source lineage','authenticated tenant context','all fixture writes rolled back']) details;
