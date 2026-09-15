-- SELECT-only preflight for Step 4/6.2. Isolated Development only.
WITH migration_state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911165000') applied
), checks AS (
  SELECT 'physical_state_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(2-count(*))::bigint violation_rows,
    jsonb_build_object('present',count(*),'expected',2) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260911163000','20260911164000')
  UNION ALL
  SELECT 'physical_state_column_contract',
    CASE WHEN (state.applied AND inventory.column_count=4)
      OR (NOT state.applied AND inventory.column_count=0) THEN 'PASS' ELSE 'BLOCKER' END,
    abs((CASE WHEN state.applied THEN 4 ELSE 0 END)-inventory.column_count),
    jsonb_build_object('migrationApplied',state.applied,'columns',inventory.columns,
      'expected',CASE WHEN state.applied THEN 4 ELSE 0 END)
  FROM migration_state state CROSS JOIN LATERAL (
    SELECT count(*) column_count,
      COALESCE(jsonb_agg(column_name ORDER BY column_name),'[]'::jsonb) columns
    FROM information_schema.columns WHERE table_schema='public'
      AND table_name='backoffice_sales_delivery_discrepancy_lines'
      AND column_name IN('physical_state','actual_uom_id',
        'actual_quantity_uom','actual_quantity_base')
  ) inventory
  UNION ALL
  SELECT 'physical_state_routine_contract',
    CASE WHEN (state.applied AND inventory.routine_count=1)
      OR (NOT state.applied AND inventory.routine_count=0) THEN 'PASS' ELSE 'BLOCKER' END,
    abs((CASE WHEN state.applied THEN 1 ELSE 0 END)-inventory.routine_count),
    jsonb_build_object('migrationApplied',state.applied,
      'threeArgumentClassifierRows',inventory.routine_count,
      'expected',CASE WHEN state.applied THEN 1 ELSE 0 END)
  FROM migration_state state CROSS JOIN LATERAL (
    SELECT count(*) routine_count FROM pg_proc proc
    JOIN pg_namespace ns ON ns.oid=proc.pronamespace
    WHERE ns.nspname='private'
      AND proc.oid=to_regprocedure(
        'private.classify_backoffice_sales_discrepancy(text,text,text)')
  ) inventory
  UNION ALL
  SELECT 'physical_state_unreconciled_runtime_rows',
    CASE WHEN state.applied OR inventory.row_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.applied THEN 0 ELSE inventory.row_count END,
    jsonb_build_object('migrationApplied',state.applied,'runtimeRows',inventory.row_count,
      'rule','Before migration, any row requires explicit data reconciliation; no default is inferred')
  FROM migration_state state CROSS JOIN LATERAL (
    SELECT (SELECT count(*) FROM public.backoffice_sales_delivery_discrepancies)
      +(SELECT count(*) FROM public.backoffice_sales_delivery_discrepancy_lines)
      +(SELECT count(*) FROM public.backoffice_sales_discrepancy_operations)
      +(SELECT count(*) FROM public.backoffice_sales_discrepancy_audit) row_count
  ) inventory
  UNION ALL
  SELECT 'physical_state_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'physical_state_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'physical_state_clean_receipt_compatibility',
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NULL
      THEN 1 ELSE 0 END,
    jsonb_build_object('legacyWrapperPreserved',to_regprocedure(
      'public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NOT NULL)
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY check_name;

