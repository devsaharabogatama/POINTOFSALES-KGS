-- Rollback-only structural behavior for Backoffice Reservation and multi-DO lineage.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_order jsonb;v_confirmed jsonb;v_order_id uuid;
  v_order_line public.backoffice_sales_order_lines%rowtype;
  v_reservation uuid:=gen_random_uuid();v_delivery uuid:=gen_random_uuid();
  v_backorder uuid:=gen_random_uuid();v_reservation_line uuid:=gen_random_uuid();
  v_before jsonb;v_after jsonb;v_audit_id bigint;v_immutable boolean:=false;
  v_payload jsonb;
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
    AND EXISTS(SELECT 1 FROM public.customers customer
      WHERE customer.company_id=company.id AND customer.is_active)
    AND EXISTS(SELECT 1 FROM public.product_uoms product_uom
      JOIN public.products product ON product.company_id=product_uom.company_id
        AND product.id=product_uom.product_id AND product.is_active
      WHERE product_uom.company_id=company.id AND product_uom.is_active
        AND product_uom.sales_allowed)
  ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company)
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();
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
  WHERE product_uom.company_id=v_company AND product_uom.is_active
    AND product_uom.sales_allowed ORDER BY product_uom.id LIMIT 1;

  SELECT jsonb_build_object(
    'retailReservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'retailDeliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_before;

  v_payload:=jsonb_build_object(
    'storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
    'selectedPricelistId',NULL,'orderDate',DATE '2026-09-09',
    'plannedDeliveryDate',DATE '2026-09-10','isTempo',false,
    'currencyCode','IDR','globalDiscount',0,'roundingDirection','NONE',
    'roundingIncrement',100,'lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',2)));
  v_order:=public.save_backoffice_sales_order_draft(
    NULL,NULL,gen_random_uuid(),v_payload);
  v_confirmed:=public.confirm_backoffice_sales_order(
    (v_order->'data'->>'id')::uuid,
    (v_order->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_order_id:=(v_confirmed->'data'->>'id')::uuid;
  SELECT * INTO STRICT v_order_line FROM public.backoffice_sales_order_lines
  WHERE company_id=v_company AND sales_order_id=v_order_id;

  INSERT INTO public.backoffice_sales_reservations(
    id,company_id,sales_order_id,warehouse_id,total_ordered_base_qty,
    total_reserved_base_qty,created_by,updated_by)
  VALUES(v_reservation,v_company,v_order_id,v_warehouse,
    v_order_line.ordered_base_qty,v_order_line.ordered_base_qty,v_actor,v_actor);
  INSERT INTO public.backoffice_sales_reservation_lines(
    id,company_id,reservation_id,sales_order_id,sales_order_line_id,product_id,
    warehouse_id,ordered_base_qty,reserved_base_qty)
  VALUES(v_reservation_line,v_company,v_reservation,v_order_id,v_order_line.id,
    v_order_line.product_id,v_warehouse,v_order_line.ordered_base_qty,
    v_order_line.ordered_base_qty);

  INSERT INTO public.backoffice_sales_delivery_orders(
    id,company_id,sales_order_id,reservation_id,delivery_no,sequence_no,
    scheduled_date,recipient_snapshot,
    total_planned_base_qty,created_by,updated_by)
  VALUES(v_delivery,v_company,v_order_id,v_reservation,
    'BODO-TEST-'||replace(v_delivery::text,'-',''),1,
    DATE '2026-09-10',v_confirmed->'data'->'customerSnapshot',
    v_order_line.ordered_base_qty,v_actor,v_actor);
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders
    WHERE company_id=v_company AND id=v_delivery
      AND delivery_kind='INITIAL' AND status='READY'
      AND parent_delivery_order_id IS NULL) THEN
    RAISE EXCEPTION 'TEST_FAILED: Initial Delivery default contract invalid';
  END IF;
  INSERT INTO public.backoffice_sales_delivery_order_lines(
    company_id,delivery_order_id,sales_order_id,reservation_id,
    reservation_line_id,sales_order_line_id,line_no,product_id,uom_id,
    product_code_snapshot,product_name_snapshot,uom_code_snapshot,
    uom_name_snapshot,base_qty_per_uom,planned_qty_uom,planned_base_qty)
  VALUES(v_company,v_delivery,v_order_id,v_reservation,v_reservation_line,
    v_order_line.id,1,v_order_line.product_id,v_order_line.uom_id,
    v_order_line.product_code_snapshot,v_order_line.product_name_snapshot,
    v_order_line.uom_code_snapshot,v_order_line.uom_name_snapshot,
    v_order_line.base_qty_per_uom,v_order_line.ordered_qty,
    v_order_line.ordered_base_qty);

  INSERT INTO public.backoffice_sales_delivery_orders(
    id,company_id,sales_order_id,reservation_id,delivery_no,sequence_no,
    delivery_kind,parent_delivery_order_id,scheduled_date,
    recipient_snapshot,total_planned_base_qty,created_by,updated_by)
  VALUES(v_backorder,v_company,v_order_id,v_reservation,
    'BODO-TEST-'||replace(v_backorder::text,'-',''),2,'BACKORDER',v_delivery,
    DATE '2026-09-11',v_confirmed->'data'->'customerSnapshot',
    v_order_line.ordered_base_qty,v_actor,v_actor);
  IF (SELECT count(*) FROM public.backoffice_sales_delivery_orders
      WHERE company_id=v_company AND sales_order_id=v_order_id)<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: one SO did not retain multiple Delivery Orders';
  END IF;

  INSERT INTO public.backoffice_sales_fulfillment_audit(
    company_id,sales_order_id,delivery_order_id,operation_id,action,actor_id,
    after_state)
  VALUES(v_company,v_order_id,v_delivery,gen_random_uuid(),'CREATE_DELIVERY',
    v_actor,jsonb_build_object('status','READY')) RETURNING id INTO v_audit_id;
  BEGIN
    UPDATE public.backoffice_sales_fulfillment_audit
    SET reason='must fail' WHERE id=v_audit_id;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%BACKOFFICE_SALES_FULFILLMENT_AUDIT_IMMUTABLE%'
      THEN v_immutable:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_immutable THEN
    RAISE EXCEPTION 'TEST_FAILED: fulfillment audit update accepted';
  END IF;

  SELECT jsonb_build_object(
    'retailReservations',(SELECT count(*) FROM public.sales_stock_reservations),
    'retailDeliveries',(SELECT count(*) FROM public.sales_delivery_documents),
    'invoices',(SELECT count(*) FROM public.sales_invoice_snapshots),
    'movements',(SELECT count(*) FROM public.stock_movements),
    'events',(SELECT count(*) FROM public.financial_events)) INTO v_after;
  IF v_after<>v_before THEN
    RAISE EXCEPTION 'TEST_FAILED: foundation changed retail or downstream rows';
  END IF;
  RAISE NOTICE 'BACKOFFICE_SALES_FULFILLMENT_FOUNDATION_BEHAVIOR_PASS';
END
$test$;
ROLLBACK;
