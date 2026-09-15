-- Purchase Step 5/6B: rollback-only Warehouse boundary behavior.
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

  BEGIN
    PERFORM public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_source,NULL,NULL,
      jsonb_build_array(jsonb_build_object('supplierOrderLineId',v_order_line,
        'receivedUomId',v_uom,'receivedQty',4,'acceptedGoodQty',4)));
    RAISE EXCEPTION 'TEST_FAILED: non-receiving Warehouse accepted';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message<>'PURCHASE_RECEIPT_WAREHOUSE_INVALID' THEN RAISE; END IF;
  END;
  v_receipt:=public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_receiver,NULL,
    'Explicit Warehouse selected at Receive',jsonb_build_array(jsonb_build_object(
      'supplierOrderLineId',v_order_line,'receivedUomId',v_uom,
      'receivedQty',4,'acceptedGoodQty',4)));
  IF v_receipt->>'documentId' IS NULL OR NOT EXISTS(
      SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=v_company AND receipt.id=(v_receipt->>'documentId')::uuid
        AND receipt.warehouse_id=v_receiver AND receipt.status='DRAFT') THEN
    RAISE EXCEPTION 'TEST_FAILED: explicit receiving Warehouse not retained';
  END IF;
  RAISE NOTICE 'TEST PASSED: AUTO_PO creates active Product without destination; archived Product stays excluded; Receive requires explicit valid Warehouse; retry is exact';
END
$test$;

ROLLBACK;
