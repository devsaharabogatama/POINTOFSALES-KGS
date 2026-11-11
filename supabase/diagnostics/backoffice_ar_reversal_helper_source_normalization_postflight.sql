-- READ ONLY. Run after 20261110150000 and after rollback behavior.
WITH routine AS (
  SELECT pg_get_functiondef(proc.oid) definition,proc.prosecdef,
    proc.proconfig,proc.proacl,pg_get_userbyid(proc.proowner) owner_name,
    proc.provolatile volatility,proc.proparallel parallel_safety,
    proc.proleakproof leakproof
  FROM pg_proc proc WHERE proc.oid=
    'private.ar5_item_allocated(uuid,uuid,date)'::regprocedure
), checks AS (
  SELECT
    'backoffice_ar_reversal_helper_normalization_postflight_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20261110150000'

  UNION ALL

  SELECT 'backoffice_ar_reversal_helper_normalization_postflight_runtime_contract',
    CASE WHEN md5(definition)='3de3fd3ba6aa98e79db22ef32f1bd0da'
        AND md5(replace(definition,E'\r\n',E'\n'))=
          '3de3fd3ba6aa98e79db22ef32f1bd0da'
        AND owner_name='postgres' AND prosecdef
        AND volatility='s' AND parallel_safety='u' AND NOT leakproof
        AND has_function_privilege('service_role',
          'private.ar5_item_allocated(uuid,uuid,date)','EXECUTE')
        AND NOT has_function_privilege('authenticated',
          'private.ar5_item_allocated(uuid,uuid,date)','EXECUTE')
        AND NOT has_function_privilege('anon',
          'private.ar5_item_allocated(uuid,uuid,date)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN md5(definition)='3de3fd3ba6aa98e79db22ef32f1bd0da'
        AND md5(replace(definition,E'\r\n',E'\n'))=
          '3de3fd3ba6aa98e79db22ef32f1bd0da'
        AND owner_name='postgres' AND prosecdef
        AND volatility='s' AND parallel_safety='u' AND NOT leakproof
        AND has_function_privilege('service_role',
          'private.ar5_item_allocated(uuid,uuid,date)','EXECUTE')
        AND NOT has_function_privilege('authenticated',
          'private.ar5_item_allocated(uuid,uuid,date)','EXECUTE')
        AND NOT has_function_privilege('anon',
          'private.ar5_item_allocated(uuid,uuid,date)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('rawMd5',md5(definition),
      'normalizedMd5',md5(replace(definition,E'\r\n',E'\n')),
      'owner',owner_name,'securityDefiner',prosecdef,
      'volatility',volatility,'parallelSafety',parallel_safety,
      'leakproof',leakproof,'runtimeConfig',proconfig,
      'accessControl',proacl)
  FROM routine

  UNION ALL

  SELECT 'backoffice_ar_reversal_helper_normalization_postflight_business_boundary',
    'INFO',0,jsonb_build_object(
      'changed',ARRAY['stored helper source line endings'],
      'preserved',ARRAY['AR operations and allocations','Events/Journals',
        'Customer Balance','POS Retail','Stock/Reservation/FIFO/HPP'],
      'next','Run focused rollback behavior, Task 5 and Task 6 regressions, then this postflight again')
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY check_name;
