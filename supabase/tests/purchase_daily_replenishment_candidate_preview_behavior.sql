-- Purchase Daily Replenishment Step 2/6: rollback-only behavior.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153132','purchase-preview-test@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase Preview Test"}'::jsonb,false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153132','purchase-preview-test@example.invalid',
  'Purchase Preview Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153132';v_company uuid;
  v_product uuid;v_warehouse uuid;v_receiver uuid;v_stock_id uuid;
  v_version bigint;v_preview jsonb;v_candidate jsonb;v_setting jsonb;
  v_open numeric;v_expected numeric;v_request_before bigint;v_order_before bigint;
  v_receipt_before bigint;v_batch_before bigint;
BEGIN
  IF private.purchase_uncovered_negative_qty(-10,0)<>10
    OR private.purchase_uncovered_negative_qty(-10,4)<>6
    OR private.purchase_uncovered_negative_qty(-10,15)<>0
    OR private.purchase_uncovered_negative_qty(5,0)<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: uncovered negative quantity formula drift';
  END IF;

  SELECT company.id,product.id,warehouse.id
  INTO v_company,v_product,v_warehouse
  FROM public.companies company
  JOIN public.products product ON product.company_id=company.id AND product.uom_id IS NOT NULL
  JOIN public.uoms uom ON uom.company_id=product.company_id AND uom.id=product.uom_id
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
  JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE'
  ORDER BY company.id,product.id,warehouse.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with Product/Base UOM and operational Warehouse required';
  END IF;

  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);

  SELECT count(*) INTO v_request_before FROM public.stock_request_documents WHERE company_id=v_company;
  SELECT count(*) INTO v_order_before FROM public.supplier_order_documents WHERE company_id=v_company;
  SELECT count(*) INTO v_receipt_before FROM public.goods_receipt_documents WHERE company_id=v_company;
  SELECT count(*) INTO v_batch_before FROM public.purchase_daily_batches WHERE company_id=v_company;

  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id,updated_at)
  VALUES(v_product,v_warehouse,-987654,v_company,clock_timestamp())
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET stock_qty=-987654,
    company_id=excluded.company_id,updated_at=clock_timestamp()
  RETURNING id INTO v_stock_id;

  SELECT warehouse.id INTO v_receiver FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.is_active
    AND warehouse.is_purchase_destination
    AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
  ORDER BY (warehouse.id=v_warehouse) DESC,warehouse.name,warehouse.id LIMIT 1;
  SELECT master_version INTO v_version FROM public.company_purchase_replenishment_settings
  WHERE company_id=v_company;
  v_setting:=public.set_purchase_replenishment_default_warehouse(v_receiver,v_version);

  v_preview:=public.get_purchase_daily_replenishment_preview();
  SELECT item INTO v_candidate FROM jsonb_array_elements(v_preview->'candidates') item
  WHERE item->>'productId'=v_product::text
    AND item->>'sourceWarehouseId'=v_warehouse::text;
  IF v_candidate IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: negative On Hand candidate missing'; END IF;
  IF (v_candidate->>'onHandBaseQty')::numeric<>-987654 THEN
    RAISE EXCEPTION 'TEST_FAILED: candidate On Hand snapshot mismatch';
  END IF;
  v_open:=(v_candidate->>'openPurchaseBaseQty')::numeric;
  v_expected:=private.purchase_uncovered_negative_qty(-987654,v_open);
  IF (v_candidate->>'requestedBaseQty')::numeric<>v_expected THEN
    RAISE EXCEPTION 'TEST_FAILED: exact outstanding purchase deduction mismatch';
  END IF;
  IF v_candidate->>'sourceWarehouseId'<>v_warehouse::text THEN
    RAISE EXCEPTION 'TEST_FAILED: source Warehouse identity changed';
  END IF;
  IF v_receiver IS NULL AND v_candidate->>'destinationWarehouseId' IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: destination invented without purchase receiving Warehouse';
  END IF;
  IF v_receiver IS NOT NULL AND v_candidate->>'destinationWarehouseId' IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: destination default was not resolved';
  END IF;

  IF (SELECT count(*) FROM public.stock_request_documents WHERE company_id=v_company)<>v_request_before
    OR (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_company)<>v_order_before
    OR (SELECT count(*) FROM public.goods_receipt_documents WHERE company_id=v_company)<>v_receipt_before
    OR (SELECT count(*) FROM public.purchase_daily_batches WHERE company_id=v_company)<>v_batch_before THEN
    RAISE EXCEPTION 'TEST_FAILED: read-only preview created an operational document';
  END IF;

  RAISE NOTICE 'TEST_PASS: exact formula, negative On Hand source, destination fallback, and zero operational mutation verified';
END
$test$;

ROLLBACK;
