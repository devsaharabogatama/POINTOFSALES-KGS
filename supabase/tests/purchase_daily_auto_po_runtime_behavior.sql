-- Purchase Daily Replenishment Step 4/6: rollback-only behavior.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153134','purchase-auto-po-test@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase AUTO PO Test"}'::jsonb,false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153134','purchase-auto-po-test@example.invalid',
  'Purchase AUTO PO Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153134';v_company uuid;
  v_category uuid:=gen_random_uuid();v_uom uuid:=gen_random_uuid();
  v_ready_product uuid:=gen_random_uuid();v_pending_product uuid:=gen_random_uuid();
  v_blocked_product uuid:=gen_random_uuid();v_ready_warehouse uuid:=gen_random_uuid();
  v_blocked_warehouse uuid:=gen_random_uuid();v_supplier uuid:=gen_random_uuid();
  v_relation uuid:=gen_random_uuid();v_batch uuid;v_date date:='2099-12-30';
  v_effective timestamptz;v_before_cutoff timestamptz;v_timezone text;
  v_setting_version bigint;v_generate_operation uuid:=gen_random_uuid();
  v_reuse_operation uuid:=gen_random_uuid();v_failed_operation uuid:=gen_random_uuid();
  v_second_operation uuid:=gen_random_uuid();v_second_batch uuid;
  v_generate jsonb;v_retry jsonb;v_reuse jsonb;v_second jsonb;v_message text;
  v_stock_movements bigint;v_finance_events bigint;v_receipts bigint;v_orders bigint;
