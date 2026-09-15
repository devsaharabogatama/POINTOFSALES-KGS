WITH dependency_versions(version) AS (
  VALUES
    ('20260908100000'::text),
    ('20260909162000'::text),
    ('20260909163000'::text),
    ('20260910110000'::text),
    ('20260910120000'::text)
), dependency_state AS (
  SELECT count(*)::bigint AS present
  FROM dependency_versions expected
  JOIN private.kgs_schema_migrations ledger USING(version)
), column_state AS (
  SELECT column_name,is_nullable
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='sales_headers'
    AND column_name IN('session_id','pos_id','created_session_id',
      'sales_origin','sales_process_mode','source_channel')
), constraint_state AS (
  SELECT constraint_name
  FROM information_schema.table_constraints
  WHERE table_schema='public' AND table_name='sales_headers'
    AND constraint_name IN('sales_headers_origin_check',
      'sales_headers_process_mode_check','sales_headers_origin_process_pair_check')
), routine_state AS (
  SELECT to_regprocedure(
    'private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)'
  ) AS classifier,
  to_regprocedure('private.trg_guard_sales_process_identity()') AS identity_guard,
  to_regprocedure('private.trg_g4_prepare_sale_draft()') AS draft_prepare
), relation_state AS (
  SELECT to_regclass('public.sales_process_cutover_plans') AS plans,
    to_regclass('public.finance_posting_queue_runs') AS finance_queue,
    to_regclass('public.pos_offline_sale_submissions') AS offline_submissions
), checks AS (
  SELECT 'cutover_identity_dependency_ledger' check_name,
    CASE WHEN present=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    (5-present)::bigint violation_rows,
    jsonb_build_object('expected',5,'present',present) details
  FROM dependency_state
  UNION ALL
  SELECT 'cutover_identity_required_columns',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,
    (6-count(*))::bigint,
    jsonb_build_object('expected',6,'present',count(*),
      'columns',COALESCE(jsonb_agg(jsonb_build_array(column_name,is_nullable)
        ORDER BY column_name),'[]'::jsonb))
  FROM column_state
  UNION ALL
  SELECT 'cutover_identity_current_not_null_contract',
    CASE WHEN count(*) FILTER(WHERE is_nullable='NO')=3 THEN 'PASS' ELSE 'BLOCKER' END,
    (3-count(*) FILTER(WHERE is_nullable='NO'))::bigint,
    jsonb_build_object('requiredBeforeMigration',
      ARRAY['session_id','pos_id','created_session_id'],
      'notNullColumns',COALESCE(jsonb_agg(column_name ORDER BY column_name)
        FILTER(WHERE is_nullable='NO'),'[]'::jsonb))
  FROM column_state
  WHERE column_name IN('session_id','pos_id','created_session_id')
  UNION ALL
  SELECT 'cutover_identity_constraint_dependencies',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    (3-count(*))::bigint,
    jsonb_build_object('expected',3,'present',count(*),
      'constraints',COALESCE(jsonb_agg(constraint_name ORDER BY constraint_name),'[]'::jsonb))
  FROM constraint_state
  UNION ALL
  SELECT 'cutover_identity_routine_dependencies',
    CASE WHEN classifier IS NOT NULL AND identity_guard IS NOT NULL
      AND draft_prepare IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
    ((classifier IS NULL)::int+(identity_guard IS NULL)::int+
      (draft_prepare IS NULL)::int)::bigint,
    jsonb_build_object('classifierExists',classifier IS NOT NULL,
      'identityGuardExists',identity_guard IS NOT NULL,
      'draftPrepareExists',draft_prepare IS NOT NULL)
  FROM routine_state
  UNION ALL
  SELECT 'cutover_identity_relation_dependencies',
    CASE WHEN plans IS NOT NULL AND finance_queue IS NOT NULL
      AND offline_submissions IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
    ((plans IS NULL)::int+(finance_queue IS NULL)::int+
      (offline_submissions IS NULL)::int)::bigint,
    jsonb_build_object('plansExists',plans IS NOT NULL,
      'financeQueueExists',finance_queue IS NOT NULL,
      'offlineSubmissionsExists',offline_submissions IS NOT NULL)
  FROM relation_state
  UNION ALL
  SELECT 'cutover_identity_helper_collision',
    CASE WHEN to_regprocedure(
      'private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)'
    ) IS NULL THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure(
      'private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)'
    ) IS NULL THEN 0 ELSE 1 END,
    jsonb_build_object('helperExists',to_regprocedure(
      'private.sales_process_retail_identity_is_valid(text,text,uuid,uuid,uuid)'
    ) IS NOT NULL)
  UNION ALL
  SELECT 'open_cutover_plan_boundary',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*)::bigint violation_rows,
  jsonb_build_object('openPlans',count(*)) details
FROM public.sales_process_cutover_plans
WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'active_finance_queue_boundary',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*)::bigint violation_rows,
  jsonb_build_object('activeRuns',count(*)) details
FROM public.finance_posting_queue_runs
WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission_boundary',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*)::bigint violation_rows,
  jsonb_build_object('submissionRows',count(*)) details
FROM public.pos_offline_sale_submissions
WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'sales_identity_existing_rows',
  CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
  count(*)::bigint violation_rows,
  jsonb_build_object('invalidRows',count(*)) details
FROM public.sales_headers
WHERE sales_origin NOT IN('POS','BACKOFFICE_SALES')
   OR sales_process_mode NOT IN(
     'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')
   OR session_id IS NULL OR pos_id IS NULL OR created_session_id IS NULL
)
SELECT * FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 ELSE 1 END,check_name;
