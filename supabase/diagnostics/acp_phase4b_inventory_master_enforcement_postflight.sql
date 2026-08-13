-- ACP-4B postflight: one enforced Inventory permission key, guarded end to end.
-- SAFETY: SELECT-only aggregate/catalog metadata.

WITH public_runtime AS (
  SELECT p.oid,p.proname,pg_get_functiondef(p.oid) definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN(
    'save_inventory_product_category','save_inventory_uom',
    'save_inventory_warehouse','save_product_category_tax_assignment'
  )
), private_cores AS (
  SELECT p.oid,p.proname
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname IN(
    'save_inventory_uom','save_inventory_warehouse',
    'save_product_category_tax_assignment'
  )
), category_columns(column_name) AS (
  VALUES('company_id'),('category_code'),('category_name'),('is_active')
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)<>1 AS violation,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812140000'

  UNION ALL
  SELECT 'inventory_master_permission_enforced',
    CASE WHEN count(*)=1 AND COALESCE(bool_and(enforcement_status='ENFORCED'),FALSE)
      THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=1 AND COALESCE(bool_and(enforcement_status='ENFORCED'),FALSE)),
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='inventory.master_data'

  UNION ALL
  SELECT 'other_inventory_permissions_remain_shadow',
    CASE WHEN count(*) FILTER(WHERE enforcement_status<>'SHADOW')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE enforcement_status<>'SHADOW')<>0,
    jsonb_build_object('non_shadow',count(*) FILTER(WHERE enforcement_status<>'SHADOW'))
  FROM public.access_permission_catalog
  WHERE permission_key LIKE 'inventory.%' AND permission_key<>'inventory.master_data'

  UNION ALL
  SELECT 'required_public_inventory_master_routines',
    CASE WHEN count(*)=4 AND count(*) FILTER(
      WHERE definition ILIKE '%inventory.master_data%' AND definition ILIKE '%MANAGE%'
    )=4 THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=4 AND count(*) FILTER(
      WHERE definition ILIKE '%inventory.master_data%' AND definition ILIKE '%MANAGE%'
    )=4),
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%inventory.master_data%' AND definition ILIKE '%MANAGE%'))
  FROM public_runtime

  UNION ALL
  SELECT 'browser_inventory_master_rpc_boundary',
    CASE WHEN count(*)=4
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=4
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=4
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=4
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0),
    jsonb_build_object(
      'routine_rows',count(*),
      'authenticated_rows',count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE')))
  FROM public_runtime

  UNION ALL
  SELECT 'private_inventory_master_core_boundary',
    CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=3
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=0),
    jsonb_build_object('core_rows',count(*),'authenticated_rows',
      count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE')))
  FROM private_cores

  UNION ALL
  SELECT 'product_category_direct_write_boundary',
    CASE WHEN NOT has_table_privilege('authenticated','public.product_categories','INSERT,UPDATE,DELETE')
      AND count(*) FILTER(WHERE has_column_privilege(
        'authenticated','public.product_categories',column_name,'INSERT'
      ) OR has_column_privilege(
        'authenticated','public.product_categories',column_name,'UPDATE'
      ))=0 THEN 'PASS' ELSE 'FAIL' END,
    has_table_privilege('authenticated','public.product_categories','INSERT,UPDATE,DELETE')
      OR count(*) FILTER(WHERE has_column_privilege(
        'authenticated','public.product_categories',column_name,'INSERT'
      ) OR has_column_privilege(
        'authenticated','public.product_categories',column_name,'UPDATE'
      ))>0,
    jsonb_build_object(
      'table_write',has_table_privilege('authenticated','public.product_categories','INSERT,UPDATE,DELETE'),
      'writable_columns',COALESCE(jsonb_agg(column_name ORDER BY column_name) FILTER(
        WHERE has_column_privilege('authenticated','public.product_categories',column_name,'INSERT')
           OR has_column_privilege('authenticated','public.product_categories',column_name,'UPDATE')
      ),'[]'::JSONB))
  FROM category_columns

  UNION ALL
  SELECT 'other_inventory_master_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
    ))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
    ))>0,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name) FILTER(
      WHERE has_table_privilege('authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE')
    ),'[]'::JSONB))
  FROM (VALUES('uoms'),('warehouses'),('stores'),('pos_terminals')) relation(relation_name)

  UNION ALL
  SELECT 'inventory_master_audit_contract',
    CASE WHEN count(*)=1 AND COALESCE(bool_and(
      pg_get_constraintdef(c.oid) ILIKE '%PRODUCT_CATEGORY%'
    ),FALSE) THEN 'PASS' ELSE 'FAIL' END,
    NOT(count(*)=1 AND COALESCE(bool_and(
      pg_get_constraintdef(c.oid) ILIKE '%PRODUCT_CATEGORY%'
    ),FALSE)),
    jsonb_build_object('constraint_rows',count(*))
  FROM pg_constraint c JOIN pg_class r ON r.oid=c.conrelid
  JOIN pg_namespace n ON n.oid=r.relnamespace
  WHERE n.nspname='public' AND r.relname='inventory_master_write_audit'
    AND c.conname='inventory_master_audit_type_check'

  UNION ALL
  SELECT 'inventory_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)>0,
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id AND membership.status='ACTIVE'
  LEFT JOIN public.profiles profile ON profile.id=override_row.user_id
  WHERE membership.user_id IS NULL AND profile.role<>'super_admin'::public.user_role

  UNION ALL
  SELECT 'nonterminal_master_import_jobs',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)>0,
    jsonb_build_object('job_count',count(*),'companies',count(DISTINCT company_id))
  FROM public.master_import_jobs
  WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

  UNION ALL
  SELECT 'inventory_master_enforcement_inventory','INFO',FALSE,
    jsonb_build_object(
      'categories',(SELECT count(*) FROM public.product_categories),
      'uoms',(SELECT count(*) FROM public.uoms),
      'warehouses',(SELECT count(*) FROM public.warehouses),
      'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
        WHERE permission_key='inventory.master_data'),
      'audit_rows',(SELECT count(*) FROM public.inventory_master_write_audit))
)
SELECT check_name,status,CASE WHEN violation THEN 1 ELSE 0 END violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
