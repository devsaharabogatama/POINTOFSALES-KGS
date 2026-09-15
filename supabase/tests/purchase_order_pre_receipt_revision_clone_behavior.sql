-- Clone-only unit 86 fixture, derived from audited Warehouse-boundary canonical generator test.
-- Pre-generated Receipt workflow 14180000 is not yet installed. All preparation rolls back.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153146','purchase-warehouse-boundary@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase Warehouse Boundary Test"}'::jsonb,false,'authenticated','authenticated',
  clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153146',
  'purchase-warehouse-boundary@example.invalid','Purchase Warehouse Boundary Test',
  'super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153146';v_company uuid;
  v_timezone text;v_category uuid:=gen_random_uuid();v_uom uuid:=gen_random_uuid();
  v_active_product uuid:=gen_random_uuid();v_inactive_product uuid:=gen_random_uuid();
  v_source uuid:=gen_random_uuid();v_receiver uuid:=gen_random_uuid();
  v_date date:='2099-12-29';v_effective timestamptz;v_setting_version bigint;
  v_operation uuid:=gen_random_uuid();v_result jsonb;v_retry jsonb;v_batch uuid;
  v_order uuid;v_order_line uuid;v_receipt jsonb;v_message text;
  v_document public.supplier_order_documents%rowtype;v_line public.supplier_order_lines%rowtype;
  v_before jsonb;v_lines jsonb;v_revision_operation uuid:=gen_random_uuid();
  v_stock bigint;v_events bigint;v_bills bigint;
