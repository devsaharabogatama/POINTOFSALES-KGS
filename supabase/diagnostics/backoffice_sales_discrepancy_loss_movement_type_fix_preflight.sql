-- SELECT-only preflight for Step 5/6.2 forward-fix 20260912136000.
WITH definition AS (
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)')) body
), facts AS (
  SELECT
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260912135000') dependency_rows,
    (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20260912136000') migration_rows,
    EXISTS(SELECT 1 FROM pg_enum enum_value
      JOIN pg_type enum_type ON enum_type.oid=enum_value.enumtypid
      JOIN pg_namespace namespace ON namespace.oid=enum_type.typnamespace
      WHERE namespace.nspname='public' AND enum_type.typname='stock_movement_type'
        AND enum_value.enumlabel='BACKOFFICE_DISCREPANCY_LOSS') enum_exists,
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_rows,
    (SELECT pg_get_constraintdef(constraint_state.oid)
      FROM pg_constraint constraint_state
      WHERE constraint_state.conrelid='public.stock_movements'::regclass
        AND constraint_state.conname='stock_movements_adjustment_snapshot_complete') adjustment_constraint
), checks AS (
  SELECT 's5_2f_dependency_ledger' check_name,
    CASE WHEN dependency_rows=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(dependency_rows-1)::bigint violation_rows,
    jsonb_build_object('requiredVersion','20260912135000','ledgerRows',dependency_rows) details
  FROM facts
  UNION ALL SELECT 's5_2f_migration_collision',
    CASE WHEN migration_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    migration_rows::bigint,jsonb_build_object('ledgerRows',migration_rows) FROM facts
  UNION ALL SELECT 's5_2f_active_finance_queue',
    CASE WHEN active_finance=0 THEN 'PASS' ELSE 'BLOCKER' END,
    active_finance::bigint,jsonb_build_object('runRows',active_finance) FROM facts
  UNION ALL SELECT 's5_2f_nonterminal_offline',
    CASE WHEN offline_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    offline_rows::bigint,jsonb_build_object('submissionRows',offline_rows) FROM facts
  UNION ALL SELECT 's5_2f_adjustment_constraint_contract',
    CASE WHEN adjustment_constraint IS NOT NULL
      AND position('ADJUSTMENT' in adjustment_constraint)>0
      AND position('stock_adjustment_documents' in adjustment_constraint)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN adjustment_constraint IS NOT NULL
      AND position('ADJUSTMENT' in adjustment_constraint)>0
      AND position('stock_adjustment_documents' in adjustment_constraint)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('constraint',adjustment_constraint) FROM facts
  UNION ALL SELECT 's5_2f_resolver_anchor_contract',
    CASE WHEN body IS NOT NULL
      AND (length(body)-length(replace(body,
        '''ADJUSTMENT''::public.stock_movement_type','')))
        /length('''ADJUSTMENT''::public.stock_movement_type')=1
      AND position('''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type' in body)=0
      AND position('backoffice_sales_discrepancy_stock_effects' in body)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN body IS NOT NULL
      AND (length(body)-length(replace(body,
        '''ADJUSTMENT''::public.stock_movement_type','')))
        /length('''ADJUSTMENT''::public.stock_movement_type')=1
      AND position('''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type' in body)=0
      AND position('backoffice_sales_discrepancy_stock_effects' in body)>0
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('resolverExists',body IS NOT NULL,
      'legacyMarkerCount',CASE WHEN body IS NULL THEN 0 ELSE
        (length(body)-length(replace(body,
          '''ADJUSTMENT''::public.stock_movement_type','')))
          /length('''ADJUSTMENT''::public.stock_movement_type') END,
      'newMarkerPresent',COALESCE(position(
        '''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type' in body)>0,false))
  FROM definition
  UNION ALL SELECT 's5_2f_enum_state',
    CASE WHEN enum_exists THEN 'PASS' ELSE 'SETUP' END,0::bigint,
    jsonb_build_object('enumExists',enum_exists,
      'rule','SETUP is allowed; migration adds the enum before replacing the resolver') FROM facts
  UNION ALL SELECT 's5_2f_existing_invalid_movement_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM public.stock_movements movement
  WHERE movement.reference_table='backoffice_sales_discrepancy_stock_effects'
    AND movement.movement_type='ADJUSTMENT'::public.stock_movement_type
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
