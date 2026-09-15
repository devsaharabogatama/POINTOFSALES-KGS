-- Authenticated rollback-only behavior for actual-data cutover preview.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_order uuid:=gen_random_uuid();v_preview jsonb;v_before_plan bigint;v_before_item bigint;
  v_before_audit bigint;v_blocked boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909163000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: cutover preview runtime required';
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
    active_mode='RETAIL_CONFIRM_INVOICE',mode_effective_at=clock_timestamp(),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  v_preview:=public.get_sales_process_cutover_preview(
    'BACKOFFICE_DELIVERED_QTY_INVOICE');
  IF v_preview->>'currentMode'<>'RETAIL_CONFIRM_INVOICE'
    OR v_preview->>'targetMode'<>'BACKOFFICE_DELIVERED_QTY_INVOICE'
    OR COALESCE((v_preview->>'readOnly')::boolean,false) IS NOT TRUE
    OR jsonb_typeof(v_preview->'candidates')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: Retail to Office preview contract invalid';
  END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at=clock_timestamp(),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  INSERT INTO public.backoffice_sales_orders(id,company_id,store_id,warehouse_id,
    customer_id,quotation_no,status,order_date,planned_delivery_date,is_tempo,
    currency_code,customer_snapshot,commercial_snapshot,created_by,updated_by)
  VALUES(v_order,v_company,v_store,v_warehouse,v_customer,
    'QTN-CUTOVER-'||substr(replace(v_order::text,'-',''),1,12),'DRAFT',current_date,
    current_date,false,'IDR',jsonb_build_object('id',v_customer,'name','Cutover Preview'),
    '{}',v_actor,v_actor);
  SELECT count(*) INTO v_before_plan FROM public.sales_process_cutover_plans;
  SELECT count(*) INTO v_before_item FROM public.sales_process_cutover_items;
  SELECT count(*) INTO v_before_audit FROM public.sales_process_cutover_audit;
  v_preview:=public.get_sales_process_cutover_preview('RETAIL_CONFIRM_INVOICE');
  IF v_preview->>'currentMode'<>'BACKOFFICE_DELIVERED_QTY_INVOICE'
    OR v_preview->>'targetMode'<>'RETAIL_CONFIRM_INVOICE'
    OR COALESCE((v_preview->>'readOnly')::boolean,false) IS NOT TRUE
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_preview->'candidates') candidate
      WHERE candidate->>'sourceDocumentId'=v_order::text
        AND candidate->>'decision'='CONVERT'
        AND candidate->>'sourceDocumentType'='BACKOFFICE_SALES_ORDER') THEN
    RAISE EXCEPTION 'TEST_FAILED: actual Draft candidate missing or misclassified';
  END IF;
  IF (SELECT count(*) FROM public.sales_process_cutover_plans)<>v_before_plan
    OR (SELECT count(*) FROM public.sales_process_cutover_items)<>v_before_item
    OR (SELECT count(*) FROM public.sales_process_cutover_audit)<>v_before_audit THEN
    RAISE EXCEPTION 'TEST_FAILED: read-only preview created cutover state';
  END IF;
  BEGIN
    PERFORM public.get_sales_process_cutover_preview('BACKOFFICE_DELIVERED_QTY_INVOICE');
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CUTOVER_TARGET_INVALID%';
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: same-mode target accepted'; END IF;
  PERFORM set_config('request.jwt.claim.sub','',true);
  v_blocked:=false;
  BEGIN
    PERFORM public.get_sales_process_cutover_preview('RETAIL_CONFIRM_INVOICE');
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%AUTHENTICATION_REQUIRED%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: unauthenticated preview accepted'; END IF;
END
$test$;
ROLLBACK;
SELECT 'sales_process_cutover_preview_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'actual Retail to Office branch executed read-only',
    'actual Backoffice Draft classified for Office to Retail',
    'active Company and Super Admin boundary','same-mode target rejected',
    'unauthenticated caller rejected','preview created zero plan/item/audit rows',
    'all fixture writes rolled back']) details;
