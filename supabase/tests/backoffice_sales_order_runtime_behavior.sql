-- Rollback-only representative Backoffice Quotation/SO runtime behavior.
BEGIN;

DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_customer uuid;v_category uuid;
  v_uom uuid;v_warehouse uuid;v_product uuid;v_product_uom uuid;
  v_category_result jsonb;v_uom_result jsonb;v_warehouse_result jsonb;v_product_result jsonb;
  v_payload jsonb;v_create jsonb;v_retry jsonb;v_send jsonb;v_confirm jsonb;
  v_cancel_create jsonb;v_cancel jsonb;v_order uuid;v_cancel_order uuid;
  v_version bigint;v_save_op uuid:=gen_random_uuid();v_send_op uuid:=gen_random_uuid();
  v_confirm_op uuid:=gen_random_uuid();v_cancel_save_op uuid:=gen_random_uuid();
  v_cancel_op uuid:=gen_random_uuid();v_conflict_caught boolean:=false;
  v_stale_caught boolean:=false;v_before jsonb;v_after jsonb;
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_ORDER_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=EXCLUDED.company_id,
    selection_source=EXCLUDED.selection_source;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}'::jsonb,v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,
    updated_by=EXCLUDED.updated_by,updated_at=clock_timestamp();

  SELECT store.id INTO STRICT v_store FROM public.stores store
  WHERE store.company_id=v_company AND store.status='ACTIVE' ORDER BY store.id LIMIT 1;
  SELECT customer.id INTO STRICT v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active ORDER BY customer.is_system_customer DESC,customer.id LIMIT 1;
  SELECT category.id INTO v_category FROM public.product_categories category
  WHERE category.company_id=v_company AND category.is_active ORDER BY category.id LIMIT 1;
  IF v_category IS NULL THEN
    v_category_result:=public.save_inventory_product_category(
      NULL::uuid,NULL::bigint,'Backoffice Runtime Test Category'::text,true);
    v_category:=(v_category_result->'data'->>'id')::uuid;
  END IF;

  v_uom_result:=public.save_inventory_uom(NULL::uuid,NULL::bigint,
    'Backoffice Runtime Test Unit'::text,'UNIT'::text,false,0::smallint,true);
  v_uom:=(v_uom_result->'data'->>'id')::uuid;
  v_warehouse_result:=public.save_inventory_warehouse(NULL::uuid,NULL::bigint,
    'Backoffice Runtime Test Warehouse'::text,'STORE'::text,v_store,
    'Rollback fixture'::text,true,false,true);
  v_warehouse:=(v_warehouse_result->'data'->>'id')::uuid;
  v_product_result:=public.save_product_with_uoms(NULL::uuid,NULL::bigint,
    'BO-RUNTIME-TEST'::text,'Backoffice Runtime Test Product'::text,
    v_category,v_uom,v_uom,1::numeric,false,NULL::text,true,
    jsonb_build_array(jsonb_build_object(
      'uomId',v_uom,'factorToBase',1,'purchaseAllowed',true,
      'salesAllowed',true,'purchasePrice',10000,'salePrice',15000,'isActive',true)));
  v_product:=(v_product_result->>'productId')::uuid;
  SELECT product_uom.id INTO STRICT v_product_uom FROM public.product_uoms product_uom
  WHERE product_uom.company_id=v_company AND product_uom.product_id=v_product
    AND product_uom.uom_id=v_uom;

  SELECT jsonb_build_object(
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events)
  ) INTO v_before;
  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'orderDate',DATE '2026-09-08',
    'plannedDeliveryDate',DATE '2026-09-10','isTempo',true,
    'dueDate',DATE '2026-09-30','currencyCode','IDR','notes','Rollback behavior',
    'lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',2)));

  v_create:=public.save_backoffice_sales_order_draft(NULL,NULL,v_save_op,v_payload);
  v_order:=(v_create->'data'->>'id')::uuid;
  v_version:=(v_create->'data'->>'masterVersion')::bigint;
  IF v_create->'data'->>'status'<>'DRAFT' OR (v_create->'data'->>'grandTotal')::numeric<>30000 THEN
    RAISE EXCEPTION 'TEST_FAILED: draft snapshot or server pricing invalid';
  END IF;
  v_retry:=public.save_backoffice_sales_order_draft(NULL,NULL,v_save_op,v_payload);
  IF (v_retry->>'exactRetry')::boolean IS DISTINCT FROM true
    OR v_retry->'data'->>'id'<>v_order::text THEN
    RAISE EXCEPTION 'TEST_FAILED: exact save retry invalid';
  END IF;
  BEGIN
    PERFORM public.save_backoffice_sales_order_draft(NULL,NULL,v_save_op,
      jsonb_set(v_payload,'{notes}','"different"'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%IDEMPOTENCY_PAYLOAD_CONFLICT%' THEN v_conflict_caught:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_conflict_caught THEN RAISE EXCEPTION 'TEST_FAILED: payload conflict accepted'; END IF;
  BEGIN
    PERFORM public.save_backoffice_sales_order_draft(v_order,v_version+99,
      gen_random_uuid(),v_payload);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%MASTER_VERSION_CONFLICT%' THEN v_stale_caught:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_stale_caught THEN RAISE EXCEPTION 'TEST_FAILED: stale version accepted'; END IF;

  v_send:=public.send_backoffice_sales_quotation(v_order,v_version,v_send_op);
  v_version:=(v_send->'data'->>'masterVersion')::bigint;
  IF v_send->'data'->>'status'<>'SENT' THEN RAISE EXCEPTION 'TEST_FAILED: send state'; END IF;
  v_confirm:=public.confirm_backoffice_sales_order(v_order,v_version,v_confirm_op);
  IF v_confirm->'data'->>'status'<>'CONFIRMED'
    OR nullif(v_confirm->'data'->>'orderNo','') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: confirm state';
  END IF;
  v_retry:=public.confirm_backoffice_sales_order(v_order,v_version,v_confirm_op);
  IF (v_retry->>'exactRetry')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'TEST_FAILED: confirm exact retry';
  END IF;

  v_cancel_create:=public.save_backoffice_sales_order_draft(
    NULL,NULL,v_cancel_save_op,jsonb_set(v_payload,'{notes}','"cancel path"'::jsonb));
  v_cancel_order:=(v_cancel_create->'data'->>'id')::uuid;
  v_cancel:=public.cancel_backoffice_sales_order(v_cancel_order,
    (v_cancel_create->'data'->>'masterVersion')::bigint,v_cancel_op,'Customer canceled');
  IF v_cancel->'data'->>'status'<>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: cancel state';
  END IF;

  SELECT jsonb_build_object(
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events)
  ) INTO v_after;
  IF v_after<>v_before THEN RAISE EXCEPTION 'TEST_FAILED: downstream effect detected'; END IF;
  IF (SELECT count(*) FROM public.backoffice_sales_order_operations
      WHERE company_id=v_company AND sales_order_id IN(v_order,v_cancel_order))<>5
    OR (SELECT count(*) FROM public.backoffice_sales_order_audit
      WHERE company_id=v_company AND sales_order_id IN(v_order,v_cancel_order))<>5 THEN
    RAISE EXCEPTION 'TEST_FAILED: operation/audit coverage';
  END IF;
  RAISE NOTICE 'BACKOFFICE_SALES_ORDER_RUNTIME_BEHAVIOR_PASS';
END
$test$;

ROLLBACK;
