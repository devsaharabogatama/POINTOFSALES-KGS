-- SELECT-only preflight for source-known/destination-unset Supplier Order lines.
WITH constraint_fact AS (
  SELECT pg_get_constraintdef(oid) definition
  FROM pg_constraint
  WHERE conrelid='public.supplier_order_lines'::regclass
    AND conname='supplier_order_line_warehouse_pair_check'
), checks AS (
  SELECT 's5b2_dependency_ledger' check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END status,
    2-count(*) violation_rows,jsonb_build_object('expected',2,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260914110000','20260914111000')
  UNION ALL
  SELECT 's5b2_legacy_constraint_contract',
    CASE WHEN count(*)=1 AND bool_and(position(
      'source_warehouse_id IS NOT NULL) AND (destination_warehouse_id IS NOT NULL'
      in definition)>0) THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=1 AND bool_and(position(
      'source_warehouse_id IS NOT NULL) AND (destination_warehouse_id IS NOT NULL'
      in definition)>0) THEN 0 ELSE 1 END,
    jsonb_build_object('constraintRows',count(*),'definition',max(definition))
  FROM constraint_fact
  UNION ALL
  SELECT 's5b2_index_collision',CASE WHEN to_regclass(
      'public.supplier_order_lines_unset_destination_unique') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regclass('public.supplier_order_lines_unset_destination_unique') IS NULL
      THEN 0 ELSE 1 END,
    jsonb_build_object('existing',to_regclass(
      'public.supplier_order_lines_unset_destination_unique') IS NOT NULL)
  UNION ALL
  SELECT 's5b2_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 's5b2_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 's5b2_open_sales_cutover',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('planRows',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 's5b2_existing_unset_destination_duplicates',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('duplicateGroups',count(*))
  FROM (SELECT company_id,document_id,product_id,ordered_uom_id,source_warehouse_id
    FROM public.supplier_order_lines
    WHERE source_warehouse_id IS NOT NULL AND destination_warehouse_id IS NULL
    GROUP BY company_id,document_id,product_id,ordered_uom_id,source_warehouse_id
    HAVING count(*)>1) duplicate
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
