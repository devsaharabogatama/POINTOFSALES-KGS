-- Rollback-only authenticated behavior for plan refresh/cancel.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_order uuid:=gen_random_uuid();v_create_op uuid:=gen_random_uuid();
  v_refresh_op uuid:=gen_random_uuid();v_cancel_op uuid:=gen_random_uuid();
  v_plan jsonb;v_refreshed jsonb;v_retry jsonb;v_canceled jsonb;
  v_settings_version bigint;v_blocked boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260910120000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: refresh/cancel runtime required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT setting.company_id,store.id,warehouse.id,customer.id
  INTO v_company,v_store,v_warehouse,v_customer
  FROM public.company_sales_process_settings setting
  JOIN public.companies company ON company.id=setting.company_id AND company.status='ACTIVE'
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  WHERE NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_plans plan
    WHERE plan.company_id=setting.company_id AND plan.status IN('DRAFT','PREVIEWED','APPLYING'))
  ORDER BY setting.company_id,store.id,warehouse.id,customer.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Super Admin/Company fixture required';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
    WHERE company_id=v_company AND status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: selected fixture Company has open cutover plan';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE
    SET is_enabled=true,updated_by=excluded.updated_by;
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',
    mode_effective_at=clock_timestamp(),master_version=master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp() WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  SELECT master_version INTO STRICT v_settings_version
  FROM public.company_sales_process_settings WHERE company_id=v_company;
  INSERT INTO public.backoffice_sales_orders(id,company_id,store_id,warehouse_id,customer_id,
    quotation_no,status,order_date,planned_delivery_date,is_tempo,currency_code,
    customer_snapshot,commercial_snapshot,created_by,updated_by)
  VALUES(v_order,v_company,v_store,v_warehouse,v_customer,
    'QTN-REFRESH-'||substr(replace(v_order::text,'-',''),1,10),'DRAFT',current_date,
    current_date,false,'IDR',jsonb_build_object('id',v_customer,'name','Refresh Test'),
    '{}',v_actor,v_actor);
  v_plan:=public.create_sales_process_cutover_plan('RETAIL_CONFIRM_INVOICE',
    clock_timestamp()+interval '1 day',v_settings_version,v_create_op,'Locked plan fields');
  IF (v_plan->>'masterVersion')::bigint<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: initial plan version invalid';
  END IF;
  UPDATE public.backoffice_sales_orders SET notes='Refresh version evidence',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_order;
  v_refreshed:=public.refresh_sales_process_cutover_plan((v_plan->>'planId')::uuid,1,
    v_settings_version,v_refresh_op);
  IF (v_refreshed->>'masterVersion')::bigint<>2
    OR v_refreshed->>'targetMode'<>v_plan->>'targetMode'
    OR v_refreshed->>'effectiveAt'<>v_plan->>'effectiveAt'
    OR v_refreshed->>'reason'<>v_plan->>'reason'
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_refreshed->'items') item
      WHERE item->>'sourceDocumentId'=v_order::text
        AND (item->>'sourceMasterVersion')::bigint=2) THEN
    RAISE EXCEPTION 'TEST_FAILED: refresh/version-lock contract invalid';
  END IF;
  v_retry:=public.refresh_sales_process_cutover_plan((v_plan->>'planId')::uuid,1,
    v_settings_version,v_refresh_op);
  IF v_retry<>v_refreshed THEN RAISE EXCEPTION 'TEST_FAILED: refresh retry not exact'; END IF;
  BEGIN
    PERFORM public.refresh_sales_process_cutover_plan((v_plan->>'planId')::uuid,1,
      v_settings_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_PLAN_VERSION_STALE%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale refresh accepted'; END IF;
  v_canceled:=public.cancel_sales_process_cutover_plan((v_plan->>'planId')::uuid,2,
    v_cancel_op,'Plan parameters must change');
  IF v_canceled->>'status'<>'CANCELED' OR (v_canceled->>'masterVersion')::bigint<>3
    OR v_canceled->>'targetMode'<>v_plan->>'targetMode'
    OR v_canceled->>'effectiveAt'<>v_plan->>'effectiveAt'
    OR jsonb_array_length(v_canceled->'items')<>jsonb_array_length(v_refreshed->'items') THEN
    RAISE EXCEPTION 'TEST_FAILED: cancel/history contract invalid';
  END IF;
  v_retry:=public.cancel_sales_process_cutover_plan((v_plan->>'planId')::uuid,2,
    v_cancel_op,'Plan parameters must change');
  IF v_retry<>v_canceled THEN RAISE EXCEPTION 'TEST_FAILED: cancel retry not exact'; END IF;
  v_blocked:=false;
  BEGIN
    PERFORM public.cancel_sales_process_cutover_plan((v_plan->>'planId')::uuid,2,
      v_cancel_op,'Different cancel payload');
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: cancel payload conflict accepted'; END IF;
  v_blocked:=false;
  BEGIN
    PERFORM public.refresh_sales_process_cutover_plan((v_plan->>'planId')::uuid,3,
      v_settings_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_PLAN_NOT_REFRESHABLE%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: canceled plan refresh accepted'; END IF;
END
$test$;
ROLLBACK;
SELECT 'sales_process_cutover_plan_refresh_cancel_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'actual source version refreshed','plan version increments','target/effective/reason locked',
    'exact refresh retry','stale refresh rejected','cancel retains items/history',
    'exact cancel retry','cancel payload conflict rejected','canceled refresh rejected',
    'all fixture writes rolled back']) details;
