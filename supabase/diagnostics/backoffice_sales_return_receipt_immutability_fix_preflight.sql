-- SELECT-only preflight for 20260917121000. Run the entire file.
WITH trigger_inventory AS (
  SELECT table_state.table_name,trigger_state.tgname,
    COALESCE(trigger_state.tgenabled,'-') enabled
  FROM (VALUES
    ('backoffice_sales_return_receipts','backoffice_sales_return_receipts_immutable'),
    ('backoffice_sales_return_receipt_lines','backoffice_sales_return_receipt_lines_immutable'),
    ('backoffice_sales_return_receipt_fifo_restorations','backoffice_sales_return_receipt_fifo_immutable'),
    ('backoffice_sales_return_receipt_operations','backoffice_sales_return_receipt_operations_immutable'),
    ('backoffice_sales_return_receipt_audit','backoffice_sales_return_receipt_audit_immutable')
  ) table_state(table_name,trigger_name)
  LEFT JOIN pg_class relation ON relation.oid=to_regclass('public.'||table_state.table_name)
  LEFT JOIN pg_trigger trigger_state ON trigger_state.tgrelid=relation.oid
    AND trigger_state.tgname=table_state.trigger_name AND NOT trigger_state.tgisinternal
), checks AS (
  SELECT 'immutability_fix_dependency_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('requiredVersion','20260917120000') details
  FROM private.kgs_schema_migrations WHERE version='20260917120000'
  UNION ALL
  SELECT 'immutability_fix_relation_contract',
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END,(5-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',5)
  FROM (VALUES('backoffice_sales_return_receipts'),('backoffice_sales_return_receipt_lines'),
    ('backoffice_sales_return_receipt_fifo_restorations'),
    ('backoffice_sales_return_receipt_operations'),('backoffice_sales_return_receipt_audit')) candidate(name)
  WHERE to_regclass('public.'||candidate.name) IS NOT NULL
  UNION ALL
  SELECT 'immutability_fix_guard_routine',
    CASE WHEN to_regprocedure('private.trg_guard_backoffice_sales_return_receipt_history()') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('private.trg_guard_backoffice_sales_return_receipt_history()') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('guardPresent',to_regprocedure(
      'private.trg_guard_backoffice_sales_return_receipt_history()') IS NOT NULL)
  UNION ALL
  SELECT 'immutability_fix_current_trigger_inventory','INFO',0::bigint,
    jsonb_build_object('expected',5,'present',count(tgname),
      'enabledAlways',count(*) FILTER(WHERE enabled='A'),
      'triggers',jsonb_agg(jsonb_build_object('table',table_name,'trigger',tgname,'enabled',enabled)
        ORDER BY table_name))
  FROM trigger_inventory
  UNION ALL
  SELECT 'immutability_fix_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'immutability_fix_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
