-- Rollback-only behavior for Backoffice quantity-to-invoice ledger foundation.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_created jsonb;v_order_id uuid;v_line_id uuid;
  v_ordered numeric;v_failed boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909152000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Customer receipt foundation required';
  END IF;
  SELECT profile.id INTO STRICT v_actor
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,customer.id,product_uom.id
  INTO STRICT v_company,v_store,v_warehouse,v_customer,v_product_uom
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base>0
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
  WHERE company.status='ACTIVE'
  ORDER BY company.id,store.id,warehouse.id,customer.is_system_customer DESC,
    customer.id,product_uom.id LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;

  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
      'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',current_date,
      'plannedDeliveryDate',current_date+1,'isTempo',false,'currencyCode','IDR',
      'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object(
        'productUomId',v_product_uom,'quantity',4))));
  v_order_id:=(v_created->'data'->>'id')::uuid;
  SELECT id,ordered_base_qty INTO STRICT v_line_id,v_ordered
  FROM public.backoffice_sales_order_lines
  WHERE company_id=v_company AND sales_order_id=v_order_id;

  IF EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=v_company AND line.id=v_line_id
      AND (line.accepted_base_qty<>0 OR line.net_delivered_base_qty<>0
        OR line.to_invoice_base_qty<>0)) THEN
    RAISE EXCEPTION 'TEST_FAILED: new Order line received nonzero delivery ledger';
  END IF;

  UPDATE public.backoffice_sales_order_lines SET accepted_base_qty=v_ordered/2
  WHERE company_id=v_company AND id=v_line_id;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=v_company AND line.id=v_line_id
      AND line.net_delivered_base_qty=v_ordered/2
      AND line.to_invoice_base_qty=v_ordered/2) THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted quantity did not become Qty To Invoice';
  END IF;

  UPDATE public.backoffice_sales_order_lines SET
    returned_before_invoice_base_qty=v_ordered/4,
    draft_invoice_allocated_base_qty=v_ordered/4
  WHERE company_id=v_company AND id=v_line_id;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=v_company AND line.id=v_line_id
      AND line.net_delivered_base_qty=v_ordered/4
      AND line.to_invoice_base_qty=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: Return/Draft allocation quantity formula invalid';
  END IF;

  BEGIN
    UPDATE public.backoffice_sales_order_lines SET invoiced_base_qty=v_ordered/4
    WHERE company_id=v_company AND id=v_line_id;
  EXCEPTION WHEN check_violation THEN v_failed:=true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: over-allocation beyond Net Delivered accepted';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_customer_receipt_foundation_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'new line zero ledger','accepted becomes Qty To Invoice',
    'pre-Invoice Return reduces Net Delivered','Draft allocation holds Qty To Invoice',
    'over-allocation rejected','all fixture writes rolled back']) details;
