-- Authenticated rollback-only behavior for dedicated/lazy Transit usage.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_parent uuid;v_first uuid;v_retry uuid;
  v_parent_result jsonb;v_transit public.warehouses%rowtype;
  v_before jsonb;v_after jsonb;v_failed boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909150000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Transit usage foundation required';
  END IF;
  SELECT profile.id INTO STRICT v_actor
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  v_parent_result:=public.save_inventory_warehouse(NULL,NULL,
    'Transit Test Source '||substr(gen_random_uuid()::text,1,8),'CENTRAL',NULL,
    NULL,false,false,true);
  v_parent:=(v_parent_result->'data'->>'id')::uuid;
  SELECT jsonb_build_object('warehouses',(SELECT count(*) FROM public.warehouses),
    'audits',(SELECT count(*) FROM public.inventory_master_write_audit),
    'stocks',(SELECT count(*) FROM public.product_stocks),
    'batches',(SELECT count(*) FROM public.product_batches),
    'movements',(SELECT count(*) FROM public.stock_movements)) INTO v_before;

  v_first:=private.resolve_or_create_warehouse_transit(v_company,v_parent,
    'SALES_DELIVERY_OUTBOUND',v_actor);
  v_retry:=private.resolve_or_create_warehouse_transit(v_company,v_parent,
    'SALES_DELIVERY_OUTBOUND',v_actor);
  IF v_retry<>v_first THEN RAISE EXCEPTION 'TEST_FAILED: lazy Transit retry changed identity'; END IF;
  SELECT * INTO STRICT v_transit FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.id=v_first;
  IF v_transit.warehouse_type<>'TRANSIT' OR NOT v_transit.is_active
    OR v_transit.transit_parent_warehouse_id<>v_parent
    OR v_transit.transit_operation<>'SALES_DELIVERY_OUTBOUND'
    OR v_transit.is_sale_source OR v_transit.is_purchase_destination
    OR v_transit.allow_negative_stock OR nullif(btrim(v_transit.code),'') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: generated Transit shape invalid';
  END IF;
  BEGIN
    PERFORM public.save_inventory_transit_warehouse(NULL,NULL,
      'Duplicate Transit '||substr(gen_random_uuid()::text,1,8),v_parent,
      'SALES_DELIVERY_OUTBOUND',NULL,true);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%TRANSIT_USAGE_ALREADY_ASSIGNED%' THEN RAISE; END IF;
    v_failed:=true;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: duplicate active Transit usage accepted'; END IF;
  SELECT jsonb_build_object('warehouses',(SELECT count(*) FROM public.warehouses),
    'audits',(SELECT count(*) FROM public.inventory_master_write_audit),
    'stocks',(SELECT count(*) FROM public.product_stocks),
    'batches',(SELECT count(*) FROM public.product_batches),
    'movements',(SELECT count(*) FROM public.stock_movements)) INTO v_after;
  IF (v_after->>'warehouses')::bigint<>(v_before->>'warehouses')::bigint+1
    OR (v_after->>'audits')::bigint<>(v_before->>'audits')::bigint+1
    OR v_after->'stocks' IS DISTINCT FROM v_before->'stocks'
    OR v_after->'batches' IS DISTINCT FROM v_before->'batches'
    OR v_after->'movements' IS DISTINCT FROM v_before->'movements' THEN
    RAISE EXCEPTION 'TEST_FAILED: Transit foundation effect invalid % -> %',v_before,v_after;
  END IF;
END
$test$;
ROLLBACK;
SELECT 'warehouse_transit_usage_foundation_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY['lazy dedicated Transit creation','exact identity retry',
    'duplicate usage rejection','automatic master code','zero Stock/FIFO/Movement effect',
    'all fixture writes rolled back'],'writesPersisted',false) details;
