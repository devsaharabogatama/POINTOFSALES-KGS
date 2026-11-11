-- READ ONLY. Run after 20261110140000 and again after rollback behavior.
WITH routine AS (
  SELECT pg_get_functiondef(proc.oid) definition,proc.prosecdef,
    proc.proconfig,proc.proacl,pg_get_userbyid(proc.proowner) owner_name
  FROM pg_proc proc WHERE proc.oid=
    'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)'::regprocedure
), checks AS (
  SELECT 'backoffice_ar_function_source_normalization_postflight_migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20261110140000'
  UNION ALL
  SELECT 'backoffice_ar_function_source_normalization_postflight_runtime_contract',
    CASE WHEN md5(definition)='1f3eb44dda2997282789da828e31fa81'
        AND md5(replace(definition,E'\r\n',E'\n'))='1f3eb44dda2997282789da828e31fa81'
        AND prosecdef
        AND has_function_privilege('authenticated',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
        AND NOT has_function_privilege('anon',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN md5(definition)='1f3eb44dda2997282789da828e31fa81'
        AND md5(replace(definition,E'\r\n',E'\n'))='1f3eb44dda2997282789da828e31fa81'
        AND prosecdef
        AND has_function_privilege('authenticated',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
        AND NOT has_function_privilege('anon',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('rawMd5',md5(definition),
      'normalizedMd5',md5(replace(definition,E'\r\n',E'\n')),
      'owner',owner_name,'securityDefiner',prosecdef,
      'runtimeConfig',proconfig,'accessControl',proacl) FROM routine
  UNION ALL
  SELECT 'backoffice_ar_function_source_normalization_postflight_business_boundary',
    'INFO',0,jsonb_build_object(
      'changed',ARRAY['stored function source line endings'],
      'preserved',ARRAY['AR operations and allocations','Events/Journals',
        'Customer Balance','POS Retail','Stock/Reservation/FIFO/HPP'],
      'next','Run Task 5 rollback behavior then this postflight again')
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;

