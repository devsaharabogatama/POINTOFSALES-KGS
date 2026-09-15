-- SELECT-only preflight for 20260909162000.
WITH checks AS (
  SELECT 'required_migration_chain'::text check_name,
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END status,
    abs(6-count(*))::bigint violation_rows,
    jsonb_build_object('expected',6,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260908100000','20260908110000','20260909145000',
    '20260909152000','20260909156000','20260909161000')
  UNION ALL
  SELECT 'cutover_foundation_name_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('collisionRows',count(*))
  FROM information_schema.tables
  WHERE table_schema='public' AND table_name IN(
    'company_sales_process_settings','company_sales_process_mode_history',
    'sales_process_cutover_plans','sales_process_cutover_items',
    'sales_process_cutover_audit')
  UNION ALL
  SELECT 'cutover_foundation_routine_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('collisionRows',count(*))
  FROM pg_proc proc JOIN pg_namespace namespace ON namespace.oid=proc.pronamespace
  WHERE namespace.nspname='private' AND proc.proname IN(
    'classify_sales_process_conversion_candidate',
    'trg_initialize_company_sales_process_setting',
    'trg_guard_company_sales_process_setting',
    'trg_guard_sales_process_history')
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*)::bigint,
    jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'sales_process_identity_contract',
    CASE WHEN count(*)=2
      AND bool_and(column_state.is_nullable='NO')
      AND to_regprocedure('private.trg_guard_sales_process_identity()') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=2
      AND bool_and(column_state.is_nullable='NO')
      AND to_regprocedure('private.trg_guard_sales_process_identity()') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('columnRows',count(*),'immutableGuardExists',
      to_regprocedure('private.trg_guard_sales_process_identity()') IS NOT NULL)
  FROM information_schema.columns column_state
  WHERE column_state.table_schema='public' AND column_state.table_name='sales_headers'
    AND column_state.column_name IN('sales_origin','sales_process_mode')
  UNION ALL
  SELECT 'nonterminal_offline_submission_inventory','INFO',0::bigint,
    jsonb_build_object('submissionRows',count(*),
      'rule','Foundation does not process or invalidate Offline submissions')
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'open_cross_process_inventory','INFO',0::bigint,jsonb_build_object(
    'companies',(SELECT count(*) FROM public.companies),
    'retailDraftOrScheduled',(SELECT count(*) FROM public.sales_headers
      WHERE order_runtime_status IN('DRAFT_INPUT','SCHEDULED')),
    'retailOpenReservations',(SELECT count(*) FROM public.sales_stock_reservations
      WHERE status IN('OPEN','PARTIALLY_DISPATCHED')),
    'retailOpenProcurementLines',(SELECT count(*)
      FROM public.sales_order_procurement_demand_lines
      WHERE status IN('OPEN','REQUESTED','ORDERED','AMENDMENT_REQUIRED')),
    'backofficeOpenOrders',(SELECT count(*) FROM public.backoffice_sales_orders
      WHERE status IN('DRAFT','SENT','CONFIRMED')
        AND fulfillment_status<>'COMPLETED'),
    'backofficeOpenReservations',(SELECT count(*)
      FROM public.backoffice_sales_reservations WHERE status<>'RELEASED'),
    'retailPendingRevisions',(SELECT count(*) FROM public.sales_order_revisions
      WHERE status='PENDING'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
