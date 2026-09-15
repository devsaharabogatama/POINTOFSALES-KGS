-- Step 4D/6 SELECT-only postflight.
WITH checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911120000'
  UNION ALL
  SELECT 'required_step_4d_routines',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    abs(5-count(*)),jsonb_build_object('expected',5,'routineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname,pg_get_function_identity_arguments(procedure.oid)) IN(
    ('public','adopt_backoffice_cutover_sale_draft','p_sales_id uuid, p_expected_master_version bigint, p_cashier_session_id uuid, p_operation_id uuid, p_confirm_takeover boolean'),
    ('public','save_backoffice_cutover_sale_draft_preserved','p_sales_id uuid, p_expected_master_version bigint, p_cashier_session_id uuid, p_operation_id uuid, p_payments jsonb'),
    ('private','backoffice_cutover_retail_draft_response','p_company_id uuid, p_sales_id uuid, p_exact_retry boolean, p_operation text'),
    ('private','sales_process_retail_identity_is_valid','p_sales_origin text, p_sales_process_mode text, p_session_id uuid, p_pos_id uuid, p_created_session_id uuid'),
    ('public','list_pos_sale_drafts','p_store_id uuid'))
  UNION ALL
  SELECT 'step_4d_relation_boundary',
    CASE WHEN to_regclass('public.sales_cutover_retail_adoption_operations') IS NOT NULL
      AND relrowsecurity THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regclass('public.sales_cutover_retail_adoption_operations') IS NOT NULL
      AND relrowsecurity THEN 0 ELSE 1 END,
    jsonb_build_object('relationExists',to_regclass('public.sales_cutover_retail_adoption_operations') IS NOT NULL,
      'rlsEnabled',COALESCE(relrowsecurity,false))
  FROM pg_class WHERE oid='public.sales_cutover_retail_adoption_operations'::regclass
  UNION ALL
  SELECT 'step_4d_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='anon')=0
      AND count(*) FILTER(WHERE grantee='authenticated')=2 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE grantee='anon')+
      abs(2-count(*) FILTER(WHERE grantee='authenticated')),
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE grantee='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'))
  FROM information_schema.routine_privileges
  WHERE routine_schema='public' AND privilege_type='EXECUTE'
    AND routine_name IN('adopt_backoffice_cutover_sale_draft',
      'save_backoffice_cutover_sale_draft_preserved')
    AND grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'step_4d_security_contract',
    CASE WHEN count(*)=2 AND bool_and(prosecdef) AND bool_and(provolatile='v')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 AND bool_and(prosecdef) AND bool_and(provolatile='v')
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',bool_and(prosecdef),
      'volatility',string_agg(DISTINCT provolatile::text,','))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'adopt_backoffice_cutover_sale_draft','save_backoffice_cutover_sale_draft_preserved')
  UNION ALL
  SELECT 'step_4d_definition_contract',
    CASE WHEN position('SALE_DRAFT_WAREHOUSE_ACCESS_DENIED' in adopt.definition)>0
      AND position('snapshotPreserved' in preserve.definition)>0
      AND position('salesOrigin' in listing.definition)>0
      AND position('salesWarehouseId' in listing.definition)>0 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('SALE_DRAFT_WAREHOUSE_ACCESS_DENIED' in adopt.definition)>0
      AND position('snapshotPreserved' in preserve.definition)>0
      AND position('salesOrigin' in listing.definition)>0
      AND position('salesWarehouseId' in listing.definition)>0 THEN 0 ELSE 1 END,
    jsonb_build_object('sameWarehouseGuard',position('SALE_DRAFT_WAREHOUSE_ACCESS_DENIED' in adopt.definition)>0,
      'preserveGuard',position('snapshotPreserved' in preserve.definition)>0,
      'listOrigin',position('salesOrigin' in listing.definition)>0,
      'listWarehouse',position('salesWarehouseId' in listing.definition)>0)
  FROM (SELECT pg_get_functiondef('public.adopt_backoffice_cutover_sale_draft(uuid,bigint,uuid,uuid,boolean)'::regprocedure) definition) adopt,
    (SELECT pg_get_functiondef('public.save_backoffice_cutover_sale_draft_preserved(uuid,bigint,uuid,uuid,jsonb)'::regprocedure) definition) preserve,
    (SELECT pg_get_functiondef('public.list_pos_sale_drafts(uuid)'::regprocedure) definition) listing
  UNION ALL
  SELECT 'step_4d_runtime_inventory','INFO',0,
    jsonb_build_object('operations',count(*),
      'adopt',count(*) FILTER(WHERE operation_type='ADOPT'),
      'preserveSave',count(*) FILTER(WHERE operation_type='PRESERVE_SAVE'))
  FROM public.sales_cutover_retail_adoption_operations
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
