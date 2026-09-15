-- SELECT-only postflight for 20260910120000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910120000'
  UNION ALL
  SELECT 'plan_master_version_contract',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*))::bigint,jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='sales_process_cutover_plans' AND column_name='master_version'
    AND is_nullable='NO' AND data_type='bigint' AND column_default IS NOT NULL
  UNION ALL
  SELECT 'required_refresh_cancel_routines',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*))::bigint,jsonb_build_object('expected',4,'routineRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='private' AND proc.proname IN(
    'refresh_sales_process_cutover_plan_core','cancel_sales_process_cutover_plan_core'))
    OR (namespace.nspname='public' AND proc.proname IN(
    'refresh_sales_process_cutover_plan','cancel_sales_process_cutover_plan'))
  UNION ALL
  SELECT 'refresh_cancel_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='anon')=0
      AND count(*) FILTER(WHERE grantee='authenticated')=2 THEN 'PASS' ELSE 'FAIL' END,
    (count(*) FILTER(WHERE grantee='anon')+abs(2-count(*) FILTER(WHERE grantee='authenticated')))::bigint,
    jsonb_build_object('anonExecute',count(*) FILTER(WHERE grantee='anon'),
      'authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'))
  FROM information_schema.routine_privileges WHERE specific_schema='public'
    AND routine_name IN('refresh_sales_process_cutover_plan','cancel_sales_process_cutover_plan')
    AND privilege_type='EXECUTE' AND grantee IN('anon','authenticated')
  UNION ALL
  SELECT 'refresh_cancel_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges WHERE specific_schema='private'
    AND routine_name IN('refresh_sales_process_cutover_plan_core','cancel_sales_process_cutover_plan_core')
    AND privilege_type='EXECUTE' AND grantee='authenticated'
  UNION ALL
  SELECT 'cutover_plan_version_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.sales_process_cutover_plans WHERE master_version<1
  UNION ALL
  SELECT 'canceled_plan_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.sales_process_cutover_plans WHERE status='CANCELED'
    AND (canceled_by IS NULL OR canceled_at IS NULL OR nullif(btrim(cancel_reason),'') IS NULL)
  UNION ALL
  SELECT 'refresh_cancel_audit_response_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.sales_process_cutover_audit WHERE action IN('REFRESH_PREVIEW','CANCEL_PLAN')
    AND (after_state->>'requestHash' IS NULL OR jsonb_typeof(after_state->'response')<>'object')
  UNION ALL
  SELECT 'refresh_cancel_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'previewedPlans',(SELECT count(*) FROM public.sales_process_cutover_plans WHERE status='PREVIEWED'),
    'canceledPlans',(SELECT count(*) FROM public.sales_process_cutover_plans WHERE status='CANCELED'),
    'refreshAudits',(SELECT count(*) FROM public.sales_process_cutover_audit WHERE action='REFRESH_PREVIEW'),
    'cancelAudits',(SELECT count(*) FROM public.sales_process_cutover_audit WHERE action='CANCEL_PLAN'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
