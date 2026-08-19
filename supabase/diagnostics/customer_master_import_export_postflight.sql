-- Customer master import/export postflight. SELECT-only.

WITH checks AS (
  SELECT 'migration_ledger' check_name,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260819150000')=1 passed,
    jsonb_build_object('ledgerRows',(SELECT count(*)
      FROM private.kgs_schema_migrations WHERE version='20260819150000')) details
  UNION ALL
  SELECT 'customer_import_type_contract',
    pg_get_constraintdef(oid) LIKE '%CUSTOMER%',
    jsonb_build_object('definition',pg_get_constraintdef(oid))
  FROM pg_constraint WHERE conrelid='public.master_import_jobs'::regclass
    AND conname='master_import_jobs_type_check'
  UNION ALL
  SELECT 'required_customer_exchange_routines',count(*)=4,
    jsonb_build_object('routineRows',count(*),'expected',4)
  FROM unnest(ARRAY[
    to_regprocedure('private.create_customer_import_job(uuid,text,text,text,text,text)'),
    to_regprocedure('private.validate_customer_import_job(uuid,bigint)'),
    to_regprocedure('private.commit_customer_import_job(uuid,bigint,integer)'),
    to_regprocedure('public.export_contacts_customers()')
  ]) routine_oid WHERE routine_oid IS NOT NULL
  UNION ALL
  SELECT 'customer_exchange_browser_boundary',
    has_function_privilege('authenticated','public.export_contacts_customers()','EXECUTE')
      AND NOT has_function_privilege('anon','public.export_contacts_customers()','EXECUTE')
      AND NOT has_function_privilege('authenticated',
        'private.commit_customer_import_job(uuid,bigint,integer)','EXECUTE'),
    jsonb_build_object(
      'authenticatedExport',has_function_privilege('authenticated',
        'public.export_contacts_customers()','EXECUTE'),
      'anonExport',has_function_privilege('anon',
        'public.export_contacts_customers()','EXECUTE'),
      'authenticatedPrivateCommit',has_function_privilege('authenticated',
        'private.commit_customer_import_job(uuid,bigint,integer)','EXECUTE'))
  UNION ALL
  SELECT 'customer_import_permission_hook',
    pg_get_functiondef(to_regprocedure(
      'private.acp_require_customer_import_if_needed(uuid,text)')) LIKE '%CUSTOMER%',
    jsonb_build_object('routineRows',1)
  UNION ALL
  SELECT 'nonterminal_customer_import_job',count(*)=0,
    jsonb_build_object('jobCount',count(*))
  FROM public.master_import_jobs WHERE import_type='CUSTOMER'
    AND status NOT IN('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')
  UNION ALL
  SELECT 'customer_export_walk_in_exclusion',
    pg_get_functiondef(to_regprocedure('public.export_contacts_customers()'))
      LIKE '%NOT customer.is_system_customer%',
    jsonb_build_object('systemCustomers',(SELECT count(*) FROM public.customers
      WHERE is_system_customer))
)
SELECT check_name,CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END status,
  CASE WHEN passed THEN 0 ELSE 1 END violation_rows,details
FROM checks ORDER BY status,check_name;

