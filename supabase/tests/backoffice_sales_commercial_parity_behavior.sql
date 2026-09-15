-- Authenticated rollback-only commercial behavior on isolated Development data.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_operation uuid:=gen_random_uuid();v_payload jsonb;
  v_preview jsonb;v_result jsonb;v_retry jsonb;v_before jsonb;v_after jsonb;
  v_conflict boolean:=false;
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE' AND EXISTS(SELECT 1 FROM public.stores store
    JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
      AND warehouse.is_active AND warehouse.is_sale_source
      AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
    WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed)
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_COMMERCIAL_TEST')
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
    'plannedDeliveryDate',DATE '2026-09-10','isTempo',false,'dueDate',NULL,
    'currencyCode','IDR','globalDiscount',1000,'roundingDirection','DOWN',
    'roundingIncrement',100,'lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',2,'overrideUnitPrice',20000,
      'lineDiscountType','PERCENT','lineDiscountInput',10)));
  v_preview:=public.preview_backoffice_sales_order_lines(
    v_store,v_customer,NULL,DATE '2026-09-09',v_payload->'lines');
  IF jsonb_array_length(v_preview->'lines')<>1
    OR (v_preview->'lines'->0->>'canonicalUnitPrice')::numeric<0 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical preview invalid';
  END IF;

  v_result:=public.save_backoffice_sales_order_draft(NULL,NULL,v_operation,v_payload);
  IF (v_result->'data'->'lines'->0->>'unitPrice')::numeric<>20000
    OR (v_result->'data'->'lines'->0->>'canonicalUnitPrice')::numeric<0
    OR NOT (v_result->'data'->'lines'->0->>'priceOverrideApplied')::boolean
    OR (v_result->'data'->'lines'->0->>'lineDiscountAmount')::numeric<>4000
    OR (v_result->'data'->>'globalDiscount')::numeric<>1000
    OR (v_result->'data'->>'grandTotalBeforeRounding')::numeric<>35000
    OR (v_result->'data'->>'grandTotal')::numeric<>35000 THEN
    RAISE EXCEPTION 'TEST_FAILED: commercial calculation mismatch';
  END IF;
  v_retry:=public.save_backoffice_sales_order_draft(NULL,NULL,v_operation,v_payload);
  IF NOT COALESCE((v_retry->>'exactRetry')::boolean,false)
    OR v_retry->'data'<>v_result->'data' THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry snapshot mismatch';
  END IF;
  BEGIN
    PERFORM public.save_backoffice_sales_order_draft(NULL,NULL,v_operation,
      jsonb_set(v_payload,'{globalDiscount}','2000'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%IDEMPOTENCY_PAYLOAD_CONFLICT%' THEN v_conflict:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_conflict THEN RAISE EXCEPTION 'TEST_FAILED: payload conflict accepted'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_operations operation
    WHERE operation.company_id=v_company AND operation.operation_id=v_operation
      AND operation.response_snapshot->'data'=v_result->'data')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_audit audit
      WHERE audit.company_id=v_company AND audit.operation_id=v_operation
        AND audit.after_state=v_result->'data') THEN
    RAISE EXCEPTION 'TEST_FAILED: immutable operation or audit snapshot is not final';
  END IF;

  SELECT jsonb_build_object(
    'reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'payments',(SELECT count(*) FROM public.sales_payment_verification_requests),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_after;
  IF v_after<>v_before THEN RAISE EXCEPTION 'TEST_FAILED: downstream effect detected'; END IF;
  RAISE NOTICE 'BACKOFFICE_SALES_COMMERCIAL_PARITY_BEHAVIOR_PASS';
END
$test$;
ROLLBACK;
