-- Purchase Daily Replenishment Step 5/6: rollback-only behavior.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153145','purchase-receipt-test@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase Receipt Test"}'::jsonb,false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153145','purchase-receipt-test@example.invalid',
  'Purchase Receipt Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153145';v_company uuid;
  v_category uuid:=gen_random_uuid();v_uom uuid:=gen_random_uuid();
  v_product_a uuid:=gen_random_uuid();v_product_b uuid:=gen_random_uuid();
  v_warehouse_a uuid:=gen_random_uuid();v_warehouse_b uuid:=gen_random_uuid();
  v_supplier uuid:=gen_random_uuid();v_batch uuid:=gen_random_uuid();
  v_order uuid:=gen_random_uuid();v_line_a uuid:=gen_random_uuid();v_line_b uuid:=gen_random_uuid();
  v_receipt_a uuid;v_receipt_b uuid;v_version bigint;v_result jsonb;v_assignment jsonb;
  v_assignment_retry jsonb;v_assignment_operation uuid:=gen_random_uuid();
  v_message text;v_stock_a numeric;v_stock_b numeric;v_event_count bigint;
BEGIN
  SELECT company.id INTO v_company FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with Step 1 setting required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);

  IF NOT EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=v_company AND category.system_key='GOODS_RECEIPT'
        AND category.is_active) THEN
    INSERT INTO public.transaction_categories(id,company_id,category_code,category_name,
      system_key,description,is_active,created_by,updated_by)
    VALUES(v_category,v_company,'GR-TEST-'||upper(left(replace(v_category::text,'-',''),8)),
      'Goods Receipt Test '||upper(left(replace(v_category::text,'-',''),8)),
      'GOODS_RECEIPT','Rollback-only Goods Receipt category',true,v_actor,v_actor);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.system_function_key='INVENTORY_ASSET'
        AND account.is_active AND account.is_postable) THEN
    INSERT INTO public.chart_of_accounts(company_id,account_code,account_name,account_type,
      normal_balance,system_function_key,is_system_account,is_postable,
      allow_manual_posting,allow_reconciliation,created_by,updated_by)
    VALUES(v_company,'TINV-'||upper(left(replace(v_category::text,'-',''),8)),
      'Test Inventory '||upper(left(replace(v_category::text,'-',''),8)),
      'ASSET','DEBIT','INVENTORY_ASSET',true,true,false,false,v_actor,v_actor);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.system_function_key='SUPPLIER_AP_PROVISIONAL'
        AND account.is_active AND account.is_postable) THEN
    INSERT INTO public.chart_of_accounts(company_id,account_code,account_name,account_type,
      normal_balance,system_function_key,is_system_account,is_postable,
      allow_manual_posting,allow_reconciliation,created_by,updated_by)
    VALUES(v_company,'TAP-'||upper(left(replace(v_category::text,'-',''),8)),
      'Test Provisional AP '||upper(left(replace(v_category::text,'-',''),8)),
      'LIABILITY','CREDIT','SUPPLIER_AP_PROVISIONAL',true,true,false,true,v_actor,v_actor);
  END IF;
  INSERT INTO public.product_categories(id,company_id,category_code,category_name,created_by,updated_by)
  VALUES(v_category,v_company,'GR-'||left(replace(v_category::text,'-',''),12),
    'Receipt rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision,
    created_by,updated_by)
  VALUES(v_uom,v_company,'GR'||left(replace(v_uom::text,'-',''),10),
    'Receipt Test Unit','UNIT',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
    weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,created_by,updated_by)
  VALUES
    (v_product_a,v_company,'GRA-'||left(replace(v_product_a::text,'-',''),12),
      'Receipt Product A','Receipt rollback category',v_category,20,12,'Receipt Test Unit',v_uom,
      v_uom,1,true,false,v_actor,v_actor),
    (v_product_b,v_company,'GRB-'||left(replace(v_product_b::text,'-',''),12),
      'Receipt Product B','Receipt rollback category',v_category,30,18,'Receipt Test Unit',v_uom,
      v_uom,1,true,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,purchase_allowed,
    sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES(v_company,v_product_a,v_uom,1,true,true,0,20,true,v_actor,v_actor),
    (v_company,v_product_b,v_uom,1,true,true,0,30,true,v_actor,v_actor);
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,is_sale_source,
    is_purchase_destination,is_active,created_by,updated_by)
  VALUES(v_warehouse_a,v_company,'GRA'||left(replace(v_warehouse_a::text,'-',''),10),
      'Receipt Warehouse A','CENTRAL',false,true,true,v_actor,v_actor),
    (v_warehouse_b,v_company,'GRB'||left(replace(v_warehouse_b::text,'-',''),10),
      'Receipt Warehouse B','CENTRAL',false,true,true,v_actor,v_actor);
  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,is_active,created_by,updated_by)
  VALUES(v_supplier,v_company,'GRS-'||left(replace(v_supplier::text,'-',''),12),
    'Receipt Assigned Supplier',true,v_actor,v_actor);
  INSERT INTO public.purchase_daily_batches(id,company_id,batch_no,business_date,mode_snapshot,
    status,cutoff_at,line_count,requested_total_base_qty,generated_by)
  VALUES(v_batch,v_company,'GRB-'||upper(left(replace(v_batch::text,'-',''),12)),
    '2099-12-31','AUTO_PO','DRAFT','2099-12-31 23:59:00+07',2,5,v_actor);
  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,line_count,
    total_ordered_base_qty,estimated_total,confirmed_by,confirmed_at,
    confirmation_idempotency_key,order_source,document_scope,purchase_daily_batch_id,
    supplier_assignment_status)
  VALUES(v_order,v_company,'PO-GR-'||upper(left(replace(v_order::text,'-',''),12)),
    NULL,NULL,NULL,'2099-12-31',v_actor,'DRAFT',2,5,0,NULL,NULL,
    NULL,'DAILY_REPLENISHMENT','COMPANY_MULTI_WAREHOUSE',v_batch,'SUPPLIER_PENDING');
  INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,client_line_key,
    product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,ordered_base_qty,
    estimated_unit_price,estimated_subtotal,product_sku_snapshot,product_name_snapshot,
    ordered_uom_name_snapshot,source_warehouse_id,destination_warehouse_id)
  VALUES(v_line_a,v_company,v_order,1,gen_random_uuid(),v_product_a,v_uom,2,1,2,0,0,
      'GRA','Receipt Product A','Receipt Test Unit',v_warehouse_a,v_warehouse_a),
    (v_line_b,v_company,v_order,2,gen_random_uuid(),v_product_b,v_uom,3,1,3,0,0,
      'GRB','Receipt Product B','Receipt Test Unit',v_warehouse_b,v_warehouse_b);
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_order;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product_a,v_warehouse_a,0,v_company),(v_product_b,v_warehouse_b,0,v_company);

  BEGIN
    PERFORM public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_warehouse_a,NULL,NULL,
      jsonb_build_array(jsonb_build_object('supplierOrderLineId',v_line_b,
        'receivedUomId',v_uom,'receivedQty',3,'acceptedGoodQty',3)));
    RAISE EXCEPTION 'TEST_FAILED: mixed Warehouse line accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'DAILY_SUPPLIER_ORDER_LINE_WAREHOUSE_INVALID' THEN RAISE; END IF;
  END;
  v_result:=public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_warehouse_a,NULL,
    'Warehouse A receipt',jsonb_build_array(jsonb_build_object('supplierOrderLineId',v_line_a,
      'receivedUomId',v_uom,'receivedQty',2,'acceptedGoodQty',2)));
  v_receipt_a:=(v_result->>'documentId')::uuid;
  IF v_result->>'supplierAssignmentStatus'<>'SUPPLIER_PENDING'
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_lines line
      WHERE line.company_id=v_company AND line.document_id=v_receipt_a
        AND line.provisional_cost_source='PRODUCT_COGS'
        AND line.estimated_base_unit_cost=12 AND line.provisional_ap_amount=24) THEN
    RAISE EXCEPTION 'TEST_FAILED: Product COGS provisional default invalid'; END IF;
  SELECT master_version INTO v_version FROM public.goods_receipt_documents
  WHERE company_id=v_company AND id=v_receipt_a;
  v_result:=public.post_purchase_daily_goods_receipt(v_receipt_a,v_version,gen_random_uuid());
  IF v_result->>'financePostingState'<>'HOLD_FOR_SUPPLIER_ASSIGNMENT'
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_unassigned_clearings clearing
      WHERE clearing.company_id=v_company AND clearing.receipt_id=v_receipt_a AND clearing.amount=24)
    OR EXISTS(SELECT 1 FROM public.goods_receipt_ap_provisionals provisional
      WHERE provisional.company_id=v_company AND provisional.receipt_id=v_receipt_a) THEN
    RAISE EXCEPTION 'TEST_FAILED: pending Supplier clearing boundary invalid'; END IF;

  v_result:=public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_warehouse_b,NULL,
    'Warehouse B receipt',jsonb_build_array(jsonb_build_object('supplierOrderLineId',v_line_b,
      'receivedUomId',v_uom,'receivedQty',3,'acceptedGoodQty',3,
      'provisionalUnitCost',20)));
  v_receipt_b:=(v_result->>'documentId')::uuid;
  SELECT master_version INTO v_version FROM public.goods_receipt_documents
  WHERE company_id=v_company AND id=v_receipt_b;
  PERFORM public.post_purchase_daily_goods_receipt(v_receipt_b,v_version,gen_random_uuid());
  IF NOT EXISTS(SELECT 1 FROM public.goods_receipt_lines line
      WHERE line.company_id=v_company AND line.document_id=v_receipt_b
        AND line.provisional_cost_source='USER_OVERRIDE'
        AND line.estimated_base_unit_cost=20 AND line.provisional_ap_amount=60) THEN
    RAISE EXCEPTION 'TEST_FAILED: editable provisional cost invalid'; END IF;
  SELECT stock_qty INTO v_stock_a FROM public.product_stocks
    WHERE product_id=v_product_a AND warehouse_id=v_warehouse_a;
  SELECT stock_qty INTO v_stock_b FROM public.product_stocks
    WHERE product_id=v_product_b AND warehouse_id=v_warehouse_b;
  IF v_stock_a<>2 OR v_stock_b<>3 OR
    (SELECT count(*) FROM public.product_batches batch WHERE batch.company_id=v_company
      AND batch.goods_receipt_line_id IN(SELECT id FROM public.goods_receipt_lines
        WHERE document_id IN(v_receipt_a,v_receipt_b)))<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: multi-Warehouse Stock/FIFO effect invalid'; END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_items item
      JOIN public.financial_events event ON event.company_id=item.company_id
        AND event.id=item.financial_event_id
      WHERE event.source_id IN(v_receipt_a,v_receipt_b)) THEN
    RAISE EXCEPTION 'TEST_FAILED: pending Supplier event entered Finance queue'; END IF;
  SELECT count(*) INTO v_event_count FROM public.financial_events WHERE company_id=v_company;
  SELECT master_version INTO v_version FROM public.goods_receipt_documents
  WHERE company_id=v_company AND id=v_receipt_a;
  SELECT id INTO v_line_a FROM public.goods_receipt_lines
  WHERE company_id=v_company AND document_id=v_receipt_a;
  v_assignment:=public.assign_purchase_daily_receipt_suppliers(v_receipt_a,v_version,
    v_assignment_operation,jsonb_build_array(jsonb_build_object('receiptLineId',v_line_a,
      'supplierId',v_supplier)));
  IF (v_assignment->>'assignmentCount')::integer<>1
    OR (v_assignment->>'assignedAmount')::numeric<>24
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_supplier_assignments assignment
      WHERE assignment.company_id=v_company AND assignment.receipt_id=v_receipt_a
        AND assignment.supplier_id=v_supplier AND assignment.assigned_amount=24)
    OR (SELECT master_version FROM public.goods_receipt_documents
      WHERE company_id=v_company AND id=v_receipt_a)<>v_version THEN
    RAISE EXCEPTION 'TEST_FAILED: append-only Supplier assignment invalid'; END IF;
  IF (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_event_count+1
    OR NOT EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=v_company AND event.id=(v_assignment->>'financialEventId')::uuid
        AND event.system_event_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT'
        AND event.source_id=v_assignment_operation AND event.status='HOLD'::public.event_status) THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier assignment reclassification event invalid';
  END IF;
  v_assignment_retry:=public.assign_purchase_daily_receipt_suppliers(v_receipt_a,v_version,
    v_assignment_operation,jsonb_build_array(jsonb_build_object('receiptLineId',v_line_a,
      'supplierId',v_supplier)));
  IF NOT (v_assignment_retry->>'exactRetry')::boolean
    OR (SELECT count(*) FROM public.goods_receipt_supplier_assignments assignment
      WHERE assignment.company_id=v_company AND assignment.receipt_id=v_receipt_a)<>1
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_event_count+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier assignment exact retry duplicated effect';
  END IF;
  RAISE NOTICE 'TEST_PASS: per-Warehouse Receipt, COGS default/edit, pending clearing, Stock/FIFO, queue exclusion and append-only Supplier assignment verified';
END
$test$;

ROLLBACK;
