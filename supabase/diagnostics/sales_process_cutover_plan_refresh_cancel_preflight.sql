-- Catalog-only, SELECT-only preflight for 20260910120000.
WITH checks AS (
  SELECT 'persistent_preview_dependency'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910110000'
  UNION ALL
  SELECT 'refresh_cancel_relation_contract',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(3-count(*))::bigint,jsonb_build_object('expected',3,'relationRows',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'sales_process_cutover_plans','sales_process_cutover_items','sales_process_cutover_audit')
  UNION ALL
  SELECT 'refresh_cancel_runtime_dependency',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(3-count(*))::bigint,jsonb_build_object('expected',3,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('private.get_sales_process_cutover_preview_core(uuid,text)')),
    (to_regprocedure('private.get_sales_process_cutover_plan_core(uuid,uuid)')),
    (to_regprocedure('private.create_sales_process_cutover_plan_core(uuid,uuid,text,timestamptz,bigint,uuid,text)'))
  ) required(routine_oid) WHERE routine_oid IS NOT NULL
  UNION ALL
  SELECT 'plan_master_version_column_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='sales_process_cutover_plans' AND column_name='master_version'
  UNION ALL
  SELECT 'refresh_cancel_routine_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='private' AND proc.proname IN(
      'refresh_sales_process_cutover_plan_core','cancel_sales_process_cutover_plan_core'))
    OR (namespace.nspname='public' AND proc.proname IN(
      'refresh_sales_process_cutover_plan','cancel_sales_process_cutover_plan'))
  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0::bigint,
    jsonb_build_object('database',current_database(),'databaseUser',current_user,
      'serverAddress',inet_server_addr()::text,'serverPort',inet_server_port())
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
