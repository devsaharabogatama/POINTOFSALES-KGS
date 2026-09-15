WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,0::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909100000'
  UNION ALL
  SELECT 'required_default_warehouse_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    0,jsonb_build_object('expected',2,'routineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'set_backoffice_sales_default_warehouse','get_backoffice_sales_order_workspace')
  UNION ALL
  SELECT 'warehouse_guard_trigger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    0,jsonb_build_object('triggerRows',count(*))
  FROM pg_trigger WHERE tgrelid='public.backoffice_sales_orders'::regclass
    AND tgname='backoffice_sales_order_warehouse_guard' AND tgenabled<>'D'
  UNION ALL
  SELECT 'default_warehouse_runtime_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.company_features feature
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=feature.company_id
    AND warehouse.id=CASE WHEN feature.config->>'defaultWarehouseId' ~
      '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
      THEN (feature.config->>'defaultWarehouseId')::uuid END
    AND warehouse.is_active AND warehouse.is_sale_source
  WHERE feature.feature_code='backoffice_delivered_qty_sales_enabled'
    AND feature.config ? 'defaultWarehouseId' AND warehouse.id IS NULL
  UNION ALL
  SELECT 'existing_order_warehouse_scope',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_orders document
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
    AND warehouse.id=document.warehouse_id AND warehouse.is_active
    AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=document.store_id)
  WHERE warehouse.id IS NULL
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
