-- Authenticated rollback-only behavior for Step 4/6.5A foundation.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_customer_category uuid;v_product_uom uuid;v_today date;v_original_negative boolean;
  v_created jsonb;v_confirmed jsonb;v_payload jsonb;v_class jsonb;
  v_order_id uuid;v_order_line_id uuid;v_failed boolean:=false;v_fixture_code text;
  v_split boolean;v_expected_accepted numeric;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912110000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Warehouse resolution foundation required';
  END IF;
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912137000') INTO v_split;
  v_expected_accepted:=CASE WHEN v_split THEN 4 ELSE 5 END;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    product_uom.id,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_original_negative,v_product_uom,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed
    AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active
    AND NOT product.is_bundle AND product.uom_id=product_uom.uom_id
  WHERE company.status='ACTIVE'
  ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Company, Store, Warehouse and Product-UOM required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
    AND NOT customer.is_system_customer ORDER BY customer.id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT category.id INTO v_customer_category FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.is_system_category DESC,category.id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Customer Category required';
    END IF;
    v_fixture_code:='WHRES-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_created:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
      'Warehouse Resolution Rollback Customer',v_customer_category,NULL,NULL,NULL,
      'BUSINESS',0,NULL,'Rollback-only Warehouse resolution fixture',TRUE,NULL,NULL);
    v_customer:=(v_created->>'customerId')::uuid;
  END IF;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  -- Rollback-only preparation; operational RPCs run with the setup marker cleared.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company sales process setting required';
  END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(
    v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
      'quantity',4,'overrideUnitPrice',50000)));
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_order_id:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order_id,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO STRICT v_order_line_id FROM public.backoffice_sales_order_lines
  WHERE company_id=v_company AND sales_order_id=v_order_id;

  BEGIN
    UPDATE public.backoffice_sales_order_lines SET accepted_base_qty=5
    WHERE company_id=v_company AND id=v_order_line_id;
  EXCEPTION WHEN check_violation THEN
    v_failed:=SQLERRM LIKE '%backoffice_sales_order_lines_invoiceable_quantity_check%';
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: unapproved accepted overage passed quantity guard';
  END IF;

  UPDATE public.backoffice_sales_order_lines
  SET accepted_base_qty=v_expected_accepted,approved_overage_base_qty=1
  WHERE company_id=v_company AND id=v_order_line_id;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND id=v_order_line_id
      AND ordered_base_qty=4 AND accepted_base_qty=v_expected_accepted
      AND approved_overage_base_qty=1 AND to_invoice_base_qty=v_expected_accepted) THEN
    RAISE EXCEPTION 'TEST_FAILED: installed-version approved overage quantity ledger invalid';
  END IF;

  v_failed:=false;
  BEGIN
    UPDATE public.backoffice_sales_order_lines
    SET accepted_base_qty=v_expected_accepted+1,approved_overage_base_qty=1
    WHERE company_id=v_company AND id=v_order_line_id;
  EXCEPTION WHEN check_violation THEN
    v_failed:=SQLERRM LIKE '%backoffice_sales_order_lines_invoiceable_quantity_check%';
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: regular accepted quantity exceeded ordered quantity boundary';
  END IF;

  v_class:=private.classify_backoffice_sales_discrepancy(
    'OVERAGE','ACCEPT_OVERAGE',NULL);
  IF (v_class->>'requiresSalesApproval')::boolean IS NOT TRUE
    OR (v_class->>'requiresWarehouseResolution')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted overage approval/resolution classifier invalid %',v_class;
  END IF;
  IF to_regprocedure('public.resolve_backoffice_sales_delivery_discrepancy(uuid,bigint,uuid,date,text)')
    IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: operational Warehouse resolution was activated by foundation';
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_warehouse_resolution_foundation_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'unapproved accepted overage rejected','approved overage quantity bounded',
    'installed-version quantity contract tested only in rollback fixture',
    'excess beyond approval rejected','Sales and Warehouse approval both required',
    'no public Warehouse resolution runtime','all fixture writes rolled back']) details;
