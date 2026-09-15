-- Rollback-only behavior for default Warehouse configuration and scope guard.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_valid uuid;v_invalid uuid;
  v_result jsonb;v_workspace jsonb;v_failed boolean:=false;
BEGIN
  SELECT user_row.id INTO STRICT v_actor FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY user_row.id LIMIT 1;
  SELECT company.id INTO STRICT v_company FROM public.companies company
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.stores store
      WHERE store.company_id=company.id AND store.status='ACTIVE')
    AND EXISTS(SELECT 1 FROM public.warehouses warehouse
      WHERE warehouse.company_id=company.id AND warehouse.is_active
        AND warehouse.is_sale_source)
  ORDER BY company.id LIMIT 1;
  SELECT store.id INTO STRICT v_store FROM public.stores store
  WHERE store.company_id=v_company AND store.status='ACTIVE' ORDER BY store.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_ODOO_FORM_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=EXCLUDED.company_id,
    selection_source=EXCLUDED.selection_source;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}'::jsonb,v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,
    config='{}'::jsonb,updated_by=EXCLUDED.updated_by,
    updated_at=clock_timestamp();
  SELECT warehouse.id INTO STRICT v_valid FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.is_active AND warehouse.is_sale_source
  ORDER BY warehouse.id LIMIT 1;
  v_result:=public.save_inventory_warehouse(NULL::uuid,NULL::bigint,
    'Backoffice Invalid Default Test'::text,'STORE'::text,v_store,
    'Rollback-only'::text,false,false,true);
  v_invalid:=(v_result->'data'->>'id')::uuid;
  v_result:=public.set_backoffice_sales_default_warehouse(v_valid);
  IF (v_result->>'defaultWarehouseId')::uuid<>v_valid THEN
    RAISE EXCEPTION 'TEST_FAILED: default Warehouse setter mismatch';
  END IF;
  v_workspace:=public.get_backoffice_sales_order_workspace();
  IF (v_workspace->>'defaultWarehouseId')::uuid<>v_valid THEN
    RAISE EXCEPTION 'TEST_FAILED: workspace default Warehouse mismatch';
  END IF;
  BEGIN
    PERFORM public.set_backoffice_sales_default_warehouse(v_invalid);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%BACKOFFICE_DEFAULT_WAREHOUSE_INVALID%' THEN v_failed:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: invalid Warehouse accepted'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_workspace->'warehouses') item
    WHERE (item->>'id')::uuid=v_invalid) THEN
    RAISE EXCEPTION 'TEST_FAILED: non-sale Warehouse exposed';
  END IF;
END
$test$;
ROLLBACK;
