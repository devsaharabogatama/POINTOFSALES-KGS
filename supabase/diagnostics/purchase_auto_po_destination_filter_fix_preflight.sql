-- SELECT-only preflight for the remaining AUTO_PO destination filter.
WITH definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')) body
), checks AS (
  SELECT 's5b1_dependency_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260914110000'
  UNION ALL
  SELECT 's5b1_remaining_destination_filter',
    CASE WHEN occurrences=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-occurrences),jsonb_build_object('expected',1,'present',occurrences)
  FROM definition CROSS JOIN LATERAL(SELECT
    (length(body)-length(replace(body,'AND line.destination_warehouse_id IS NOT NULL','')))/
      length('AND line.destination_warehouse_id IS NOT NULL') occurrences) fact
  UNION ALL
  SELECT 's5b1_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 's5b1_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
