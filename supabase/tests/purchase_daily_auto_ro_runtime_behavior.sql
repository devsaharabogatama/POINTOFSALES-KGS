-- Purchase Daily Replenishment Step 3/6: rollback-only behavior.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153133','purchase-auto-ro-test@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase AUTO RO Test"}'::jsonb,false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153133','purchase-auto-ro-test@example.invalid',
  'Purchase AUTO RO Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153133';v_company uuid;
  v_category uuid:=gen_random_uuid();v_product uuid:=gen_random_uuid();
  v_uom uuid:=gen_random_uuid();v_warehouse uuid:=gen_random_uuid();
  v_receiver uuid;v_supplier uuid:=gen_random_uuid();
  v_relation uuid:=gen_random_uuid();v_batch uuid;v_line uuid;v_version bigint;
  v_line_version bigint;v_requested numeric;v_date date;v_effective timestamptz;
  v_before_cutoff timestamptz;v_generate_operation uuid:=gen_random_uuid();
  v_generate_reuse_operation uuid:=gen_random_uuid();
  v_confirm_operation uuid:=gen_random_uuid();v_failed_operation uuid:=gen_random_uuid();
  v_generate jsonb;v_generate_retry jsonb;v_generate_reuse jsonb;
  v_confirm jsonb;v_confirm_retry jsonb;
  v_payload jsonb;v_message text;v_stock_movements bigint;v_finance_events bigint;
  v_receipts bigint;v_orders_before bigint;v_setting_version bigint;v_timezone text;
