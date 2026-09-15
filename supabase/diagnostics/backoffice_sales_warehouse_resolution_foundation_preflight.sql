-- SELECT-only preflight for 20260912110000. Run the entire file.
WITH checks AS (
  SELECT 'active_finance_queue' check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,count(*) violation_rows,
    jsonb_build_object('runRows',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'warehouse_resolution_dependency_ledger',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,4-count(*),
    jsonb_build_object('expected',4,'present',count(*))
  FROM private.kgs_schema_migrations
  WHERE version IN('20260911164000','20260911165000','20260911166000','20260912100000')
  UNION ALL
  SELECT 'warehouse_resolution_relation_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(table_name ORDER BY table_name),'[]'::jsonb))
  FROM information_schema.tables
  WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_discrepancy_stock_effects',
    'backoffice_sales_discrepancy_fifo_allocations',
    'backoffice_sales_discrepancy_backorders',
    'backoffice_sales_discrepancy_backorder_lines')
  UNION ALL
  SELECT 'warehouse_resolution_column_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(column_name),'[]'::jsonb))
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='backoffice_sales_order_lines'
    AND column_name='approved_overage_base_qty'
  UNION ALL
  SELECT 'warehouse_resolution_source_constraint_contract',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,abs(2-count(*)),
    jsonb_build_object('expected',2,'present',count(*),
      'constraints',COALESCE(jsonb_agg(constraint_row.conname ORDER BY constraint_row.conname),'[]'::jsonb))
  FROM pg_constraint constraint_row
  WHERE (constraint_row.conrelid='public.backoffice_sales_delivery_discrepancy_lines'::regclass
      AND constraint_row.conname='backoffice_sales_delivery_discrepancy_lines_warehouse_check')
    OR (constraint_row.conrelid='public.backoffice_sales_order_lines'::regclass
      AND constraint_row.conname='backoffice_sales_order_lines_invoiceable_quantity_check')
  UNION ALL
  SELECT 'warehouse_resolution_stock_identity_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(constraint_row.conname),'[]'::jsonb))
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.stock_movements'::regclass
    AND constraint_row.conname='bo_stock_movements_company_id_unique'
  UNION ALL
  SELECT 'warehouse_resolution_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(p.oid::regprocedure::text),'[]'::jsonb))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.proname IN(
    'validate_backoffice_sales_discrepancy_stock_effect',
    'validate_backoffice_sales_discrepancy_fifo_allocation')
  UNION ALL
  SELECT 'accepted_overage_warehouse_state',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('unsupportedRows',count(*),
      'allowedBeforeMigration',ARRAY['NOT_REQUIRED','PENDING'])
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE requested_resolution='ACCEPT_OVERAGE'
    AND warehouse_resolution_status NOT IN('NOT_REQUIRED','PENDING')
  UNION ALL
  SELECT 'approved_overage_existing_quantity_compatibility',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidRows',count(*),
      'rule','Before this migration accepted quantity may not exceed ordered quantity')
  FROM public.backoffice_sales_order_lines line
  WHERE line.accepted_base_qty>line.ordered_base_qty
  UNION ALL
  SELECT 'warehouse_resolution_runtime_inventory','INFO',0,
    jsonb_build_object('openDiscrepancies',count(DISTINCT discrepancy.id),
      'acceptedOverageLines',count(*) FILTER(WHERE line.requested_resolution='ACCEPT_OVERAGE'),
      'backorderLines',count(*) FILTER(WHERE line.requested_resolution IN('BACKORDER','REPLACE_WRONG_ITEM')))
  FROM public.backoffice_sales_delivery_discrepancies discrepancy
  JOIN public.backoffice_sales_delivery_discrepancy_lines line
    ON line.company_id=discrepancy.company_id AND line.discrepancy_id=discrepancy.id
  WHERE discrepancy.status NOT IN('RESOLVED','CANCELED')
  UNION ALL
  SELECT 'preflight_revision','INFO',0,
    jsonb_build_object('revision','STEP_4_6_5A_WAREHOUSE_FOUNDATION_V1',
      'writes',false,'executionRule','Run the entire file; do not run selected text')
)
SELECT check_name,status,GREATEST(violation_rows,0)::bigint violation_rows,details
FROM checks ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
