-- Purchase Daily Replenishment Step 6/6B rollback-only behavior.
-- Covers scheduler identity/retry, date identity, RO/PO cancellation, and full-Return gate.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153147','purchase-scheduler-test@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase Scheduler Test"}'::jsonb,false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153147','purchase-scheduler-test@example.invalid',
  'Purchase Scheduler Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE
  v_actor uuid:='00000000-0000-0000-0000-000000153147';
  v_company uuid:='00000000-0000-0000-0000-000000153200';
  v_other_company uuid:='00000000-0000-0000-0000-000000153299';
  v_store uuid:='00000000-0000-0000-0000-000000153201';
  v_terminal uuid:='00000000-0000-0000-0000-000000153202';
  v_warehouse uuid:='00000000-0000-0000-0000-000000153203';
  v_category uuid:='00000000-0000-0000-0000-000000153204';
  v_base_uom uuid:='00000000-0000-0000-0000-000000153205';
  v_purchase_uom uuid:='00000000-0000-0000-0000-000000153206';
  v_product uuid:='00000000-0000-0000-0000-000000153207';
  v_supplier uuid:='00000000-0000-0000-0000-000000153208';
  v_session uuid:='00000000-0000-0000-0000-000000153209';
  v_timezone text:='Asia/Jakarta';v_effective timestamptz;v_scheduler jsonb;
  v_ro uuid:=gen_random_uuid();v_ro_operation uuid:=gen_random_uuid();v_result jsonb;
  v_po_batch uuid:=gen_random_uuid();v_po uuid:=gen_random_uuid();
  v_po_operation uuid:=gen_random_uuid();v_receipt uuid:=gen_random_uuid();
  v_generation_operation uuid:=gen_random_uuid();
  v_received_po uuid:='00000000-0000-0000-0000-000000153210';
  v_received_line uuid:='00000000-0000-0000-0000-000000153211';
  v_received_receipt uuid;v_source_allocation uuid;v_return uuid;
  v_message text;v_version bigint;v_net numeric;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914141000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: scheduler midnight-window forward fix required';
  END IF;
  INSERT INTO public.companies(id,company_code,company_name,company_slug,status,timezone)
  VALUES(v_company,'P6B1','Purchase Step 6B','purchase-step-6b','ACTIVE',v_timezone);
  INSERT INTO public.companies(id,company_code,company_name,company_slug,status,timezone)
  VALUES(v_other_company,'P6B2','Purchase Step 6B Other','purchase-step-6b-other',
    'ACTIVE',v_timezone);
  INSERT INTO public.stores(id,company_id,store_code,store_name,status)
  VALUES(v_store,v_company,'P6BS','Purchase Step 6B Store','ACTIVE');
  INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status)
  VALUES(v_terminal,v_company,v_store,'P6BP','Purchase Step 6B POS','ACTIVE');
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,
    is_sale_source,is_purchase_destination,is_active)
  VALUES(v_warehouse,v_company,'P6BWH','Purchase Step 6B Warehouse','STORE',v_store,
    false,true,true);
  INSERT INTO public.product_categories(id,company_id,category_code,category_name)
  VALUES(v_category,v_company,'P6BCAT','Purchase Step 6B Product');
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
  VALUES
    (v_base_uom,v_company,'P6BPCS','Purchase Step 6B Piece','UNIT',false,0),
    (v_purchase_uom,v_company,'P6BBOX','Purchase Step 6B Box','PACKAGING',false,0);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
    uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle)
  VALUES(v_product,v_company,'P6B-PROD','Purchase Step 6B Product',
    'Purchase Step 6B Product',v_category,100,45,'P6BPCS',v_base_uom,
    v_base_uom,1,true,false);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
  VALUES
    (v_company,v_product,v_base_uom,1,false,true,45,100,true),
    (v_company,v_product,v_purchase_uom,10,true,false,450,1000,true);
  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,created_by,updated_by)
  VALUES(v_supplier,v_company,'P6BSUP','Purchase Step 6B Supplier',v_actor,v_actor);
  INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,store_id,
    pos_id,status,sales_warehouse_id)
  VALUES(v_session,'P6B-SESSION',v_actor,v_company,v_store,v_terminal,
    'OPEN'::public.session_status,v_warehouse);

  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claims',
    jsonb_build_object('sub',v_actor,'role','authenticated')::text,true);

  -- Isolate the scheduler to this rollback-only Company.
  UPDATE public.company_purchase_replenishment_settings
  SET replenishment_mode='MANUAL',updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id<>v_company;
  UPDATE public.company_purchase_replenishment_settings
  SET replenishment_mode='AUTO_RO',updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;

  v_effective:=((date '2098-12-29'+time '23:59:30') AT TIME ZONE v_timezone);
  v_scheduler:=private.run_purchase_daily_replenishment_scheduler(v_effective);
  IF v_scheduler->>'executionActor'<>'SYSTEM_AUTOMATION'
    OR v_scheduler->>'actorDisplayName'<>'Sistem Otomatis' THEN
    RAISE EXCEPTION 'TEST_FAILED: scheduler response identity invalid: %',v_scheduler;
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.purchase_daily_scheduler_runs run
      WHERE run.company_id=v_company AND run.business_date='2098-12-29'
        AND run.execution_actor='SYSTEM_AUTOMATION'
        AND run.actor_display_name='Sistem Otomatis'
        AND run.technical_sponsor_id=v_actor
        AND run.status='NO_DEMAND') THEN
    RAISE EXCEPTION 'TEST_FAILED: scheduler run invalid: response=%, run=%',v_scheduler,
      (SELECT to_jsonb(run) FROM public.purchase_daily_scheduler_runs run
       WHERE run.company_id=v_company AND run.business_date='2098-12-29');
  END IF;
  PERFORM private.run_purchase_daily_replenishment_scheduler(v_effective);
  IF (SELECT attempt_count FROM public.purchase_daily_scheduler_runs
      WHERE company_id=v_company AND business_date='2098-12-29')<>2
    OR (SELECT count(*) FROM public.purchase_daily_scheduler_attempts attempt
      WHERE attempt.company_id=v_company AND attempt.business_date='2098-12-29')<>2
    OR NOT EXISTS(SELECT 1 FROM public.purchase_daily_scheduler_attempts attempt
      WHERE attempt.company_id=v_company AND attempt.business_date='2098-12-29'
        AND attempt.status='NO_DEMAND')
    OR NOT EXISTS(SELECT 1 FROM public.purchase_daily_scheduler_attempts attempt
      WHERE attempt.company_id=v_company AND attempt.business_date='2098-12-29'
        AND attempt.status='REUSED')
    OR EXISTS(SELECT 1 FROM public.purchase_daily_batches batch
      WHERE batch.company_id=v_company AND batch.business_date='2098-12-29') THEN
    RAISE EXCEPTION 'TEST_FAILED: scheduler retry/no-demand behavior invalid';
  END IF;
  BEGIN
    UPDATE public.purchase_daily_scheduler_attempts SET status='FAILED'
    WHERE company_id=v_company AND business_date='2098-12-29';
    RAISE EXCEPTION 'TEST_FAILED: scheduler attempt history was mutable';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_AUTOMATION_HISTORY_IMMUTABLE' THEN RAISE; END IF;
  END;

  -- AUTO_RO Draft can be canceled and the exact retry is idempotent.
  INSERT INTO public.purchase_daily_batches(id,company_id,batch_no,business_date,
    mode_snapshot,status,cutoff_at,line_count,requested_total_base_qty,generated_by)
  VALUES(v_ro,v_company,'RO-20981230-TEST','2098-12-30','AUTO_RO','DRAFT',
    ((date '2098-12-30'+time '23:59') AT TIME ZONE v_timezone),0,0,v_actor);
  BEGIN
    PERFORM public.cancel_purchase_daily_auto_ro(v_ro,NULL,gen_random_uuid(),'Null version');
    RAISE EXCEPTION 'TEST_FAILED: null RO version unexpectedly accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'MASTER_VERSION_CONFLICT' THEN RAISE; END IF;
  END;
  UPDATE public.user_active_company_contexts SET company_id=v_other_company,
    updated_at=clock_timestamp() WHERE user_id=v_actor;
  BEGIN
    PERFORM public.cancel_purchase_daily_auto_ro(v_ro,1,gen_random_uuid(),'Cross tenant');
    RAISE EXCEPTION 'TEST_FAILED: cross-tenant RO cancellation unexpectedly accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_DAILY_BATCH_NOT_FOUND' THEN RAISE; END IF;
  END;
  UPDATE public.user_active_company_contexts SET company_id=v_company,
    updated_at=clock_timestamp() WHERE user_id=v_actor;
  v_result:=public.cancel_purchase_daily_auto_ro(v_ro,1,v_ro_operation,'Tidak dilanjutkan');
  IF v_result->>'status'<>'CANCELED'
    OR (SELECT status FROM public.purchase_daily_batches
      WHERE company_id=v_company AND id=v_ro)<>'CANCELED'
    OR NOT EXISTS(SELECT 1 FROM public.purchase_daily_batch_audit audit
      WHERE audit.company_id=v_company AND audit.batch_id=v_ro
        AND audit.action='CANCEL' AND audit.actor_id=v_actor) THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft RO cancellation invalid';
  END IF;
  v_result:=public.cancel_purchase_daily_auto_ro(v_ro,1,v_ro_operation,'Tidak dilanjutkan');
  IF NOT (v_result->>'exactRetry')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft RO cancellation retry invalid';
  END IF;

  -- Confirmed PO with no posted Receipt can be canceled; its Draft Receipt closes too.
  INSERT INTO public.purchase_daily_batches(id,company_id,batch_no,business_date,
    mode_snapshot,status,cutoff_at,line_count,requested_total_base_qty,generated_by)
  VALUES(v_po_batch,v_company,'POB-20981231-TEST','2098-12-31','AUTO_PO','DRAFT',
    ((date '2098-12-31'+time '23:59') AT TIME ZONE v_timezone),0,0,v_actor);
  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,line_count,
    total_ordered_base_qty,estimated_total,order_source,document_scope,
    purchase_daily_batch_id,supplier_assignment_status)
  VALUES(v_po,v_company,'PO-20981231-TEST',NULL,NULL,NULL,'2098-12-31',v_actor,
    'DRAFT',0,0,0,'DAILY_REPLENISHMENT','COMPANY_MULTI_WAREHOUSE',v_po_batch,
    'SUPPLIER_PENDING');
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=master_version+1 WHERE company_id=v_company AND id=v_po;
  INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,operation_type,
    request_hash,result_snapshot,actor_id)
  VALUES(v_generation_operation,v_company,v_po_batch,'GENERATE_AUTO_PO','test',
    jsonb_build_object('batchId',v_po_batch),v_actor);
  UPDATE public.purchase_daily_batches SET status='READY',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_operation_id=v_generation_operation,
    generation_operation_id=v_generation_operation,master_version=master_version+1
  WHERE company_id=v_company AND id=v_po_batch;
  INSERT INTO public.goods_receipt_documents(id,company_id,receipt_no,supplier_order_id,
    store_id,warehouse_id,receiving_session_id,receiving_pos_id,received_by,source_channel,
    receipt_scope,purchase_daily_batch_id,supplier_assignment_status,
    unassigned_clearing_status)
  VALUES(v_receipt,v_company,'GR-20981231-TEST',v_po,NULL,v_warehouse,NULL,NULL,v_actor,
    'BACKOFFICE','DAILY_WAREHOUSE',v_po_batch,'SUPPLIER_PENDING','OPEN');
  v_result:=public.cancel_purchase_supplier_order(v_po,2,v_po_operation,'Tidak jadi dibeli');
  IF v_result->>'status'<>'CANCELED'
    OR (SELECT status FROM public.goods_receipt_documents
      WHERE company_id=v_company AND id=v_receipt)<>'CANCELED'
    OR (SELECT status FROM public.purchase_daily_batches
      WHERE company_id=v_company AND id=v_po_batch)<>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: unreceived PO/Draft Receipt cancellation invalid';
  END IF;
  v_result:=public.cancel_purchase_supplier_order(v_po,2,v_po_operation,'Tidak jadi dibeli');
  IF NOT (v_result->>'exactRetry')::boolean
    OR (SELECT count(*) FROM public.purchase_supplier_order_cancel_operations operation
      WHERE operation.company_id=v_company AND operation.id=v_po_operation)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: PO cancellation retry invalid';
  END IF;

  -- A posted Receipt blocks cancellation until every stock-bearing unit is returned.
  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,line_count,
    total_ordered_base_qty,estimated_total)
  VALUES(v_received_po,v_company,
    'PO-'||to_char(current_date,'YYYYMMDD')||'-RECEIVED',v_store,v_warehouse,v_supplier,
    current_date,v_actor,'DRAFT',1,10,450);
  INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,
    client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
    ordered_base_qty,estimated_unit_price,estimated_subtotal,product_sku_snapshot,
    product_name_snapshot,ordered_uom_name_snapshot)
  VALUES(v_received_line,v_company,v_received_po,1,gen_random_uuid(),v_product,
    v_purchase_uom,1,10,10,450,450,'P6B-PROD','Purchase Step 6B Product',
    'Purchase Step 6B Box');
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=2 WHERE company_id=v_company AND id=v_received_po;

  v_result:=public.save_goods_receipt(NULL,NULL,v_session,v_received_po,'DEL-P6B',
    'Full receipt before cancellation',jsonb_build_array(jsonb_build_object(
      'clientLineKey',gen_random_uuid(),'supplierOrderLineId',v_received_line,
      'receivedUomId',v_purchase_uom,'receivedQty',1,'acceptedGoodQty',1,
      'damagedQty',0,'rejectedQty',0)));
  v_received_receipt:=(v_result->>'documentId')::uuid;
  PERFORM public.post_goods_receipt(v_received_receipt,1,gen_random_uuid());
  SELECT master_version INTO v_version FROM public.supplier_order_documents
  WHERE company_id=v_company AND id=v_received_po;
  BEGIN
    PERFORM public.cancel_purchase_supplier_order(v_received_po,v_version,
      gen_random_uuid(),'Harus diretur dulu');
    RAISE EXCEPTION 'TEST_FAILED: received PO cancellation unexpectedly accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'SUPPLIER_ORDER_RETURN_REQUIRED_BEFORE_CANCEL' THEN RAISE; END IF;
  END;
  SELECT allocation.id INTO STRICT v_source_allocation
  FROM public.goods_receipt_condition_allocations allocation
  JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
    AND line.id=allocation.receipt_line_id
  WHERE line.company_id=v_company AND line.document_id=v_received_receipt
    AND allocation.condition_type='GOOD';
  v_result:=public.save_purchase_return_draft(NULL,NULL,v_session,v_received_receipt,
    v_warehouse,current_date,'Batalkan PO setelah retur penuh','SUP-RET-P6B',
    'Full return before PO cancellation',jsonb_build_array(jsonb_build_object(
      'clientLineKey',gen_random_uuid(),'sourceConditionAllocationId',v_source_allocation,
      'returnUomId',v_base_uom,'returnQty',10)));
  v_return:=(v_result->>'documentId')::uuid;
  v_result:=public.review_purchase_return(v_return,1,'APPROVE',NULL);
  PERFORM public.post_purchase_return(v_return,(v_result->>'masterVersion')::bigint,
    gen_random_uuid());
  v_net:=private.purchase_supplier_order_net_received_base_qty(v_company,v_received_po);
  IF v_net<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: full Return left net received quantity %',v_net;
  END IF;
  SELECT master_version INTO v_version FROM public.supplier_order_documents
  WHERE company_id=v_company AND id=v_received_po;
  v_result:=public.cancel_purchase_supplier_order(v_received_po,v_version,
    gen_random_uuid(),'Seluruh barang sudah diretur');
  IF v_result->>'status'<>'CANCELED'
    OR (SELECT status FROM public.supplier_order_documents
      WHERE company_id=v_company AND id=v_received_po)<>'CANCELED'
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=v_company AND receipt.id=v_received_receipt
        AND receipt.status='POSTED')
    OR NOT EXISTS(SELECT 1 FROM public.purchase_return_documents document
      WHERE document.company_id=v_company AND document.id=v_return
        AND document.status='POSTED') THEN
    RAISE EXCEPTION 'TEST_FAILED: full-Return PO cancellation/history preservation invalid';
  END IF;

  RAISE NOTICE 'TEST_PASS: scheduler system identity/retry, date-bearing RO/PO, tenant/version guards, Draft RO cancel, unreceived PO cancel, received PO blocker, full Purchase Return, final cancel, and immutable posted history verified';
END
$test$;

ROLLBACK;
