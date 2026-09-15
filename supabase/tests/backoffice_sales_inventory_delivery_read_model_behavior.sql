-- Authenticated rollback-only behavior for Backoffice Delivery visibility.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_created jsonb;v_confirmed jsonb;v_workspace jsonb;
  v_order_id uuid;v_delivery_id uuid;v_delivery_no text;v_row jsonb;v_line jsonb;
  v_before jsonb;v_after jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909149000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Backoffice Delivery read migration required';
  END IF;
  SELECT profile.id INTO STRICT v_actor
  FROM auth.users user_row
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
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
       AND product.id=product_uom.product_id AND product.is_active
       AND NOT product.is_bundle
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed AND product_uom.factor_to_base>0)
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),
      updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE
    SET is_enabled=true,updated_by=excluded.updated_by;
  SELECT store.id,warehouse.id INTO STRICT v_store,v_warehouse
  FROM public.stores store
  JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  WHERE store.company_id=v_company AND store.status='ACTIVE'
  ORDER BY warehouse.store_id NULLS LAST,store.id,warehouse.id LIMIT 1;
  SELECT id INTO STRICT v_customer FROM public.customers
  WHERE company_id=v_company AND is_active
  ORDER BY is_system_customer DESC,id LIMIT 1;
  SELECT product_uom.id INTO STRICT v_product_uom
  FROM public.product_uoms product_uom
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
    AND NOT product.is_bundle
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed AND product_uom.factor_to_base>0
  ORDER BY product_uom.id LIMIT 1;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
      'customerId',v_customer,'selectedPricelistId',NULL,
      'orderDate',current_date,'plannedDeliveryDate',current_date+1,
      'isTempo',false,'currencyCode','IDR','globalDiscount',0,
      'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object(
        'productUomId',v_product_uom,'quantity',1))));
  v_order_id:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order_id,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery_id:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  v_delivery_no:=v_confirmed->'fulfillment'->>'deliveryNo';

  SELECT jsonb_build_object(
    'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
    'reservations',(SELECT count(*) FROM public.backoffice_sales_reservations),
    'deliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders),
    'audits',(SELECT count(*) FROM public.backoffice_sales_fulfillment_audit),
    'stocks',(SELECT count(*) FROM public.product_stocks),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_before;
  v_workspace:=public.get_inventory_backoffice_delivery_orders(
    current_date,current_date+2);
  SELECT item INTO STRICT v_row FROM jsonb_array_elements(v_workspace->'data') item
  WHERE item->>'deliveryDocumentId'=v_delivery_id::text;
  SELECT item INTO STRICT v_line FROM jsonb_array_elements(v_workspace->'lines') item
  WHERE item->>'delivery_document_id'=v_delivery_id::text;
  SELECT jsonb_build_object(
    'orders',(SELECT count(*) FROM public.backoffice_sales_orders),
    'reservations',(SELECT count(*) FROM public.backoffice_sales_reservations),
    'deliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders),
    'audits',(SELECT count(*) FROM public.backoffice_sales_fulfillment_audit),
    'stocks',(SELECT count(*) FROM public.product_stocks),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_after;

  IF (v_workspace->>'workspaceVersion')::integer<>1
    OR COALESCE((v_workspace->>'operationsReady')::boolean,true)
    OR v_row->>'sourceChannel'<>'BACKOFFICE_SALES'
    OR v_row->>'salesId'<>v_order_id::text
    OR v_row->>'deliveryNo'<>v_delivery_no
    OR v_row->>'deliveryKind'<>'INITIAL'
    OR v_row->>'status'<>'READY'
    OR COALESCE((v_row->>'operationsReady')::boolean,true)
    OR v_row->>'scheduledAt'<>(current_date+1)::text THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Delivery header read invalid';
  END IF;
  IF (v_line->>'quantity_uom')::numeric<>1
    OR (v_line->>'remaining_quantity_uom')::numeric<>1
    OR (v_line->>'shipped_base_qty')::numeric<>0
    OR (v_line->>'received_base_qty')::numeric<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Delivery line read invalid';
  END IF;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Delivery read mutated business state % -> %',
      v_before,v_after;
  END IF;
END
$test$;
ROLLBACK;

SELECT 'backoffice_sales_inventory_delivery_read_model_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'canonical Confirm creates source fixture','Inventory permission-scoped read',
    'INITIAL READY Delivery header','planned and remaining line quantity',
    'operations fail-closed','read has zero business mutation',
    'all fixture writes rolled back'],'writesPersisted',false) details;
