-- ACP-4B preflight: Inventory Master Data permission enforcement readiness.
-- SAFETY: one SELECT statement; aggregate/catalog metadata only.

WITH required_versions(version) AS (
  VALUES('20260812120000'),('20260812130000')
), master_routines(routine_name) AS (
  VALUES
    ('save_inventory_uom'),
    ('save_inventory_warehouse'),
    ('save_product_category_tax_assignment')
), routine_state AS (
  SELECT expected.routine_name,p.oid,
    CASE WHEN p.oid IS NULL THEN NULL ELSE pg_get_functiondef(p.oid) END definition
  FROM master_routines expected
  LEFT JOIN pg_proc p ON p.proname=expected.routine_name
  LEFT JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='public'
  WHERE p.oid IS NULL OR n.oid IS NOT NULL
), nonterminal_import AS (
  SELECT company_id,count(*) row_count
  FROM public.master_import_jobs
  WHERE status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')
  GROUP BY company_id
), checks AS (
  SELECT 'acp_phase4b_dependencies'::TEXT check_name,
    CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
      FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) details
  FROM required_versions required
  LEFT JOIN private.kgs_schema_migrations migration ON migration.version=required.version

  UNION ALL
  SELECT 'inventory_master_permission_catalog_state',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='SHADOW') THEN 'SETUP' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',COALESCE(jsonb_agg(DISTINCT enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog WHERE permission_key='inventory.master_data'

  UNION ALL
  SELECT 'inventory_master_existing_override_scope','INFO',
    jsonb_build_object('override_rows',count(*),'companies',count(DISTINCT company_id),'users',count(DISTINCT user_id),
      'by_preset',COALESCE(jsonb_object_agg(restriction_preset,preset_count),'{}'::JSONB))
  FROM (
    SELECT company_id,user_id,restriction_preset,count(*) OVER(PARTITION BY restriction_preset) preset_count
    FROM public.user_company_permission_overrides WHERE permission_key='inventory.master_data'
  ) overrides

  UNION ALL
  SELECT 'product_category_identity_direct_write_boundary',
    CASE WHEN has_table_privilege('authenticated','public.product_categories','INSERT,UPDATE,DELETE')
              OR has_any_column_privilege('authenticated','public.product_categories','INSERT,UPDATE')
         THEN 'BLOCKER' ELSE 'PASS' END,
    jsonb_build_object(
      'table_write',has_table_privilege('authenticated','public.product_categories','INSERT,UPDATE,DELETE'),
      'column_write',has_any_column_privilege('authenticated','public.product_categories','INSERT,UPDATE')
    )

  UNION ALL
  SELECT 'other_inventory_master_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege('authenticated',format('public.%I',name),'INSERT,UPDATE,DELETE')
                                   OR has_any_column_privilege('authenticated',format('public.%I',name),'INSERT,UPDATE'))=0
         THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(name ORDER BY name)
      FILTER(WHERE has_table_privilege('authenticated',format('public.%I',name),'INSERT,UPDATE,DELETE')
                   OR has_any_column_privilege('authenticated',format('public.%I',name),'INSERT,UPDATE')),'[]'::JSONB))
  FROM (VALUES('uoms'),('warehouses'),('stores'),('pos_terminals')) relation(name)

  UNION ALL
  SELECT 'guarded_inventory_master_routine_state',
    CASE WHEN count(*) FILTER(WHERE oid IS NULL)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',count(*),'missing',COALESCE(jsonb_agg(routine_name ORDER BY routine_name)
      FILTER(WHERE oid IS NULL),'[]'::JSONB))
  FROM routine_state

  UNION ALL
  SELECT 'inventory_master_runtime_permission_hook_state',
    CASE WHEN count(*) FILTER(WHERE definition ILIKE '%inventory.master_data%')=count(*) THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(WHERE definition ILIKE '%inventory.master_data%'),
      'unhooked',COALESCE(jsonb_agg(routine_name ORDER BY routine_name)
        FILTER(WHERE definition IS NULL OR definition NOT ILIKE '%inventory.master_data%'),'[]'::JSONB))
  FROM routine_state

  UNION ALL
  SELECT 'inventory_master_missing_guarded_identity_rpc',
    CASE WHEN to_regprocedure('public.save_inventory_product_category(uuid,bigint,text,boolean)') IS NULL
         THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('rpc_exists',to_regprocedure('public.save_inventory_product_category(uuid,bigint,text,boolean)') IS NOT NULL)

  UNION ALL
  SELECT 'nonterminal_master_import_jobs',
    CASE WHEN COALESCE(sum(row_count),0)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('job_count',COALESCE(sum(row_count),0),'companies',count(*))
  FROM nonterminal_import

  UNION ALL
  SELECT 'inventory_master_normalized_name_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('duplicate_groups',count(*),'master_types',COALESCE(jsonb_agg(DISTINCT master_type),'[]'::JSONB))
  FROM (
    SELECT 'PRODUCT_CATEGORY' master_type,company_id,lower(regexp_replace(btrim(category_name),'\s+',' ','g')) normalized_name
    FROM public.product_categories GROUP BY company_id,lower(regexp_replace(btrim(category_name),'\s+',' ','g')) HAVING count(*)>1
    UNION ALL
    SELECT 'UOM',company_id,lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.uoms GROUP BY company_id,lower(regexp_replace(btrim(name),'\s+',' ','g')) HAVING count(*)>1
  ) duplicates

  UNION ALL
  SELECT 'inventory_master_runtime_inventory','INFO',jsonb_build_object(
    'active_companies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
    'categories',(SELECT count(*) FROM public.product_categories),
    'uoms',(SELECT count(*) FROM public.uoms),
    'warehouses',(SELECT count(*) FROM public.warehouses),
    'stores',(SELECT count(*) FROM public.stores),
    'terminals',(SELECT count(*) FROM public.pos_terminals)
  )
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2 WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