BEGIN
  SELECT company.id,company.timezone INTO v_company,v_timezone
  FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE'
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with Purchase replenishment setting required';
  END IF;

  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  INSERT INTO public.product_categories(id,company_id,category_code,category_name,
    created_by,updated_by)
  VALUES(v_category,v_company,'AUTORO-'||left(replace(v_category::text,'-',''),12),
    'AUTO RO rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
    decimal_precision,created_by,updated_by)
  VALUES(v_uom,v_company,'AR'||left(replace(v_uom::text,'-',''),10),
    'AUTO RO Test Unit','UNIT',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
    uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,
    created_by,updated_by)
  VALUES(v_product,v_company,'AUTORO-'||left(replace(v_product::text,'-',''),12),
    'AUTO RO rollback product','AUTO RO rollback category',v_category,10,5,
    'AUTO RO Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES(v_company,v_product,v_uom,1,true,true,10,10,true,v_actor,v_actor);
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,is_sale_source,
    is_purchase_destination,is_active,created_by,updated_by)
  VALUES(v_warehouse,v_company,'AR'||left(replace(v_warehouse::text,'-',''),10),
    'AUTO RO rollback warehouse','CENTRAL',false,true,true,v_actor,v_actor);
  v_receiver:=v_warehouse;
  v_date:=(clock_timestamp() AT TIME ZONE v_timezone)::date;
  v_effective:=((v_date+time '23:59:30') AT TIME ZONE v_timezone);
  v_before_cutoff:=((v_date+time '23:58:30') AT TIME ZONE v_timezone);

  UPDATE public.product_stocks SET stock_qty=0,updated_at=clock_timestamp()
  WHERE company_id=v_company AND stock_qty<0;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id,updated_at)
  VALUES(v_product,v_warehouse,-987654321,v_company,clock_timestamp())
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET stock_qty=-987654321,
    company_id=excluded.company_id,updated_at=clock_timestamp();

  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,is_active,
    created_by,updated_by)
  VALUES(v_supplier,v_company,'AUTORO-'||left(replace(v_supplier::text,'-',''),12),
    'AUTO RO rollback supplier '||left(v_supplier::text,8),true,v_actor,v_actor);
  INSERT INTO public.product_suppliers(id,company_id,product_id,supplier_id,
    purchase_uom_id,reference_purchase_price,is_preferred_supplier,is_active,
    selection_priority,created_by,updated_by)
  VALUES(v_relation,v_company,v_product,v_supplier,v_uom,10,false,true,1,v_actor,v_actor);

  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_default_warehouse(v_receiver,v_setting_version);
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_mode('MANUAL',v_setting_version);
  BEGIN
    PERFORM private.generate_purchase_daily_auto_ro_core(v_company,v_date,v_actor,
      v_failed_operation,v_effective);
    RAISE EXCEPTION 'TEST_FAILED: MANUAL mode generated AUTO_RO';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_AUTO_RO_MODE_REQUIRED' THEN RAISE; END IF;
  END;
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_mode('AUTO_RO',v_setting_version);
  BEGIN
    PERFORM private.generate_purchase_daily_auto_ro_core(v_company,v_date,v_actor,
      v_failed_operation,v_before_cutoff);
    RAISE EXCEPTION 'TEST_FAILED: AUTO_RO generated before cutoff';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_AUTO_RO_CUTOFF_NOT_REACHED' THEN RAISE; END IF;
  END;

  SELECT count(*) INTO v_stock_movements FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_finance_events FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_receipts FROM public.goods_receipt_documents WHERE company_id=v_company;
  SELECT count(*) INTO v_orders_before FROM public.supplier_order_documents WHERE company_id=v_company;

  v_generate:=private.generate_purchase_daily_auto_ro_core(v_company,v_date,v_actor,
    v_generate_operation,v_effective);
  v_batch:=(v_generate->>'batchId')::uuid;
  IF v_batch IS NULL OR NOT (v_generate->>'created')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_RO batch was not created: %',v_generate;
  END IF;
  SELECT batch.master_version INTO v_version FROM public.purchase_daily_batches batch
  WHERE batch.company_id=v_company AND batch.id=v_batch AND batch.status='DRAFT'
    AND batch.mode_snapshot='AUTO_RO' AND batch.generated_by=v_actor;
  IF v_version IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: generated RO header invalid'; END IF;
  SELECT line.id,line.master_version,line.requested_base_qty
  INTO v_line,v_line_version,v_requested FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=v_company AND line.batch_id=v_batch
    AND line.product_id=v_product AND line.warehouse_id=v_warehouse;
  IF v_line IS NULL OR v_requested<=2 THEN
    RAISE EXCEPTION 'TEST_FAILED: generated RO line invalid';
  END IF;
  v_generate_retry:=private.generate_purchase_daily_auto_ro_core(v_company,v_date,
    v_actor,v_generate_operation,v_effective);
  IF NOT (v_generate_retry->>'exactRetry')::boolean
    OR v_generate_retry->>'batchId'<>v_batch::text THEN
    RAISE EXCEPTION 'TEST_FAILED: generation exact retry invalid';
  END IF;
  BEGIN
    PERFORM private.generate_purchase_daily_auto_ro_core(v_company,v_date+1,v_actor,
      v_generate_operation,v_effective);
    RAISE EXCEPTION 'TEST_FAILED: generation operation hash conflict accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'IDEMPOTENCY_KEY_CONFLICT' THEN RAISE; END IF;
  END;
  v_generate_reuse:=private.generate_purchase_daily_auto_ro_core(v_company,v_date,
    v_actor,v_generate_reuse_operation,v_effective);
  IF (v_generate_reuse->>'exactRetry')::boolean
    OR NOT (v_generate_reuse->>'existingBatch')::boolean
    OR v_generate_reuse->>'batchId'<>v_batch::text
    OR (SELECT count(*) FROM public.purchase_daily_batches
      WHERE company_id=v_company AND business_date=v_date)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: same-date generation reuse invalid';
  END IF;

  v_payload:=jsonb_build_array(
    jsonb_build_object('batchLineId',v_line,'batchLineVersion',v_line_version,
      'productSupplierId',v_relation,'purchaseUomId',v_uom,
      'orderedQty',1,'estimatedUnitPrice',10,'destinationWarehouseId',v_receiver),
    jsonb_build_object('batchLineId',v_line,'batchLineVersion',v_line_version,
      'productSupplierId',NULL,'purchaseUomId',v_uom,
      'orderedQty',v_requested-1,'estimatedUnitPrice',0,'destinationWarehouseId',v_receiver));
  BEGIN
    PERFORM private.confirm_purchase_daily_auto_ro_core(v_company,v_batch,v_version+1,
      gen_random_uuid(),v_actor,v_payload,v_effective);
    RAISE EXCEPTION 'TEST_FAILED: stale RO version accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'MASTER_VERSION_CONFLICT' THEN RAISE; END IF;
  END;

  v_confirm:=private.confirm_purchase_daily_auto_ro_core(v_company,v_batch,v_version,
    v_confirm_operation,v_actor,v_payload,v_effective);
  IF v_confirm->>'status'<>'READY' OR (v_confirm->>'supplierOrderCount')::integer<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: RO confirmation did not create assigned and pending PO groups: %',v_confirm;
  END IF;
  IF (SELECT count(*) FROM public.supplier_order_documents document
      WHERE document.company_id=v_company AND document.purchase_daily_batch_id=v_batch
        AND document.order_source='DAILY_REPLENISHMENT'
        AND document.document_scope='COMPANY_MULTI_WAREHOUSE'
        AND document.store_id IS NULL AND document.destination_warehouse_id IS NULL
        AND document.status='CONFIRMED')<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: Company-level daily PO shape invalid';
  END IF;
  IF (SELECT count(*) FROM public.supplier_order_documents document
      WHERE document.company_id=v_company AND document.purchase_daily_batch_id=v_batch
        AND ((document.supplier_id=v_supplier AND document.supplier_assignment_status='ASSIGNED')
          OR (document.supplier_id IS NULL
            AND document.supplier_assignment_status='SUPPLIER_PENDING')))<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier grouping contract invalid';
  END IF;
  IF (SELECT sum(allocation.allocated_base_qty)
      FROM public.purchase_daily_batch_order_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.batch_line_id=v_line)<>v_requested THEN
    RAISE EXCEPTION 'TEST_FAILED: batch to PO allocation quantity mismatch';
  END IF;
  IF (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_company)
      <>v_orders_before+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: unexpected Supplier Order count';
  END IF;
  v_confirm_retry:=private.confirm_purchase_daily_auto_ro_core(v_company,v_batch,v_version,
    v_confirm_operation,v_actor,v_payload,v_effective);
  IF NOT (v_confirm_retry->>'exactRetry')::boolean
    OR (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_company)
      <>v_orders_before+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: confirmation exact retry duplicated PO';
  END IF;
  IF (SELECT count(*) FROM public.purchase_daily_batch_audit
      WHERE company_id=v_company AND batch_id=v_batch)<>3
    OR (SELECT count(*) FROM public.purchase_daily_batch_audit
      WHERE company_id=v_company AND batch_id=v_batch AND action='REUSE')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: generate/reuse/confirm audit coverage invalid';
  END IF;
  BEGIN
    UPDATE public.purchase_daily_batch_order_allocations SET allocated_base_qty=allocated_base_qty+1
    WHERE company_id=v_company AND batch_id=v_batch;
    RAISE EXCEPTION 'TEST_FAILED: immutable allocation was updated';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_DAILY_RUNTIME_HISTORY_IMMUTABLE' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock_movements
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_finance_events
    OR (SELECT count(*) FROM public.goods_receipt_documents WHERE company_id=v_company)<>v_receipts THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_RO confirmation created Receipt/Stock/Finance effect';
  END IF;
  RAISE NOTICE 'TEST_PASS: cutoff/mode guards, atomic RO, same-date reuse, assigned+pending PO split, retry, stale version, lineage, immutable audit and zero final effect verified';
END
$test$;

ROLLBACK;
