-- POS Stock Opname online UI postflight.
-- SAFETY: SELECT-only.

WITH workspace AS (
  SELECT procedure.oid,procedure.prosecdef,procedure.provolatile,
    procedure.proconfig,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.oid=to_regprocedure('public.get_pos_stock_opname_workspace()')
),checks(check_name,status,violation_rows,details) AS (
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260902100000'
  UNION ALL
  SELECT 'pos_stock_opname_workspace_routine',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*)) FROM workspace
  UNION ALL
  SELECT 'pos_stock_opname_workspace_security',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',COALESCE(bool_and(prosecdef),FALSE),
      'volatility',min(provolatile::TEXT),'config',min(proconfig::TEXT))
  FROM workspace WHERE prosecdef AND provolatile='s'
    AND proconfig@>ARRAY['search_path=public, pg_temp']::TEXT[]
  UNION ALL
  SELECT 'pos_stock_opname_workspace_blind_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*)) FROM workspace
  WHERE definition ILIKE '%opname.created_by=v_actor%'
    AND definition ILIKE '%private_stock_opname_counter_allowed%'
    AND definition ILIKE '%restrictionPreset%'
    AND definition NOT ILIKE '%physical_qty%'
    AND definition NOT ILIKE '%system_qty%'
    AND definition NOT ILIKE '%expected_qty%'
    AND definition NOT ILIKE '%variance_at_count%'
    AND definition NOT ILIKE '%difference%'
  UNION ALL
  SELECT 'pos_stock_opname_workspace_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon',
      'public.get_pos_stock_opname_workspace()','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.get_pos_stock_opname_workspace()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
      'public.get_pos_stock_opname_workspace()','EXECUTE')
      AND has_function_privilege('authenticated',
      'public.get_pos_stock_opname_workspace()','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('anonExecute',has_function_privilege('anon',
      'public.get_pos_stock_opname_workspace()','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
      'public.get_pos_stock_opname_workspace()','EXECUTE'))
  UNION ALL
  SELECT 'terminal_stock_opname_visibility_contract',
    CASE WHEN count(*)=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint WHERE conrelid='public.pos_terminals'::regclass
    AND conname='pos_terminal_hidden_feature_keys_check'
    AND pg_get_constraintdef(oid) ILIKE '%STOCK_OPNAME%'
  UNION ALL
  SELECT 'terminal_stock_opname_save_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.oid=to_regprocedure(
      'public.save_pos_terminal_ui_settings(uuid,bigint,text[],boolean)')
    AND pg_get_functiondef(procedure.oid) ILIKE '%STOCK_OPNAME%'
  UNION ALL
  SELECT 'browser_stock_opname_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE grantee='authenticated' AND table_schema='public'
    AND table_name IN('stock_opnames','stock_opname_details',
      'stock_opname_count_attempts','stock_opname_audit')
  UNION ALL
  SELECT 'pos_stock_opname_runtime_inventory','INFO',0,jsonb_build_object(
    'drafts',count(*) FILTER(WHERE status='DRAFT'),
    'counting',count(*) FILTER(WHERE status='COUNTING'),
    'completed',count(*) FILTER(WHERE status='COMPLETED'),
    'posted',count(*) FILTER(WHERE status='POSTED'))
  FROM public.stock_opnames
)
SELECT * FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
