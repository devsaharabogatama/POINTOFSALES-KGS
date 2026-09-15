-- SELECT-only preflight for 20260910140000.
-- Isolated Development only. This statement performs no write.
WITH checks AS (
  SELECT 'preflight_environment_identity'::text check_name,'INFO'::text status,
    0::bigint violation_rows,
    jsonb_build_object('database',current_database(),'databaseUser',current_user,
      'serverAddress',inet_server_addr(),'serverPort',inet_server_port()) details
  UNION ALL
  SELECT 'migration_not_yet_applied',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260910140000'
  UNION ALL
  SELECT 'procurement_blocker_dependency',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*))::bigint,jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260910130000'
  UNION ALL
  SELECT 'procurement_classifier_routine_contract',
    CASE WHEN count(*)=1 AND bool_and(proc.provolatile='i')
      AND bool_and(NOT proc.prosecdef) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(proc.provolatile='i')
      AND bool_and(NOT proc.prosecdef) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'volatility',min(proc.provolatile::text),
      'securityDefiner',bool_or(proc.prosecdef))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private' AND proc.oid=to_regprocedure(
    'private.classify_sales_process_conversion_candidate(text,text,boolean,boolean,boolean,boolean,boolean,boolean,boolean,boolean)')
  UNION ALL
  SELECT 'open_cutover_plan_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('openPlans',count(*),'required','Cancel through canonical RPC; never delete')
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'active_finance_queue_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('activeRuns',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'legacy_open_procurement_classifier',
    CASE WHEN result->>'decision'='CONVERT'
      AND result->'requirementCodes' ? 'TRANSFER_PROCUREMENT_LINEAGE'
      THEN 'SETUP' ELSE 'BLOCKER' END,
    CASE WHEN result->>'decision'='CONVERT'
      AND result->'requirementCodes' ? 'TRANSFER_PROCUREMENT_LINEAGE'
      THEN 1 ELSE 0 END,
    jsonb_build_object('currentResult',result,
      'target','BLOCKED + OPEN_PROCUREMENT_MUST_FINISH')
  FROM (SELECT private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
      false,false,false,false,false,false,true) result) classifier
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'SETUP' THEN 1
  WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