BEGIN
  SELECT company.id,company.timezone INTO v_company,v_timezone
  FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
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
  VALUES(v_category,v_company,'AUTOPO-'||left(replace(v_category::text,'-',''),12),
    'AUTO PO rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
    decimal_precision,created_by,updated_by)
  VALUES(v_uom,v_company,'AP'||left(replace(v_uom::text,'-',''),10),
    'AUTO PO Test Unit','UNIT',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
    uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,
    created_by,updated_by)
  VALUES
    (v_ready_product,v_company,'APR-'||left(replace(v_ready_product::text,'-',''),12),
      'AUTO PO Ready Product','AUTO PO rollback category',v_category,10,5,
      'AUTO PO Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor),
    (v_pending_product,v_company,'APP-'||left(replace(v_pending_product::text,'-',''),12),
      'AUTO PO Pending Supplier Product','AUTO PO rollback category',v_category,10,5,
      'AUTO PO Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor),
    (v_blocked_product,v_company,'APB-'||left(replace(v_blocked_product::text,'-',''),12),
      'AUTO PO Warehouse Blocked Product','AUTO PO rollback category',v_category,10,5,
      'AUTO PO Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES
    (v_company,v_ready_product,v_uom,1,true,true,10,10,true,v_actor,v_actor),
    (v_company,v_pending_product,v_uom,1,true,true,10,10,true,v_actor,v_actor),
    (v_company,v_blocked_product,v_uom,1,true,true,10,10,true,v_actor,v_actor);
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,is_sale_source,
    is_purchase_destination,is_active,created_by,updated_by)
  VALUES
    (v_ready_warehouse,v_company,'APR'||left(replace(v_ready_warehouse::text,'-',''),10),
      'AUTO PO Receiving Warehouse','CENTRAL',false,true,true,v_actor,v_actor),
    (v_blocked_warehouse,v_company,'APB'||left(replace(v_blocked_warehouse::text,'-',''),10),
      'AUTO PO Non Receiving Warehouse','CENTRAL',false,false,true,v_actor,v_actor);
  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,is_active,
    created_by,updated_by)
  VALUES(v_supplier,v_company,'AUTOPO-'||left(replace(v_supplier::text,'-',''),12),
    'AUTO PO rollback supplier '||left(v_supplier::text,8),true,v_actor,v_actor);
  INSERT INTO public.product_suppliers(id,company_id,product_id,supplier_id,
    purchase_uom_id,reference_purchase_price,is_preferred_supplier,is_active,
    selection_priority,created_by,updated_by)
  VALUES(v_relation,v_company,v_ready_product,v_supplier,v_uom,10,false,true,1,v_actor,v_actor);

  UPDATE public.product_stocks SET stock_qty=0,updated_at=clock_timestamp()
  WHERE company_id=v_company AND stock_qty<0;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id,updated_at)
  VALUES
    (v_ready_product,v_ready_warehouse,-7,v_company,clock_timestamp()),
    (v_pending_product,v_ready_warehouse,-5,v_company,clock_timestamp()),
    (v_blocked_product,v_blocked_warehouse,-3,v_company,clock_timestamp());

  v_effective:=((v_date+time '23:59:30') AT TIME ZONE v_timezone);
  v_before_cutoff:=((v_date+time '23:58:30') AT TIME ZONE v_timezone);
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_default_warehouse(NULL,v_setting_version);
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_mode('MANUAL',v_setting_version);
  BEGIN
    PERFORM private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
      v_failed_operation,v_effective);
    RAISE EXCEPTION 'TEST_FAILED: MANUAL mode generated AUTO_PO';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_AUTO_PO_MODE_REQUIRED' THEN RAISE; END IF;
  END;
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_mode('AUTO_PO',v_setting_version);
  BEGIN
    PERFORM private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
      v_failed_operation,v_before_cutoff);
    RAISE EXCEPTION 'TEST_FAILED: AUTO_PO generated before cutoff';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_AUTO_PO_CUTOFF_NOT_REACHED' THEN RAISE; END IF;
  END;

  SELECT count(*) INTO v_stock_movements FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_finance_events FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_receipts FROM public.goods_receipt_documents WHERE company_id=v_company;
  SELECT count(*) INTO v_orders FROM public.supplier_order_documents WHERE company_id=v_company;

  v_generate:=private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
    v_generate_operation,v_effective);
  v_batch:=(v_generate->>'batchId')::uuid;
  IF v_batch IS NULL OR NOT (v_generate->>'created')::boolean
    OR v_generate->>'status'<>'DRAFT' OR NOT (v_generate->>'partialHold')::boolean
    OR (v_generate->>'readyLineCount')::integer<>2
    OR (v_generate->>'blockedLineCount')::integer<>1
    OR (v_generate->>'supplierOrderCount')::integer<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_PO partial-hold result invalid: %',v_generate;
  END IF;
  IF (SELECT count(*) FROM public.purchase_daily_batch_lines line
      WHERE line.company_id=v_company AND line.batch_id=v_batch
        AND line.readiness_status='ORDERED')<>2
    OR (SELECT count(*) FROM public.purchase_daily_batch_lines line
      WHERE line.company_id=v_company AND line.batch_id=v_batch
        AND line.product_id=v_blocked_product
        AND line.readiness_status='WAREHOUSE_SETUP_REQUIRED'
        AND line.destination_warehouse_id IS NULL)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: ready/blocked line separation invalid';
  END IF;
  IF (SELECT count(*) FROM public.supplier_order_documents document
      WHERE document.company_id=v_company AND document.purchase_daily_batch_id=v_batch
        AND document.status='CONFIRMED' AND document.order_source='DAILY_REPLENISHMENT'
        AND ((document.supplier_id=v_supplier AND document.supplier_assignment_status='ASSIGNED')
          OR (document.supplier_id IS NULL
            AND document.supplier_assignment_status='SUPPLIER_PENDING')))<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: assigned and pending AUTO_PO split invalid';
  END IF;
  IF (SELECT count(*) FROM public.purchase_daily_batch_order_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.batch_id=v_batch)<>2
    OR EXISTS(SELECT 1 FROM public.purchase_daily_batch_order_allocations allocation
      JOIN public.purchase_daily_batch_lines line ON line.company_id=allocation.company_id
        AND line.id=allocation.batch_line_id
      WHERE allocation.company_id=v_company AND allocation.batch_id=v_batch
        AND line.product_id=v_blocked_product) THEN
    RAISE EXCEPTION 'TEST_FAILED: blocked line received an order allocation';
  END IF;
  IF (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_company)<>v_orders+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: unexpected Supplier Order count';
  END IF;

  v_retry:=private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
    v_generate_operation,v_effective);
  IF NOT (v_retry->>'exactRetry')::boolean
    OR (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_company)<>v_orders+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated AUTO_PO';
  END IF;
  BEGIN
    PERFORM private.generate_purchase_daily_auto_po_core(v_company,v_date+1,v_actor,
      v_generate_operation,v_effective);
    RAISE EXCEPTION 'TEST_FAILED: AUTO_PO operation hash conflict accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'IDEMPOTENCY_KEY_CONFLICT' THEN RAISE; END IF;
  END;
  v_reuse:=private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
    v_reuse_operation,v_effective);
  IF (v_reuse->>'exactRetry')::boolean OR NOT (v_reuse->>'existingBatch')::boolean
    OR v_reuse->>'batchId'<>v_batch::text
    OR (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_company)<>v_orders+2 THEN
    RAISE EXCEPTION 'TEST_FAILED: same-date AUTO_PO reuse invalid';
  END IF;
  IF (SELECT count(*) FROM public.purchase_daily_batch_audit audit
      WHERE audit.company_id=v_company AND audit.batch_id=v_batch)<>2
    OR (SELECT count(*) FROM public.purchase_daily_batch_audit audit
      WHERE audit.company_id=v_company AND audit.batch_id=v_batch
        AND audit.action='AUTO_PO_GENERATE')<>1
    OR (SELECT count(*) FROM public.purchase_daily_batch_audit audit
      WHERE audit.company_id=v_company AND audit.batch_id=v_batch
        AND audit.action='AUTO_PO_REUSE')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_PO operation/audit coverage invalid';
  END IF;

  -- A second business date proves that a fully ready AUTO_PO closes its batch.
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_default_warehouse(
    v_ready_warehouse,v_setting_version);
  UPDATE public.product_stocks SET stock_qty=CASE product_id
      WHEN v_ready_product THEN -9 WHEN v_pending_product THEN -6 ELSE -5 END,
    updated_at=clock_timestamp()
  WHERE company_id=v_company AND product_id IN(
    v_ready_product,v_pending_product,v_blocked_product);
  v_effective:=(((v_date+1)+time '23:59:30') AT TIME ZONE v_timezone);
  v_second:=private.generate_purchase_daily_auto_po_core(v_company,v_date+1,v_actor,
    v_second_operation,v_effective);
  v_second_batch:=(v_second->>'batchId')::uuid;
  IF v_second_batch IS NULL OR v_second->>'status'<>'READY'
    OR (v_second->>'partialHold')::boolean
    OR (v_second->>'readyLineCount')::integer<>3
    OR (v_second->>'blockedLineCount')::integer<>0
    OR (v_second->>'supplierOrderCount')::integer<>2
    OR NOT EXISTS(SELECT 1 FROM public.purchase_daily_batches batch
      WHERE batch.company_id=v_company AND batch.id=v_second_batch
        AND batch.status='READY' AND batch.confirmation_operation_id=v_second_operation
        AND batch.confirmed_by=v_actor) THEN
    RAISE EXCEPTION 'TEST_FAILED: fully ready AUTO_PO batch invalid: %',v_second;
  END IF;
  IF (SELECT count(*) FROM public.purchase_daily_batch_order_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.batch_id=v_second_batch)<>3
    OR (SELECT count(*) FROM public.supplier_order_documents
      WHERE company_id=v_company)<>v_orders+4 THEN
    RAISE EXCEPTION 'TEST_FAILED: fully ready AUTO_PO allocation/grouping invalid';
  END IF;
  IF (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock_movements
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_finance_events
    OR (SELECT count(*) FROM public.goods_receipt_documents WHERE company_id=v_company)<>v_receipts THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_PO created Receipt/Stock/FIFO/AP/Finance effect';
  END IF;
  RAISE NOTICE 'TEST_PASS: AUTO_PO mode/cutoff, ready plus pending PO split, warehouse blocker isolation, retry/reuse, lineage/audit and zero final effect verified';
END
$test$;

ROLLBACK;
