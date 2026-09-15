-- Rollback-only AUTO/explicit Pricelist behavior and downstream-isolation proof.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_customer uuid;v_category uuid;
  v_uom uuid;v_warehouse uuid;v_product uuid;v_product_uom uuid;v_pricelist uuid;
  v_result jsonb;v_payload jsonb;v_auto jsonb;v_explicit jsonb;v_retry jsonb;
  v_before jsonb;v_after jsonb;v_invalid_caught boolean:=false;
BEGIN
  SELECT profile.id INTO STRICT v_actor FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND (SELECT count(*) FROM public.pricelists pricelist
      WHERE pricelist.company_id=company.id AND pricelist.scope='GLOBAL'
        AND pricelist.is_default AND pricelist.is_active)=1
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_PRICELIST_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;

  SELECT id INTO STRICT v_store FROM public.stores
  WHERE company_id=v_company AND status='ACTIVE' ORDER BY id LIMIT 1;
  SELECT id INTO STRICT v_customer FROM public.customers
  WHERE company_id=v_company AND is_active ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT id INTO v_category FROM public.product_categories
  WHERE company_id=v_company AND is_active ORDER BY id LIMIT 1;
  IF v_category IS NULL THEN
    v_result:=public.save_inventory_product_category(NULL,NULL,'BO Pricelist Test Category',true);
    v_category:=(v_result->'data'->>'id')::uuid;
  END IF;
  v_result:=public.save_inventory_uom(
    NULL::uuid,NULL::bigint,'BO Pricelist Test Unit'::text,'UNIT'::text,
    false,0::smallint,true);
  v_uom:=(v_result->'data'->>'id')::uuid;
  v_result:=public.save_inventory_warehouse(NULL,NULL,'BO Pricelist Test Warehouse',
    'STORE',v_store,'Rollback fixture',true,false,true);
  v_warehouse:=(v_result->'data'->>'id')::uuid;
  v_result:=public.save_product_with_uoms(NULL,NULL,'BO-PL-TEST',
    'Backoffice Pricelist Test Product',v_category,v_uom,v_uom,1,false,NULL,true,
    jsonb_build_array(jsonb_build_object('uomId',v_uom,'factorToBase',1,
      'purchaseAllowed',true,'salesAllowed',true,'purchasePrice',9000,
      'salePrice',15000,'isActive',true)));
  v_product:=(v_result->>'productId')::uuid;
  SELECT id INTO STRICT v_product_uom FROM public.product_uoms
  WHERE company_id=v_company AND product_id=v_product AND uom_id=v_uom;
  SELECT id INTO STRICT v_pricelist FROM public.pricelists
  WHERE company_id=v_company AND scope='GLOBAL' AND is_default AND is_active;
  INSERT INTO public.pricelist_rules(company_id,pricelist_id,product_id,product_uom_id,
    min_qty,tier_qty_basis,pricing_method,fixed_unit_price,is_active,created_by,updated_by)
  VALUES(v_company,v_pricelist,v_product,v_product_uom,1,'SALES_UOM','FIXED_PRICE',12345,true,v_actor,v_actor);

  SELECT jsonb_build_object('reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_before;
  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',DATE '2026-09-09',
    'plannedDeliveryDate',DATE '2026-09-10','isTempo',false,'dueDate',NULL,
    'currencyCode','IDR','lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',2)));
  v_auto:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  IF v_auto->'data'->'lines'->0->'pricingSnapshot'->>'pricingSelectionSource'<>'AUTO' THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO Pricelist source not preserved';
  END IF;

  v_payload:=jsonb_set(v_payload,'{selectedPricelistId}',to_jsonb(v_pricelist::text));
  v_explicit:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  IF v_explicit->'data'->>'pricelistId'<>v_pricelist::text
    OR v_explicit->'data'->'lines'->0->'pricingSnapshot'->>'pricingSelectionSource'<>'BACKOFFICE_EXPLICIT'
    OR (v_explicit->'data'->'lines'->0->>'unitPrice')::numeric<>12345 THEN
    RAISE EXCEPTION 'TEST_FAILED: explicit Pricelist identity or price invalid';
  END IF;
  v_retry:=public.save_backoffice_sales_order_draft(NULL,NULL,
    gen_random_uuid(),v_payload||jsonb_build_object('notes','retry namespace'));
  IF v_retry->'data'->>'pricelistId'<>v_pricelist::text THEN
    RAISE EXCEPTION 'TEST_FAILED: repeated explicit selection drift';
  END IF;
  BEGIN
    PERFORM public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
      jsonb_set(v_payload,'{selectedPricelistId}',to_jsonb(gen_random_uuid()::text)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%PRICELIST_NOT_ELIGIBLE%' THEN v_invalid_caught:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_invalid_caught THEN RAISE EXCEPTION 'TEST_FAILED: ineligible Pricelist accepted'; END IF;

  SELECT jsonb_build_object('reservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'deliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_after;
  IF v_after<>v_before THEN RAISE EXCEPTION 'TEST_FAILED: downstream effect detected'; END IF;
  RAISE NOTICE 'BACKOFFICE_SALES_PRICELIST_HEADER_BEHAVIOR_PASS';
END
$test$;
ROLLBACK;
