-- Read-only; runtime contract is not behavioral proof.
WITH checks AS (
 SELECT 'history_migration' check_name,CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
 WHERE version='20260916110000') THEN 0 ELSE 1 END violation_rows
 UNION ALL SELECT 'history_security_contract',CASE WHEN EXISTS(SELECT 1 FROM pg_proc
 WHERE oid=to_regprocedure('public.get_office_retail_history(uuid)') AND prosecdef
 AND provolatile='s' AND proconfig @> ARRAY['search_path=public, pg_temp','statement_timeout=15s']) THEN 0 ELSE 1 END
 UNION ALL SELECT 'history_rpc_acl',CASE WHEN to_regprocedure('public.get_office_retail_history(uuid)') IS NOT NULL
 AND has_function_privilege('authenticated',to_regprocedure('public.get_office_retail_history(uuid)'),'EXECUTE')
 AND NOT has_function_privilege('anon',to_regprocedure('public.get_office_retail_history(uuid)'),'EXECUTE') THEN 0 ELSE 1 END
)
SELECT check_name,CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END status,violation_rows
FROM checks ORDER BY check_name;
