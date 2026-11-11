-- READ ONLY. Run before 20261110140000. One result set for SQL Editor.
BEGIN READ ONLY;

WITH
ledger AS (
  SELECT
    count(*) FILTER(WHERE version='20261106100000')::bigint task5_rows,
    count(*) FILTER(WHERE version='20261110100000')::bigint task6_rows,
    count(*) FILTER(WHERE version='20261110140000')::bigint normalization_rows
  FROM private.kgs_schema_migrations
  WHERE version IN('20261106100000','20261110100000','20261110140000')
),
routine AS (
  SELECT pg_get_functiondef(proc.oid) definition,proc.prosecdef,
    proc.proconfig,proc.proacl,pg_get_userbyid(proc.proowner) owner_name
  FROM pg_proc proc WHERE proc.oid=
    'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)'::regprocedure
),
boundary AS (
  SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))::bigint active_queue,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))::bigint offline
),
checks AS (
  SELECT 'backoffice_ar_function_source_normalization_preflight_dependency' check_name,
    CASE WHEN task5_rows=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN task5_rows=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('task5LedgerRows',task5_rows,
      'task6LedgerRows',task6_rows) details
  FROM ledger

  UNION ALL

  SELECT 'backoffice_ar_function_source_normalization_preflight_installation_state',
    CASE WHEN normalization_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    normalization_rows,
    jsonb_build_object('classification',CASE WHEN normalization_rows=0
      THEN 'NOT_INSTALLED' ELSE 'INSTALLED_OR_INCONSISTENT' END,
      'ledgerRows',normalization_rows)
  FROM ledger

  UNION ALL

  SELECT 'backoffice_ar_function_source_normalization_preflight_runtime_contract',
    CASE WHEN md5(replace(definition,E'\r\n',E'\n'))=
        '1f3eb44dda2997282789da828e31fa81'
        AND prosecdef
        AND has_function_privilege('authenticated',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
        AND NOT has_function_privilege('anon',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN md5(replace(definition,E'\r\n',E'\n'))=
        '1f3eb44dda2997282789da828e31fa81'
        AND prosecdef
        AND has_function_privilege('authenticated',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
        AND NOT has_function_privilege('anon',
          'public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('rawMd5',md5(definition),
      'normalizedMd5',md5(replace(definition,E'\r\n',E'\n')),
      'crlfCount',(length(definition)-length(replace(definition,E'\r\n','')))/2,
      'owner',owner_name,'securityDefiner',prosecdef,
      'runtimeConfig',proconfig,'accessControl',proacl)
  FROM routine

  UNION ALL

  SELECT 'backoffice_ar_function_source_normalization_preflight_runtime_boundary',
    CASE WHEN active_queue=0 AND offline=0 THEN 'PASS' ELSE 'BLOCKER' END,
    active_queue+offline,
    jsonb_build_object('activeFinanceQueue',active_queue,
      'nonterminalOffline',offline)
  FROM boundary

  UNION ALL

  SELECT 'backoffice_ar_function_source_normalization_preflight_business_boundary',
    'INFO',0,jsonb_build_object(
      'changed',ARRAY['stored Task 5 Apply function line-ending representation'],
      'preserved',ARRAY['Task 5 behavior','owner/ACL/runtime config',
        'AR data and Journals','Customer Balance','POS Retail','Stock/FIFO'],
      'mutation','NONE')
)
SELECT check_name,status,violation_rows,details
FROM checks ORDER BY check_name;

ROLLBACK;
