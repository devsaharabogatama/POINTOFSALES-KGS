-- ACP-4C postflight: enforced Product management and Product-import boundary.
-- SAFETY: SELECT-only aggregate/catalog metadata.

WITH public_product_routines AS (
  SELECT p.oid,p.proname,pg_get_functiondef(p.oid) definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN(
    'save_product_with_uoms','save_product_tax_assignment'
  )
), public_import_routines AS (
  SELECT p.oid,p.proname,pg_get_functiondef(p.oid) definition
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname IN(
    'create_master_import_job','stage_master_import_rows',
    'validate_master_import_job','commit_master_import_job'
  )
), private_cores AS (
  SELECT p.oid,p.proname
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname IN(
    'save_product_with_uoms','save_product_tax_assignment',
    'create_master_import_job','stage_master_import_rows',
    'validate_master_import_job','commit_master_import_job'
  )
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812150000'

  UNION ALL
  SELECT 'product_permission_enforced',
    CASE WHEN count(*)=1 AND COALESCE(bool_and(enforcement_status='ENFORCED'),FALSE)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND COALESCE(bool_and(enforcement_status='ENFORCED'),FALSE)
      THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='inventory.products'

  UNION ALL
  SELECT 'remaining_inventory_permission_state',
    CASE WHEN count(*) FILTER(WHERE permission_key NOT IN(
      'inventory.master_data','inventory.products'
    ) AND enforcement_status<>'SHADOW')=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE permission_key NOT IN(
      'inventory.master_data','inventory.products'
    ) AND enforcement_status<>'SHADOW'),
    jsonb_build_object('unexpected_non_shadow',count(*) FILTER(
      WHERE permission_key NOT IN('inventory.master_data','inventory.products')
        AND enforcement_status<>'SHADOW'))
  FROM public.access_permission_catalog WHERE permission_key LIKE 'inventory.%'

  UNION ALL
  SELECT 'product_mutation_permission_hooks',
    CASE WHEN count(*)=3 AND count(*) FILTER(
      WHERE definition ILIKE '%inventory.products%'
        AND definition ILIKE '%MANAGE%'
    )=3 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3 AND count(*) FILTER(
      WHERE definition ILIKE '%inventory.products%'
        AND definition ILIKE '%MANAGE%'
    )=3 THEN 0 ELSE 1 END,
    jsonb_build_object('signature_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%inventory.products%' AND definition ILIKE '%MANAGE%'))
  FROM public_product_routines

  UNION ALL
  SELECT 'product_import_permission_hooks',
    CASE WHEN count(*)=4 AND count(*) FILTER(
      WHERE definition ILIKE '%acp_require_product_import_if_needed%'
    )=4 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=4 AND count(*) FILTER(
      WHERE definition ILIKE '%acp_require_product_import_if_needed%'
    )=4 THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_product_import_if_needed%'))
  FROM public_import_routines

  UNION ALL
  SELECT 'browser_product_rpc_boundary',
    CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=3
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',oid,'EXECUTE'))=3
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('authenticated_rows',count(*) FILTER(
      WHERE has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE')))
  FROM public_product_routines

  UNION ALL
  SELECT 'private_product_import_core_boundary',
    CASE WHEN count(*)=7 AND count(*) FILTER(
      WHERE has_function_privilege('authenticated',oid,'EXECUTE')
    )=0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=7 AND count(*) FILTER(
      WHERE has_function_privilege('authenticated',oid,'EXECUTE')
    )=0 THEN 0 ELSE 1 END,
    jsonb_build_object('core_rows',count(*),'authenticated_rows',count(*) FILTER(
      WHERE has_function_privilege('authenticated',oid,'EXECUTE')))
  FROM private_cores

  UNION ALL
  SELECT 'product_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
    ))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE')),
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege(
        'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'
      )),'[]'::JSONB))
  FROM (VALUES('products'),('product_uoms')) relation(relation_name)

  UNION ALL
  SELECT 'product_override_tenant_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('row_count',count(*))
  FROM public.user_company_permission_overrides override_row
  LEFT JOIN public.company_memberships membership
    ON membership.company_id=override_row.company_id
   AND membership.user_id=override_row.user_id AND membership.status='ACTIVE'
  LEFT JOIN public.profiles profile ON profile.id=override_row.user_id
  WHERE override_row.permission_key='inventory.products'
    AND membership.user_id IS NULL AND profile.role<>'super_admin'::public.user_role

  UNION ALL
  SELECT 'nonterminal_master_import_jobs',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('job_count',count(*),'companies',count(DISTINCT company_id))
  FROM public.master_import_jobs
  WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

  UNION ALL
  SELECT 'product_permission_runtime_inventory','INFO',0,jsonb_build_object(
    'products',(SELECT count(*) FROM public.products),
    'product_uoms',(SELECT count(*) FROM public.product_uoms),
    'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.products'),
    'products_with_history',(SELECT count(DISTINCT product_id)
      FROM public.stock_movements))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
