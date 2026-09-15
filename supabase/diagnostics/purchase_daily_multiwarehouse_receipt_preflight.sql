-- SELECT-only preflight for Purchase Daily Replenishment Step 5/6.
WITH state AS (
  SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914100000') migration_applied
), checks AS (
  SELECT 's5_dependency_ledger' check_name,
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    5-count(*) violation_rows,
    jsonb_build_object('expected',5,'present',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260806040000','20260825130000','20260913110000',
    '20260913120000','20260913130000')
  UNION ALL
  SELECT 's5_canonical_receipt_runtime',
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END,4-count(*),
    jsonb_build_object('expected',4,'present',count(*))
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname IN('public','private') AND (
    (namespace.nspname='public' AND procedure.oid IN(
      to_regprocedure('public.save_backoffice_goods_receipt(uuid,bigint,uuid,text,text,jsonb)'),
      to_regprocedure('public.post_backoffice_goods_receipt(uuid,bigint,uuid)'),
      to_regprocedure('public.preview_purchase_ap_posting_queue(integer)')))
    OR (namespace.nspname='private' AND procedure.oid=
      to_regprocedure('private.resolve_opening_stock_account(uuid,uuid,text,timestamptz)')))
  UNION ALL
  SELECT 's5_schema_collision',
    CASE WHEN state.migration_applied OR collision.count_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.migration_applied THEN 0 ELSE collision.count_rows END,
    jsonb_build_object('migrationApplied',state.migration_applied,
      'existing',collision.names)
  FROM state CROSS JOIN LATERAL(SELECT count(*) count_rows,
    COALESCE(jsonb_agg(object_name) FILTER(WHERE object_oid IS NOT NULL),'[]'::jsonb) names
    FROM (VALUES
      ('goods_receipt_unassigned_clearings',to_regclass('public.goods_receipt_unassigned_clearings')),
      ('goods_receipt_supplier_assignments',to_regclass('public.goods_receipt_supplier_assignments')),
      ('goods_receipt_supplier_assignment_operations',to_regclass('public.goods_receipt_supplier_assignment_operations'))
    ) object(object_name,object_oid) WHERE object_oid IS NOT NULL) collision
  UNION ALL
  SELECT 's5_routine_collision',
    CASE WHEN state.migration_applied OR collision.count_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.migration_applied THEN 0 ELSE collision.count_rows END,
    jsonb_build_object('migrationApplied',state.migration_applied,'existing',collision.count_rows)
  FROM state CROSS JOIN LATERAL(SELECT count(*) count_rows FROM unnest(ARRAY[
      to_regprocedure('public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)'),
      to_regprocedure('public.post_purchase_daily_goods_receipt(uuid,bigint,uuid)'),
      to_regprocedure('public.assign_purchase_daily_receipt_suppliers(uuid,bigint,uuid,jsonb)')
    ]) oid WHERE oid IS NOT NULL) collision
  UNION ALL
  SELECT 's5_finance_catalog_collision',
    CASE WHEN state.migration_applied OR collision.count_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN state.migration_applied THEN 0 ELSE collision.count_rows END,
    jsonb_build_object('migrationApplied',state.migration_applied,
      'existingKeys',collision.existing_keys)
  FROM state CROSS JOIN LATERAL(SELECT count(*) count_rows,
    COALESCE(jsonb_agg(key_name),'[]'::jsonb) existing_keys FROM (
      SELECT function_key key_name FROM public.account_functions
      WHERE function_key='PURCHASE_UNASSIGNED_CLEARING'
      UNION ALL
      SELECT system_key FROM public.system_events
      WHERE system_key='GOODS_RECEIPT_SUPPLIER_ASSIGNMENT') existing) collision
  UNION ALL
  SELECT 's5_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 's5_daily_receipt_source_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('invalidLines',count(*),
      'rule','Daily Supplier Order line must retain source and destination Warehouse')
  FROM public.supplier_order_lines line JOIN public.supplier_order_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  WHERE document.order_source='DAILY_REPLENISHMENT'
    AND (line.source_warehouse_id IS NULL OR line.destination_warehouse_id IS NULL)
  UNION ALL
  SELECT 's5_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 's5_runtime_inventory','INFO',0,jsonb_build_object(
    'dailyOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE order_source='DAILY_REPLENISHMENT'),
    'pendingOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE order_source='DAILY_REPLENISHMENT' AND supplier_assignment_status='SUPPLIER_PENDING'),
    'receipts',(SELECT count(*) FROM public.goods_receipt_documents))
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY
  CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