BEGIN
  SELECT company.id,company.timezone INTO v_company,v_timezone
  FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting
    ON setting.company_id=company.id
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with Purchase setting required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);

  INSERT INTO public.product_categories(id,company_id,category_code,category_name,
    created_by,updated_by)
  VALUES(v_category,v_company,'PWB-'||left(replace(v_category::text,'-',''),12),
    'Purchase Warehouse Boundary rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
    decimal_precision,created_by,updated_by)
  VALUES(v_uom,v_company,'PWB'||left(replace(v_uom::text,'-',''),10),
    'Purchase Boundary Test Unit','UNIT',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
    uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,
    created_by,updated_by)
  VALUES(v_active_product,v_company,'PWA-'||left(replace(v_active_product::text,'-',''),12),
      'Active Product Without Receipt Warehouse','Purchase Warehouse Boundary rollback category',
      v_category,10,5,'Purchase Boundary Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor),
    (v_inactive_product,v_company,'PWI-'||left(replace(v_inactive_product::text,'-',''),12),
      'Inactive Archived Product','Purchase Warehouse Boundary rollback category',
      v_category,10,5,'Purchase Boundary Test Unit',v_uom,v_uom,1,false,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES(v_company,v_active_product,v_uom,1,true,true,5,10,true,v_actor,v_actor),
    (v_company,v_inactive_product,v_uom,1,true,true,5,10,true,v_actor,v_actor);
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,is_sale_source,
    is_purchase_destination,is_active,created_by,updated_by)
  VALUES(v_source,v_company,'PWS'||left(replace(v_source::text,'-',''),10),
      'Active Non Receiving Source','CENTRAL',false,false,true,v_actor,v_actor),
    (v_receiver,v_company,'PWR'||left(replace(v_receiver::text,'-',''),10),
      'Explicit Receiving Warehouse','CENTRAL',false,true,true,v_actor,v_actor);

  UPDATE public.product_stocks SET stock_qty=0,updated_at=clock_timestamp()
  WHERE company_id=v_company AND stock_qty<0;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id,updated_at)
  VALUES(v_active_product,v_source,-4,v_company,clock_timestamp()),
    (v_inactive_product,v_source,-6,v_company,clock_timestamp());
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_default_warehouse(NULL,v_setting_version);
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_mode('AUTO_PO',v_setting_version);

  v_effective:=((v_date+time '23:59:30') AT TIME ZONE v_timezone);
  v_result:=private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
    v_operation,v_effective);
  v_batch:=(v_result->>'batchId')::uuid;
  IF v_batch IS NULL OR (v_result->>'readyLineCount')::integer<>1
    OR (v_result->>'blockedLineCount')::integer<>1
    OR (v_result->>'supplierOrderCount')::integer<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_PO missing-destination result invalid: %',v_result;
  END IF;
  SELECT document.id,line.id INTO v_order,v_order_line
  FROM public.supplier_order_documents document
  JOIN public.supplier_order_lines line ON line.company_id=document.company_id
    AND line.document_id=document.id
  WHERE document.company_id=v_company AND document.purchase_daily_batch_id=v_batch
    AND line.product_id=v_active_product;
  IF v_order IS NULL OR NOT EXISTS(SELECT 1 FROM public.supplier_order_lines line
      WHERE line.company_id=v_company AND line.id=v_order_line
        AND line.destination_warehouse_id IS NULL)
    OR EXISTS(SELECT 1 FROM public.supplier_order_lines line
      WHERE line.company_id=v_company AND line.document_id=v_order
        AND line.product_id=v_inactive_product) THEN
    RAISE EXCEPTION 'TEST_FAILED: PO creation or inactive Product exclusion invalid';
  END IF;
  v_retry:=private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
    v_operation,v_effective);
  IF NOT (v_retry->>'exactRetry')::boolean
    OR (SELECT count(*) FROM public.supplier_order_documents document
      WHERE document.company_id=v_company AND document.purchase_daily_batch_id=v_batch)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_PO exact retry created duplicate';
  END IF;


  SELECT * INTO STRICT v_document FROM public.supplier_order_documents
  WHERE company_id=v_company AND id=v_order;
  SELECT * INTO STRICT v_line FROM public.supplier_order_lines
  WHERE company_id=v_company AND id=v_order_line;
  v_before:=private.purchase_supplier_order_document_snapshot(v_company,v_order);
  SELECT count(*) INTO v_stock FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_events FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_bills FROM public.supplier_invoice_documents WHERE company_id=v_company;
  v_lines:=jsonb_build_array(jsonb_build_object('lineId',v_line.id,
    'productId',v_line.product_id,'uomId',v_line.ordered_uom_id,
    'destinationWarehouseId',v_receiver,'quantity',5,'estimatedUnitPrice',6));
  v_result:=public.revise_purchase_supplier_order(v_order,v_document.master_version,
    v_revision_operation,v_document.supplier_id,v_date+1,'Rollback revision',v_lines);
  IF v_result->>'status'<>'CONFIRMED'
    OR (v_result->>'masterVersion')::bigint<>v_document.master_version+1
    OR NOT EXISTS(SELECT 1 FROM public.supplier_order_lines
      WHERE id=v_line.id AND company_id=v_company AND ordered_qty=5
        AND estimated_subtotal=30 AND destination_warehouse_id=v_receiver)
    OR NOT EXISTS(SELECT 1 FROM public.supplier_order_audit
      WHERE company_id=v_company AND document_id=v_order AND action='UPDATE'
        AND before_state=v_before) THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical revision state/audit invalid';
  END IF;
  v_retry:=public.revise_purchase_supplier_order(v_order,v_document.master_version,
    v_revision_operation,v_document.supplier_id,v_date+1,'Rollback revision',v_lines);
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: revision retry invalid';
  END IF;
  BEGIN
    PERFORM public.revise_purchase_supplier_order(v_order,v_document.master_version,
      gen_random_uuid(),v_document.supplier_id,v_date+1,NULL,v_lines);
    RAISE EXCEPTION 'TEST_FAILED: stale revision accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM<>'MASTER_VERSION_CONFLICT' THEN RAISE; END IF;
  END;
  v_receipt:=public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_receiver,NULL,
    'Receipt starts after revision',jsonb_build_array(jsonb_build_object(
      'supplierOrderLineId',v_order_line,'receivedUomId',v_uom,
      'receivedQty',5,'acceptedGoodQty',5)));
  BEGIN
    PERFORM public.revise_purchase_supplier_order(v_order,v_document.master_version+1,
      gen_random_uuid(),v_document.supplier_id,v_date+1,NULL,v_lines);
    RAISE EXCEPTION 'TEST_FAILED: revision after Receipt accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM<>'PURCHASE_PO_RECEIPT_ALREADY_STARTED' THEN RAISE; END IF;
  END;
  IF (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_events
    OR (SELECT count(*) FROM public.supplier_invoice_documents WHERE company_id=v_company)<>v_bills THEN
    RAISE EXCEPTION 'TEST_FAILED: revision or Draft Receipt created Stock/Finance/Bill effect';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'purchase_po_revision_clone_behavior' check_name,'PASS' status,0::bigint violation_rows,
  jsonb_build_object('tested',jsonb_build_array('canonical generator PO','revision qty/price/warehouse',
    'immutable identity and audit','exact retry','stale rejection','Receipt-start rejection',
    'zero Stock/Finance/Bill effect','rollback')) details;
