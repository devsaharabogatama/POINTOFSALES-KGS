WITH definition AS (
  SELECT pg_get_functiondef(
    'public.get_purchase_daily_replenishment_client_workspace()'::regprocedure) body
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914150000'
  UNION ALL
  SELECT 'client_workspace_definition_contract',
    CASE WHEN body LIKE '%clientWorkspaceVersion%'
      AND body LIKE '%generated_by_name%'
      AND body LIKE '%productSuppliers%' AND body LIKE '%purchaseUoms%'
      AND body LIKE '%receivingWarehouses%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%clientWorkspaceVersion%'
      AND body LIKE '%generated_by_name%'
      AND body LIKE '%productSuppliers%' AND body LIKE '%purchaseUoms%'
      AND body LIKE '%receivingWarehouses%' THEN 0 ELSE 1 END,
    jsonb_build_object('actorDisplay',body LIKE '%generated_by_name%',
      'relationIdentity',body LIKE '%relation.id%',
      'uomConversion',body LIKE '%factorToBase%',
      'receivingWarehouse',body LIKE '%is_purchase_destination%')
  FROM definition
  UNION ALL
  SELECT 'client_workspace_security_contract',
    CASE WHEN prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp']::text[]
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN prosecdef AND proconfig @> ARRAY['search_path=public, pg_temp']::text[]
      THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',prosecdef,'config',proconfig)
  FROM pg_proc WHERE oid=
    'public.get_purchase_daily_replenishment_client_workspace()'::regprocedure
  UNION ALL
  SELECT 'client_workspace_execute_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_purchase_daily_replenishment_client_workspace()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_purchase_daily_replenishment_client_workspace()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_purchase_daily_replenishment_client_workspace()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_purchase_daily_replenishment_client_workspace()','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',has_function_privilege('anon',
      'public.get_purchase_daily_replenishment_client_workspace()','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
      'public.get_purchase_daily_replenishment_client_workspace()','EXECUTE'))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
