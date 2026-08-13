-- ACP-4I postflight: Minimum Stock capability and composed-read boundary.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH protected_relations(relation_name) AS (
  VALUES ('product_warehouse_stock_settings'),
    ('product_warehouse_stock_setting_audit')
), public_routines AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'get_inventory_minimum_stock','save_product_warehouse_stock_setting')
), import_routines AS (
  SELECT procedure.oid,procedure.proname,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'create_master_import_job','stage_master_import_rows',
    'validate_master_import_job','commit_master_import_job')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812210000'

  UNION ALL
  SELECT 'minimum_stock_permission_enforced',CASE WHEN count(*)=1
    AND count(*) FILTER(WHERE enforcement_status='ENFORCED'
      AND supported_capabilities @> ARRAY[
        'VIEW','MANAGE','EXPORT','IMPORT']::TEXT[])=1
    THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(
      jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.minimum_stock'

  UNION ALL
  SELECT 'required_minimum_stock_public_routines',CASE WHEN count(*)=2
    AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',oid,'EXECUTE'))=2
    AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
    THEN 0 ELSE 1 END,
    jsonb_build_object('routine_names',COALESCE(jsonb_agg(proname ORDER BY proname),
      '[]'::JSONB),'routine_rows',count(*))
  FROM public_routines

  UNION ALL
  SELECT 'minimum_stock_public_runtime_guard',CASE WHEN count(*)=2
    AND count(*) FILTER(WHERE definition ILIKE
      '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.minimum_stock%')=2
    AND count(*) FILTER(WHERE proname='get_inventory_minimum_stock'
      AND definition ILIKE '%''VIEW''%')=1
    AND count(*) FILTER(WHERE proname='save_product_warehouse_stock_setting'
      AND definition ILIKE '%''MANAGE''%')=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'guarded_rows',count(*) FILTER(
      WHERE definition ILIKE '%inventory.minimum_stock%'))
  FROM public_routines

  UNION ALL
  SELECT 'minimum_stock_import_runtime_guard',CASE WHEN count(*)=4
    AND count(*) FILTER(WHERE definition ILIKE
      '%acp_require_minimum_stock_import_if_needed%')=4
    THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'guarded_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_minimum_stock_import_if_needed%'))
  FROM import_routines

  UNION ALL
  SELECT 'minimum_stock_private_core_boundary',CASE WHEN count(*)=1
    AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',procedure.oid,'EXECUTE'))=0
    AND count(*) FILTER(WHERE has_function_privilege(
      'anon',procedure.oid,'EXECUTE'))=0 THEN 0 ELSE 1 END,
    jsonb_build_object('core_rows',count(*),'authenticated_executable',
      count(*) FILTER(WHERE has_function_privilege(
        'authenticated',procedure.oid,'EXECUTE')))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='save_product_warehouse_stock_setting'

  UNION ALL
  SELECT 'minimum_stock_direct_read_write_boundary',count(*) FILTER(WHERE
    has_table_privilege('authenticated',format('public.%I',relation_name),
      'SELECT,INSERT,UPDATE,DELETE')),
    jsonb_build_object('direct_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'SELECT,INSERT,UPDATE,DELETE')),
      '[]'::JSONB))
  FROM protected_relations

  UNION ALL
  SELECT 'minimum_stock_tenant_reference_integrity',count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.product_warehouse_stock_settings setting
  LEFT JOIN public.products product ON product.company_id=setting.company_id
    AND product.id=setting.product_id
  LEFT JOIN public.warehouses warehouse
    ON warehouse.company_id=setting.company_id
   AND warehouse.id=setting.warehouse_id
  WHERE product.id IS NULL OR warehouse.id IS NULL

  UNION ALL
  SELECT 'minimum_stock_audit_coverage',count(*),
    jsonb_build_object('setting_count',count(*))
  FROM public.product_warehouse_stock_settings setting
  WHERE NOT EXISTS(SELECT 1
    FROM public.product_warehouse_stock_setting_audit audit
    WHERE audit.company_id=setting.company_id AND audit.setting_id=setting.id
      AND audit.action='CREATE')

  UNION ALL
  SELECT 'nonterminal_minimum_stock_import_job',count(*),
    jsonb_build_object('job_count',count(*))
  FROM public.master_import_jobs
  WHERE import_type='PRODUCT_WAREHOUSE_MINIMUM_STOCK'
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

  UNION ALL
  SELECT 'minimum_stock_runtime_inventory',0,jsonb_build_object(
    'settings',count(*),'companies',count(DISTINCT company_id),
    'alerts_enabled',count(*) FILTER(WHERE low_stock_alert_enabled),
    'audit_rows',(SELECT count(*)
      FROM public.product_warehouse_stock_setting_audit))
  FROM public.product_warehouse_stock_settings
)
SELECT check_name,CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END status,
  violation_rows,details
FROM checks ORDER BY CASE WHEN violation_rows>0 THEN 1 ELSE 2 END,check_name;
