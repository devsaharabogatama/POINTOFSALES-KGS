-- Catalog-only, SELECT-only preflight for 20260910110000.
-- Safe to run even when the cutover foundation is absent or partially applied.
WITH expected_relations(relation_name) AS (
  VALUES
    ('company_sales_process_settings'::text),
    ('company_sales_process_mode_history'),
    ('sales_process_cutover_plans'),
    ('sales_process_cutover_items'),
    ('sales_process_cutover_audit')
), relation_state AS (
  SELECT expected.relation_name,
    (table_state.table_name IS NOT NULL) AS relation_exists
  FROM expected_relations expected
  LEFT JOIN information_schema.tables table_state
    ON table_state.table_schema='public'
   AND table_state.table_name=expected.relation_name
), expected_preview_routines(routine_signature) AS (
  VALUES
    ('private.get_sales_process_cutover_preview_core(uuid,text)'::text),
    ('public.get_sales_process_cutover_preview(text)')
), preview_routine_state AS (
  SELECT expected.routine_signature,
    (to_regprocedure(expected.routine_signature) IS NOT NULL) AS routine_exists
  FROM expected_preview_routines expected
), checks AS (
  SELECT 'cutover_dependency_ledger'::text check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(2-count(*))::bigint violation_rows,
    jsonb_build_object('expectedVersions',ARRAY['20260909162000','20260909163000'],
      'presentVersions',COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260909162000','20260909163000')
  UNION ALL
  SELECT 'cutover_foundation_relation_contract',
    CASE WHEN bool_and(relation_exists) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE NOT relation_exists)::bigint,
    jsonb_build_object('expected',count(*),
      'present',count(*) FILTER(WHERE relation_exists),
      'missing',COALESCE(jsonb_agg(relation_name ORDER BY relation_name)
        FILTER(WHERE NOT relation_exists),'[]'::jsonb))
  FROM relation_state
  UNION ALL
  SELECT 'cutover_preview_routine_contract',
    CASE WHEN bool_and(routine_exists) THEN 'PASS' ELSE 'BLOCKER' END,
    count(*) FILTER(WHERE NOT routine_exists)::bigint,
    jsonb_build_object('expected',count(*),
      'present',count(*) FILTER(WHERE routine_exists),
      'missing',COALESCE(jsonb_agg(routine_signature ORDER BY routine_signature)
        FILTER(WHERE NOT routine_exists),'[]'::jsonb))
  FROM preview_routine_state
  UNION ALL
  SELECT 'persistent_preview_digest_dependency',
    CASE WHEN to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineExists',
      to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL)
  UNION ALL
  SELECT 'persistent_preview_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('collisionRows',count(*),
      'routines',COALESCE(jsonb_agg(namespace.nspname||'.'||proc.proname
        ORDER BY namespace.nspname,proc.proname),'[]'::jsonb))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE (namespace.nspname='private' AND proc.proname IN(
      'get_sales_process_cutover_plan_core','create_sales_process_cutover_plan_core'))
    OR (namespace.nspname='public' AND proc.proname IN(
      'get_sales_process_cutover_plan','create_sales_process_cutover_plan'))
  UNION ALL
  SELECT 'preflight_environment_identity','INFO',0::bigint,
    jsonb_build_object('database',current_database(),'databaseUser',current_user,
      'serverAddress',inet_server_addr()::text,
      'serverPort',inet_server_port())
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
