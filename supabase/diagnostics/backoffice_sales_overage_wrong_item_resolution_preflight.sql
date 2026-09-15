-- SELECT-only preflight for Step 4/6.5C3. Run the whole file.
WITH checks AS (
  SELECT 'c3_dependency_ledger' check_name,
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    5-count(*) violation_rows,
    jsonb_build_object('expected',5,'present',count(*),'required',ARRAY[
      '20260912121000','20260912122000','20260912123000','20260912124000','20260912125000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260912121000','20260912122000','20260912123000','20260912124000','20260912125000')
  UNION ALL
  SELECT 'c3_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'c3_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'c3_routine_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existing',coalesce(jsonb_agg(signature),'[]'::jsonb))
  FROM (SELECT oid::regprocedure::text signature FROM pg_proc WHERE oid IN(
    to_regprocedure('private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'),
    to_regprocedure('public.resolve_backoffice_sales_overage_wrong_item(uuid,bigint,uuid,date,text)'),
    to_regprocedure('private.record_backoffice_sales_discrepancy_transfer_effect(uuid,uuid,uuid,text,uuid)'),
    to_regprocedure('private.post_backoffice_sales_exact_return_transfer(uuid,bigint,uuid,uuid)'))) routine
  UNION ALL
  SELECT 'c3_schema_collision',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('existingColumns',coalesce(jsonb_agg(column_name),'[]'::jsonb))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_discrepancy_backorders'
    AND column_name='resolution_kind'
  UNION ALL
  SELECT 'c3_child_lineage_constraint',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(1-count(*)),jsonb_build_object('expected',1,'present',count(*))
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.backoffice_sales_discrepancy_backorders'::regclass
    AND constraint_row.conname='backoffice_sales_discrepancy_backorders_case_unique'
  UNION ALL
  SELECT 'c3_foundation_relation_contract',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'BLOCKER' END,
    8-count(*),jsonb_build_object('expected',8,'present',count(*))
  FROM (VALUES('backoffice_sales_delivery_discrepancies'),
    ('backoffice_sales_delivery_discrepancy_lines'),('backoffice_sales_discrepancy_operations'),
    ('backoffice_sales_discrepancy_audit'),('backoffice_sales_discrepancy_stock_effects'),
    ('backoffice_sales_discrepancy_fifo_allocations'),('backoffice_sales_discrepancy_backorders'),
    ('backoffice_sales_discrepancy_backorder_lines')) expected(name)
  WHERE to_regclass('public.'||expected.name) IS NOT NULL
  UNION ALL
  SELECT 'c3_required_routine_contract',CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,
    6-count(*),jsonb_build_object('expected',6,'present',count(*))
  FROM (VALUES
    ('private.post_backoffice_sales_discrepancy_transfer(uuid,bigint,uuid,uuid)'),
    ('private.save_stock_transfer_document(uuid,bigint,uuid,uuid,date,text,jsonb)'),
    ('private.post_stock_transfer(uuid,bigint,uuid)'),
    ('private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)'),
    ('private.acp_require_permission_capability(uuid,text,text)'),
    ('private.next_sales_delivery_no(uuid,timestamp with time zone)')) expected(signature)
  WHERE to_regprocedure(expected.signature) IS NOT NULL
  UNION ALL
  SELECT 'c3_pending_line_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.warehouse_resolution_status='PENDING'
    AND line.discrepancy_type IN('OVERAGE','WRONG_ITEM')
    AND ((line.discrepancy_type='OVERAGE' AND line.requested_resolution NOT IN('ACCEPT_OVERAGE','RETURN_OVERAGE'))
      OR (line.discrepancy_type='WRONG_ITEM' AND (line.requested_resolution<>'REPLACE_WRONG_ITEM'
        OR line.actual_product_id IS NULL OR line.actual_quantity_base<=0))
      OR (line.requested_resolution='ACCEPT_OVERAGE'
        AND line.commercial_approval_status NOT IN('PENDING','APPROVED')))
  UNION ALL
  SELECT 'c3_runtime_inventory','INFO',0,
    jsonb_build_object('pendingOverage',count(*) FILTER(WHERE discrepancy_type='OVERAGE'),
      'pendingWrongItem',count(*) FILTER(WHERE discrepancy_type='WRONG_ITEM'),
      'resolvedAcceptedOverage',count(*) FILTER(WHERE requested_resolution='ACCEPT_OVERAGE'
        AND warehouse_resolution_status='RESOLVED'))
  FROM public.backoffice_sales_delivery_discrepancy_lines
  WHERE warehouse_resolution_status IN('PENDING','RESOLVED')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
