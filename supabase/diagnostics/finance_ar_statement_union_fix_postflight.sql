-- F4A Customer Statement UNION forward-fix postflight. SELECT-only.
WITH routine AS (
  SELECT pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.oid=to_regprocedure(
      'public.get_finance_customer_statement(uuid,date,date,uuid)')
),checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827131000'
  UNION ALL
  SELECT 'customer_statement_union_shape',CASE WHEN count(*)=1
      AND bool_and(definition~*'sale\.store_id\s*,\s*store\.store_name\s*,\s*0::numeric')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1
      AND bool_and(definition~*'sale\.store_id\s*,\s*store\.store_name\s*,\s*0::numeric')
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',count(*))
  FROM routine
  UNION ALL
  SELECT 'customer_statement_rpc_boundary',CASE WHEN count(*)=1
      AND bool_and(has_function_privilege('authenticated',procedure.oid,'EXECUTE'))
      AND bool_and(NOT has_function_privilege('anon',procedure.oid,'EXECUTE'))
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(has_function_privilege('authenticated',procedure.oid,'EXECUTE'))
      AND bool_and(NOT has_function_privilege('anon',procedure.oid,'EXECUTE'))
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname='get_finance_customer_statement'
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;
