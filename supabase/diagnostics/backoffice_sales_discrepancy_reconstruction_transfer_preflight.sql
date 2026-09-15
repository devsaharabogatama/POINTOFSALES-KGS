-- SELECT-only preflight for Step 4/6.5C1.
WITH checks AS (
  SELECT 'reconstruction_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(2-count(*)) violation_rows,jsonb_build_object('expected',2,'present',count(*)) details
  FROM private.kgs_schema_migrations WHERE version IN('20260912120000','20260912121000')
  UNION ALL
  SELECT 'reconstruction_helper_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existing',count(*)) FROM pg_proc
  WHERE oid=to_regprocedure('private.post_backoffice_sales_discrepancy_transfer(uuid,bigint,uuid,uuid)')
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*)) FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*)) FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'reconstruction_candidate_inventory','INFO',0,
    jsonb_build_object('pendingLines',count(*),'cases',count(DISTINCT discrepancy_id))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE discrepancy_type IN('OVERAGE','WRONG_ITEM') AND warehouse_resolution_status='PENDING'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
