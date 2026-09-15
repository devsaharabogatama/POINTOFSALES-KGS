-- SELECT-only preflight for Step 4/6.5B. Run the entire file.
WITH checks AS (
  SELECT 'active_finance_queue' check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
    count(*) violation_rows,jsonb_build_object('runRows',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'dependency_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*)),jsonb_build_object('expected',1,'present',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260912110000'
  UNION ALL
  SELECT 'shortage_resolver_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existing',count(*))
  FROM pg_proc
  WHERE oid IN(
    to_regprocedure('private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)'),
    to_regprocedure('public.resolve_backoffice_sales_shortage(uuid,bigint,uuid,date,text)'))
  UNION ALL
  SELECT 'nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'pending_shortage_inventory','INFO',0,
    jsonb_build_object('pendingLines',count(*),'cases',count(DISTINCT discrepancy_id))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE discrepancy_type='SHORT' AND warehouse_resolution_status='PENDING'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
