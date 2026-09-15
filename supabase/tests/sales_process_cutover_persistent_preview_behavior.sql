-- Authenticated rollback-only behavior for persistent, version-locked preview plans.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_order uuid:=gen_random_uuid();v_operation uuid:=gen_random_uuid();
  v_other_operation uuid:=gen_random_uuid();v_plan jsonb;v_retry jsonb;v_read jsonb;
  v_version bigint;v_blocked boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910110000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: persistent preview runtime required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  SELECT setting.company_id,store.id,warehouse.id,customer.id
  INTO v_company,v_store,v_warehouse,v_customer
  FROM public.company_sales_process_settings setting
  JOIN public.companies company ON company.id=setting.company_id AND company.status='ACTIVE'
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.customers customer ON customer.company_id=company.id AND customer.is_active
  ORDER BY setting.company_id,store.id,warehouse.id,customer.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: enabled Backoffice Company with canonical Store/Warehouse/Customer required';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE
    SET is_enabled=true,updated_by=excluded.updated_by;
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at=clock_timestamp(),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  SELECT master_version INTO STRICT v_version FROM public.company_sales_process_settings
  WHERE company_id=v_company;

  INSERT INTO public.backoffice_sales_orders(id,company_id,store_id,warehouse_id,
    customer_id,quotation_no,status,order_date,planned_delivery_date,is_tempo,
    currency_code,customer_snapshot,commercial_snapshot,created_by,updated_by)
  VALUES(v_order,v_company,v_store,v_warehouse,v_customer,
    'QTN-PLAN-'||substr(replace(v_order::text,'-',''),1,12),'DRAFT',current_date,
    current_date,false,'IDR',jsonb_build_object('id',v_customer,'name','Cutover Plan'),
    '{}',v_actor,v_actor);

  BEGIN
    PERFORM public.create_sales_process_cutover_plan('RETAIL_CONFIRM_INVOICE',
      clock_timestamp()+interval '1 day',v_version+1,gen_random_uuid(),'Stale version');
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_SETTINGS_VERSION_STALE%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale settings version accepted'; END IF;
  v_blocked:=false;

  v_plan:=public.create_sales_process_cutover_plan('RETAIL_CONFIRM_INVOICE',
    clock_timestamp()+interval '1 day',v_version,v_operation,'Behavior persistent preview');
  IF v_plan->>'status'<>'PREVIEWED'
    OR (v_plan->>'expectedSettingsVersion')::bigint<>v_version
    OR v_plan->>'operationId'<>v_operation::text
    OR jsonb_array_length(v_plan->'items')<1
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_plan->'items') item
      WHERE item->>'sourceDocumentId'=v_order::text
        AND (item->>'sourceMasterVersion')::bigint=1
        AND item->>'decision'='CONVERT') THEN
    RAISE EXCEPTION 'TEST_FAILED: persisted plan/versioned item contract invalid';
  END IF;
  IF (SELECT count(*) FROM public.sales_process_cutover_audit audit
      WHERE audit.company_id=v_company AND audit.cutover_plan_id=(v_plan->>'planId')::uuid
        AND audit.action='CREATE_PLAN' AND audit.operation_id=v_operation)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: immutable CREATE_PLAN audit missing';
  END IF;

  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  v_retry:=public.create_sales_process_cutover_plan('RETAIL_CONFIRM_INVOICE',
    (v_plan->>'effectiveAt')::timestamptz,v_version,v_operation,'Behavior persistent preview');
  IF v_retry->>'planId'<>v_plan->>'planId'
    OR (SELECT count(*) FROM public.sales_process_cutover_plans plan
      WHERE plan.company_id=v_company AND plan.operation_id=v_operation)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact operation retry was not idempotent';
  END IF;

  v_read:=public.get_sales_process_cutover_plan((v_plan->>'planId')::uuid);
  IF v_read->>'planId'<>v_plan->>'planId'
    OR COALESCE((v_read->>'readOnlyPlanView')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: plan read contract invalid';
  END IF;

  BEGIN
    PERFORM public.create_sales_process_cutover_plan('RETAIL_CONFIRM_INVOICE',
      (v_plan->>'effectiveAt')::timestamptz,v_version,v_operation,'Different payload');
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: operation payload conflict accepted'; END IF;

  v_blocked:=false;
  BEGIN
    PERFORM public.create_sales_process_cutover_plan('RETAIL_CONFIRM_INVOICE',
      clock_timestamp()+interval '2 days',v_version+1,v_other_operation,'Second open plan');
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_OPEN_PLAN_EXISTS%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: second open Company plan accepted'; END IF;

  PERFORM set_config('request.jwt.claim.sub','',true);
  v_blocked:=false;
  BEGIN
    PERFORM public.get_sales_process_cutover_plan((v_plan->>'planId')::uuid);
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%AUTHENTICATION_REQUIRED%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: unauthenticated plan read accepted'; END IF;
END
$test$;
ROLLBACK;
SELECT 'sales_process_cutover_persistent_preview_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'actual Backoffice Draft persisted with exact source master version',
    'settings version captured','stale settings version rejected',
    'CREATE_PLAN audit written','exact retry survives later settings-version drift',
    'payload conflict rejected','second open Company plan rejected',
    'authenticated plan read','unauthenticated caller rejected',
    'all fixture and plan writes rolled back']) details;
