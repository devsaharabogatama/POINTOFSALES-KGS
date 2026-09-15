-- SELECT-only preflight for Purchase Step 5/6B Warehouse boundary correction.
WITH definitions AS (
  SELECT
    pg_get_functiondef(to_regprocedure(
      'private.get_purchase_daily_automatic_candidates_core(uuid,date)')) candidate_definition,
    pg_get_functiondef(to_regprocedure(
      'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')) generator_definition,
    pg_get_functiondef(to_regprocedure(
      'public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)')) receipt_definition
), checks AS (
  SELECT 's5b_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    2-count(*) violation_rows,jsonb_build_object('expected',2,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260913130000','20260914100000')
  UNION ALL
  SELECT 's5b_migration_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260914110000'
  UNION ALL
  SELECT 's5b_runtime_contract',
    CASE WHEN candidate_definition IS NOT NULL AND generator_definition IS NOT NULL
      AND receipt_definition IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
    ((candidate_definition IS NULL)::int+(generator_definition IS NULL)::int+
      (receipt_definition IS NULL)::int)::bigint,
    jsonb_build_object('candidate',candidate_definition IS NOT NULL,
      'generator',generator_definition IS NOT NULL,'receipt',receipt_definition IS NOT NULL)
  FROM definitions
  UNION ALL
  SELECT 's5b_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 's5b_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 's5b_open_sales_cutover',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('planRows',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 's5b_existing_warehouse_blocked_auto_po',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('lineRows',count(*),
      'rule','Existing held lines require explicit reconciliation; no automatic second PO')
  FROM public.purchase_daily_batch_lines line
  JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
    AND batch.id=line.batch_id
  WHERE batch.mode_snapshot='AUTO_PO' AND batch.status='DRAFT'
    AND line.readiness_status='WAREHOUSE_SETUP_REQUIRED'
  UNION ALL
  SELECT 's5b_inactive_master_policy',
    CASE WHEN position('PRODUCT_INACTIVE' in candidate_definition)>0
      AND position('SOURCE_WAREHOUSE_INACTIVE' in candidate_definition)>0
      THEN 'PASS' ELSE 'BLOCKER' END,
    ((position('PRODUCT_INACTIVE' in candidate_definition)=0)::int+
      (position('SOURCE_WAREHOUSE_INACTIVE' in candidate_definition)=0)::int)::bigint,
    jsonb_build_object('productInactiveExcluded',
        position('PRODUCT_INACTIVE' in candidate_definition)>0,
      'sourceWarehouseInactiveExcluded',
        position('SOURCE_WAREHOUSE_INACTIVE' in candidate_definition)>0,
      'rule','Inactive Product and inactive source Warehouse remain excluded from AUTO_PO')
  FROM definitions
  UNION ALL
  SELECT 's5b_runtime_inventory','INFO',0,jsonb_build_object(
    'draftAutoPoBatches',(SELECT count(*) FROM public.purchase_daily_batches
      WHERE mode_snapshot='AUTO_PO' AND status='DRAFT'),
    'warehouseBlockedLines',(SELECT count(*) FROM public.purchase_daily_batch_lines
      WHERE readiness_status='WAREHOUSE_SETUP_REQUIRED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
