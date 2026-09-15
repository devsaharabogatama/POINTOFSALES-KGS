-- SELECT-only preflight for Step 4/6.5C4. Run the entire file.
WITH facts AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912132000') dependency_ok,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912133000') migration_applied,
    to_regprocedure('public.get_backoffice_sales_discrepancy_workspace(uuid,uuid)') IS NOT NULL read_model_exists,
    to_regprocedure('public.approve_backoffice_sales_delivery_overage(uuid,bigint,uuid,jsonb,text)') IS NOT NULL approval_exists,
    to_regprocedure('public.resolve_backoffice_sales_shortage(uuid,bigint,uuid,date,text)') IS NOT NULL shortage_exists,
    to_regprocedure('public.resolve_backoffice_sales_overage_wrong_item(uuid,bigint,uuid,date,text)') IS NOT NULL other_exists,
    (SELECT count(*) FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance,
    (SELECT count(*) FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_rows
), checks AS (
  SELECT 'c4_dependency_ledger' check_name,
    CASE WHEN dependency_ok THEN 'PASS' ELSE 'BLOCKER' END status,
    CASE WHEN dependency_ok THEN 0 ELSE 1 END::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260912132000','present',dependency_ok) details FROM facts
  UNION ALL SELECT 'c4_read_model_collision',
    CASE WHEN (migration_applied AND read_model_exists) OR (NOT migration_applied AND NOT read_model_exists) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN (migration_applied AND read_model_exists) OR (NOT migration_applied AND NOT read_model_exists) THEN 0 ELSE 1 END,
    jsonb_build_object('migrationApplied',migration_applied,'readModelExists',read_model_exists) FROM facts
  UNION ALL SELECT 'c4_canonical_action_chain',
    CASE WHEN approval_exists AND shortage_exists AND other_exists THEN 'PASS' ELSE 'BLOCKER' END,
    (3-approval_exists::int-shortage_exists::int-other_exists::int)::bigint,
    jsonb_build_object('approval',approval_exists,'shortage',shortage_exists,'overageWrongItem',other_exists) FROM facts
  UNION ALL SELECT 'c4_active_finance_queue',CASE WHEN active_finance=0 THEN 'PASS' ELSE 'BLOCKER' END,
    active_finance,jsonb_build_object('runRows',active_finance) FROM facts
  UNION ALL SELECT 'c4_nonterminal_offline',CASE WHEN offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    offline_rows,jsonb_build_object('submissionRows',offline_rows) FROM facts
  UNION ALL SELECT 'c4_runtime_inventory','INFO',0,
    jsonb_build_object('cases',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancies),
      'pendingSales',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancies WHERE status='PENDING_SALES_APPROVAL'),
      'pendingWarehouse',(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancies WHERE status='PENDING_WAREHOUSE_RESOLUTION')) FROM facts
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
