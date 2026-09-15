-- Authenticated, rollback-only behavior for same-number SO revision and filters.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_create_operation uuid:=gen_random_uuid();
  v_confirm_operation uuid:=gen_random_uuid();v_revision_operation uuid:=gen_random_uuid();
  v_payload jsonb;v_created jsonb;v_confirmed jsonb;v_revised jsonb;v_retry jsonb;
  v_cancel_created jsonb;v_cancel_confirmed jsonb;v_canceled jsonb;
  v_list jsonb;v_before jsonb;v_after jsonb;v_blocked boolean:=false;
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
        AND warehouse.is_active AND warehouse.is_sale_source
        AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.customers customer WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed)
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_REVISION_STATUS_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  SELECT id INTO STRICT v_store FROM public.stores WHERE company_id=v_company
    AND status='ACTIVE' ORDER BY id LIMIT 1;
  SELECT id INTO STRICT v_warehouse FROM public.warehouses WHERE company_id=v_company
    AND is_active AND is_sale_source AND (store_id IS NULL OR store_id=v_store)
    ORDER BY store_id NULLS LAST,id LIMIT 1;
  SELECT id INTO STRICT v_customer FROM public.customers WHERE company_id=v_company
    AND is_active ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT product_uom.id INTO STRICT v_product_uom FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed ORDER BY product_uom.id LIMIT 1;

  SELECT jsonb_build_object(
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'payments',(SELECT count(*) FROM public.sales_payment_verification_requests),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_before;

  v_payload:=jsonb_build_object(
    'storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
    'selectedPricelistId',NULL,'orderDate',DATE '2026-09-09',
    'plannedDeliveryDate',DATE '2026-09-10','isTempo',true,
    'dueDate',DATE '2026-09-23','currencyCode','IDR','globalDiscount',0,
    'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',1)));
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,v_create_operation,v_payload);
  v_confirmed:=public.confirm_backoffice_sales_order(
    (v_created->'data'->>'id')::uuid,(v_created->'data'->>'masterVersion')::bigint,
    v_confirm_operation);
  IF v_confirmed->'data'->>'fulfillmentStatus'<>'CONFIRMED'
    OR v_confirmed->'data'->>'orderNo' IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: confirmed fulfillment state invalid';
  END IF;

  v_payload:=jsonb_set(v_payload,'{lines,0,quantity}','2'::jsonb)
    ||jsonb_build_object('revisionReason','Customer menambah jumlah');
  v_revised:=public.save_backoffice_sales_order_draft(
    (v_confirmed->'data'->>'id')::uuid,(v_confirmed->'data'->>'masterVersion')::bigint,
    v_revision_operation,v_payload);
  IF v_revised->'data'->>'orderNo'<>v_confirmed->'data'->>'orderNo'
    OR v_revised->'data'->>'quotationNo'<>v_confirmed->'data'->>'quotationNo'
    OR v_revised->'data'->>'status'<>'CONFIRMED'
    OR (v_revised->'data'->>'revisionCount')::bigint<>1
    OR (v_revised->'data'->'lines'->0->>'orderedQty')::numeric<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: same-number revision contract invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_audit audit
    WHERE audit.company_id=v_company AND audit.operation_id=v_revision_operation
      AND audit.action='REVISE' AND audit.reason='Customer menambah jumlah') THEN
    RAISE EXCEPTION 'TEST_FAILED: revision audit missing';
  END IF;
  v_retry:=public.save_backoffice_sales_order_draft(
    (v_confirmed->'data'->>'id')::uuid,(v_confirmed->'data'->>'masterVersion')::bigint,
    v_revision_operation,v_payload);
  IF NOT COALESCE((v_retry->>'exactRetry')::boolean,false)
    OR v_retry->'data'<>v_revised->'data' THEN
    RAISE EXCEPTION 'TEST_FAILED: revision exact retry invalid';
  END IF;

  v_list:=public.get_backoffice_sales_orders_v2('SALES_ORDER','CONFIRMED',
    'ORDER_DATE',DATE '2026-09-09',DATE '2026-09-09',NULL,500);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_list->'data') item
    WHERE item->>'id'=v_revised->'data'->>'id') THEN
    RAISE EXCEPTION 'TEST_FAILED: Sales Order filter did not return revised SO';
  END IF;

  v_cancel_created:=public.save_backoffice_sales_order_draft(
    NULL,NULL,gen_random_uuid(),v_payload-'revisionReason');
  v_cancel_confirmed:=public.confirm_backoffice_sales_order(
    (v_cancel_created->'data'->>'id')::uuid,
    (v_cancel_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_canceled:=public.cancel_backoffice_sales_order(
    (v_cancel_confirmed->'data'->>'id')::uuid,
    (v_cancel_confirmed->'data'->>'masterVersion')::bigint,gen_random_uuid(),
    'Customer membatalkan sebelum persiapan');
  IF v_canceled->'data'->>'status'<>'CANCELED'
    OR v_canceled->'data'->>'fulfillmentStatus'<>'CANCELED'
    OR v_canceled->'data'->>'orderNo'<>v_cancel_confirmed->'data'->>'orderNo' THEN
    RAISE EXCEPTION 'TEST_FAILED: guarded confirmed SO cancellation invalid';
  END IF;

  UPDATE public.backoffice_sales_orders SET fulfillment_status='IN_TRANSIT'
  WHERE company_id=v_company AND id=(v_revised->'data'->>'id')::uuid;
  BEGIN
    PERFORM public.save_backoffice_sales_order_draft(
      (v_revised->'data'->>'id')::uuid,(v_revised->'data'->>'masterVersion')::bigint,
      gen_random_uuid(),v_payload||jsonb_build_object('revisionReason','Harus ditolak'));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC%'
      THEN v_blocked:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: in-transit revision accepted'; END IF;

  SELECT jsonb_build_object(
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'payments',(SELECT count(*) FROM public.sales_payment_verification_requests),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_after;
  IF v_after<>v_before THEN RAISE EXCEPTION 'TEST_FAILED: downstream effect detected'; END IF;
  RAISE NOTICE 'BACKOFFICE_SALES_REVISION_STATUS_BEHAVIOR_PASS';
END
$test$;
ROLLBACK;
