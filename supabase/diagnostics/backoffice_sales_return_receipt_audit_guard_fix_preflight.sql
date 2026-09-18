-- SELECT-only preflight for 20260917122000. Run the entire file.
WITH checks AS (
  SELECT 'audit_guard_fix_dependency_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260917121000','ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260917121000'
  UNION ALL
  SELECT 'audit_guard_fix_relation_contract',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,(5-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',5)
  FROM (VALUES('backoffice_sales_return_receipts'),('backoffice_sales_return_receipt_lines'),
    ('backoffice_sales_return_receipt_fifo_restorations'),
    ('backoffice_sales_return_receipt_operations'),('backoffice_sales_return_receipt_audit')) candidate(name)
  WHERE to_regclass('public.'||candidate.name) IS NOT NULL
  UNION ALL
  SELECT 'audit_guard_fix_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'audit_guard_fix_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 ELSE 1 END,check_name;
