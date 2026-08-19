-- Additive Product-UOM import/export postflight. SELECT-only.

WITH checks AS (
  SELECT 'migration_ledger' check_name,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260819160000')=1 passed,
    jsonb_build_object('ledgerRows',(SELECT count(*)
      FROM private.kgs_schema_migrations WHERE version='20260819160000')) details
  UNION ALL
  SELECT 'product_uom_import_type_contract',pg_get_constraintdef(oid) LIKE '%PRODUCT_UOM%',
    jsonb_build_object('definition',pg_get_constraintdef(oid))
  FROM pg_constraint WHERE conrelid='public.master_import_jobs'::regclass
    AND conname='master_import_jobs_type_check'
  UNION ALL
  SELECT 'required_product_uom_exchange_routines',count(*)=6,
    jsonb_build_object('routineRows',count(*),'expected',6)
  FROM unnest(ARRAY[
    to_regprocedure('private.upsert_inventory_product_uom_core(uuid,bigint,uuid,numeric,boolean,boolean,numeric,numeric,text,numeric)'),
    to_regprocedure('public.export_inventory_product_uom_placeholders()'),
    to_regprocedure('public.get_inventory_product_uom_import_template()'),
    to_regprocedure('private.create_product_uom_import_job(uuid,text,text,text,text,text)'),
    to_regprocedure('private.validate_product_uom_import_job(uuid,bigint)'),
    to_regprocedure('private.commit_product_uom_import_job(uuid,bigint,integer)')
  ]) routine_oid WHERE routine_oid IS NOT NULL
  UNION ALL
  SELECT 'product_uom_import_dispatch_contract',
    position('PRODUCT_UOM' IN pg_get_functiondef(
      to_regprocedure('private.trg_g2_validate_import_business_fields()')))>0
    AND position('PRODUCT_UOM' IN pg_get_functiondef(
      to_regprocedure('private.acp_require_product_import_if_needed(uuid,text)')))>0
    AND (SELECT count(*) FROM unnest(ARRAY[
      to_regprocedure('public.create_master_import_job(uuid,text,text,text,text,text,text)'),
      to_regprocedure('public.validate_master_import_job(uuid,bigint)'),
      to_regprocedure('public.commit_master_import_job(uuid,bigint,integer)')
    ]) wrapper_oid WHERE wrapper_oid IS NOT NULL
      AND position('PRODUCT_UOM' IN pg_get_functiondef(wrapper_oid))>0)=3,
    jsonb_build_object('expectedWrappers',3)
  UNION ALL
  SELECT 'product_uom_exchange_browser_boundary',
    has_function_privilege('authenticated',
      'public.export_inventory_product_uom_placeholders()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_inventory_product_uom_import_template()','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.export_inventory_product_uom_placeholders()','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_inventory_product_uom_import_template()','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.upsert_inventory_product_uom_core(uuid,bigint,uuid,numeric,boolean,boolean,numeric,numeric,text,numeric)','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.commit_product_uom_import_job(uuid,bigint,integer)','EXECUTE'),
    jsonb_build_object('authenticatedExport',has_function_privilege('authenticated',
      'public.export_inventory_product_uom_placeholders()','EXECUTE'),
      'authenticatedTemplate',has_function_privilege('authenticated',
      'public.get_inventory_product_uom_import_template()','EXECUTE'),
      'anonExport',has_function_privilege('anon',
      'public.export_inventory_product_uom_placeholders()','EXECUTE'))
  UNION ALL
  SELECT 'product_uom_direct_write_boundary',count(*)=0,
    jsonb_build_object('directWriteRelations',COALESCE(jsonb_agg(table_name)
      FILTER(WHERE table_name IS NOT NULL),'[]'::JSONB))
  FROM (SELECT table_name FROM (VALUES('products'),('product_uoms')) relation(table_name)
    WHERE has_table_privilege('authenticated','public.'||table_name,
      'INSERT,UPDATE,DELETE')) writable
  UNION ALL
  SELECT 'nonterminal_product_uom_import_job',count(*)=0,
    jsonb_build_object('jobCount',count(*))
  FROM public.master_import_jobs WHERE import_type='PRODUCT_UOM'
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')
)
SELECT check_name,CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END status,
  CASE WHEN passed THEN 0 ELSE 1 END violation_rows,details
FROM checks ORDER BY status,check_name;
