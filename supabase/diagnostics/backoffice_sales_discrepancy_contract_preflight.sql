-- SELECT-only preflight for Step 4/6.1. Run only on isolated Development.
WITH migration_state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911164000') AS applied
), checks AS (
  SELECT 'discrepancy_dependency_ledger' check_name,
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END status,
    count(*)::bigint violation_rows,
    jsonb_build_object('present',count(*),'expected',6) details
  FROM private.kgs_schema_migrations WHERE version IN(
    '20260909152000','20260909154000','20260909155000',
    '20260911140000','20260911150000','20260911163000')
  UNION ALL
  SELECT 'discrepancy_relation_collision',
    CASE WHEN (state.applied AND inventory.object_count=4)
      OR (NOT state.applied AND inventory.object_count=0) THEN 'PASS' ELSE 'BLOCKER' END,
    inventory.object_count,
    jsonb_build_object('migrationApplied',state.applied,'existing',inventory.objects,
      'expected',CASE WHEN state.applied THEN 4 ELSE 0 END)
  FROM migration_state state CROSS JOIN LATERAL (
    SELECT count(*) object_count,
      COALESCE(jsonb_agg(rel.relname ORDER BY rel.relname),'[]'::jsonb) objects
    FROM pg_class rel JOIN pg_namespace ns ON ns.oid=rel.relnamespace
    WHERE ns.nspname='public' AND rel.relname IN(
      'backoffice_sales_delivery_discrepancies','backoffice_sales_delivery_discrepancy_lines',
      'backoffice_sales_discrepancy_operations','backoffice_sales_discrepancy_audit')
  ) inventory
  UNION ALL
  SELECT 'discrepancy_routine_collision',
    CASE WHEN (state.applied AND inventory.object_count=3)
      OR (NOT state.applied AND inventory.object_count=0) THEN 'PASS' ELSE 'BLOCKER' END,
    inventory.object_count,
    jsonb_build_object('migrationApplied',state.applied,'existing',inventory.objects,
      'expected',CASE WHEN state.applied THEN 3 ELSE 0 END)
  FROM migration_state state CROSS JOIN LATERAL (
    SELECT count(*) object_count,
      COALESCE(jsonb_agg(proc.proname ORDER BY proc.proname),'[]'::jsonb) objects
    FROM pg_proc proc JOIN pg_namespace ns ON ns.oid=proc.pronamespace
    WHERE ns.nspname='private' AND proc.proname IN(
      'classify_backoffice_sales_discrepancy',
      'validate_backoffice_sales_receipt_disposition_payload',
      'trg_guard_backoffice_sales_discrepancy_history')
  ) inventory
  UNION ALL
  SELECT 'canonical_customer_receipt_runtime',
    CASE WHEN to_regprocedure('private.receive_backoffice_sales_delivery_core(uuid,bigint,uuid,date,text)') IS NOT NULL
      AND to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('private.receive_backoffice_sales_delivery_core(uuid,bigint,uuid,date,text)') IS NOT NULL
      AND to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('privateCore',to_regprocedure(
      'private.receive_backoffice_sales_delivery_core(uuid,bigint,uuid,date,text)') IS NOT NULL,
      'publicWrapper',to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL)
  UNION ALL
  SELECT 'active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'discrepancy_runtime_inventory','INFO',0,
    jsonb_build_object('inTransitDeliveries',count(*) FILTER(WHERE status='IN_TRANSIT'),
      'completedDeliveries',count(*) FILTER(WHERE status='COMPLETED'))
  FROM public.backoffice_sales_delivery_orders
)
SELECT check_name,status,
  CASE WHEN status='PASS' THEN 0 ELSE violation_rows END violation_rows,details
FROM checks ORDER BY check_name;
