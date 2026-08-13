-- ACP-4A postflight: guarded Inventory simple-master browser boundary.
-- SAFETY: SELECT-only aggregate and catalog metadata.

WITH checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)::BIGINT violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812130000'

  UNION ALL
  SELECT 'required_guarded_inventory_routines',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,2-count(*),
    jsonb_build_object('routine_rows',count(*),'expected',2)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN('save_inventory_uom','save_inventory_warehouse')

  UNION ALL
  SELECT 'browser_inventory_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE has_function_privilege('authenticated',p.oid,'EXECUTE'))=2
              AND count(*) FILTER(WHERE has_function_privilege('anon',p.oid,'EXECUTE'))=0
         THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER(WHERE has_function_privilege('authenticated',p.oid,'EXECUTE'))=2
              AND count(*) FILTER(WHERE has_function_privilege('anon',p.oid,'EXECUTE'))=0
         THEN 0 ELSE 1 END,
    jsonb_build_object(
      'authenticated_rows',count(*) FILTER(WHERE has_function_privilege('authenticated',p.oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE has_function_privilege('anon',p.oid,'EXECUTE'))
    )
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN('save_inventory_uom','save_inventory_warehouse')

  UNION ALL
  SELECT 'inventory_simple_master_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege('authenticated',format('public.%I',name),'INSERT,UPDATE,DELETE'))=0
         THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_table_privilege('authenticated',format('public.%I',name),'INSERT,UPDATE,DELETE')),
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(name ORDER BY name)
      FILTER(WHERE has_table_privilege('authenticated',format('public.%I',name),'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM (VALUES('pos_terminals'),('stores'),('uoms'),('warehouses')) relation(name)

  UNION ALL
  SELECT 'inventory_master_audit_contract',
    CASE WHEN to_regclass('public.inventory_master_write_audit') IS NOT NULL
              AND count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regclass('public.inventory_master_write_audit') IS NOT NULL
              AND count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('table_exists',to_regclass('public.inventory_master_write_audit') IS NOT NULL,'guard_triggers',count(*))
  FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname='inventory_master_write_audit'
    AND t.tgname='trg_acp_guard_inventory_master_audit' AND NOT t.tgisinternal

  UNION ALL
  SELECT 'inventory_master_audit_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.inventory_master_write_audit audit
  LEFT JOIN public.companies company ON company.id=audit.company_id
  LEFT JOIN public.profiles actor ON actor.id=audit.actor_id
  WHERE company.id IS NULL OR actor.id IS NULL

  UNION ALL
  SELECT 'inventory_permission_catalog_remains_shadow',
    CASE WHEN count(*) FILTER(WHERE enforcement_status<>'SHADOW')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'SHADOW'),
    jsonb_build_object('inventory_keys',count(*),'non_shadow',count(*) FILTER(WHERE enforcement_status<>'SHADOW'))
  FROM public.access_permission_catalog WHERE permission_key LIKE 'inventory.%'

  UNION ALL
  SELECT 'inventory_master_runtime_inventory','INFO',0,
    jsonb_build_object(
      'uoms',(SELECT count(*) FROM public.uoms),
      'warehouses',(SELECT count(*) FROM public.warehouses),
      'stores',(SELECT count(*) FROM public.stores),
      'terminals',(SELECT count(*) FROM public.pos_terminals),
      'audit_rows',(SELECT count(*) FROM public.inventory_master_write_audit)
    )
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
