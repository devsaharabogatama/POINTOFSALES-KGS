-- Purchase Daily Replenishment Step 3/6: SELECT-only preflight.
-- Run the complete file on isolated Development only.
WITH required_versions(version) AS (VALUES
  ('20260806010000'::text),('20260806040000'),('20260813000000'),
  ('20260825131000'),('20260913100000'),('20260913110000')
), new_relations(name) AS (VALUES
  ('purchase_daily_batch_operations'::text),('purchase_daily_batch_audit'),
  ('purchase_daily_batch_order_allocations')
), new_columns(table_name,column_name) AS (VALUES
  ('purchase_daily_batches'::text,'generation_operation_id'::text),
  ('purchase_daily_batches','confirmed_by'),('purchase_daily_batches','confirmed_at'),
  ('purchase_daily_batches','confirmation_operation_id'),
  ('purchase_daily_batch_lines','readiness_status'),
  ('purchase_daily_batch_lines','master_version'),
  ('supplier_order_documents','order_source'),
  ('supplier_order_documents','document_scope'),
  ('supplier_order_documents','purchase_daily_batch_id'),
  ('supplier_order_documents','supplier_assignment_status')
), new_routines(signature) AS (VALUES
  ('private.trg_guard_purchase_daily_runtime_history()'::text),
  ('private.trg_guard_purchase_daily_batch()'),
  ('private.trg_guard_purchase_daily_batch_line()'),
  ('private.purchase_daily_batch_snapshot(uuid,uuid)'),
  ('private.get_purchase_daily_auto_ro_candidates_core(uuid,date)'),
  ('private.generate_purchase_daily_auto_ro_core(uuid,date,uuid,uuid,timestamptz)'),
  ('private.confirm_purchase_daily_auto_ro_core(uuid,uuid,bigint,uuid,uuid,jsonb,timestamptz)'),
  ('public.generate_purchase_daily_auto_ro(date,uuid)'),
  ('public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb)'),
  ('public.get_purchase_daily_auto_ro_workspace()')
), runtime_dependencies(kind,name) AS (VALUES
  ('routine'::text,'private.purchase_uncovered_negative_qty(numeric,numeric)'::text),
  ('routine','private.get_purchase_daily_replenishment_candidates_core(uuid,date)'),
  ('routine','public.private_active_company_id()'),
  ('routine','private.acp_require_permission_capability(uuid,text,text)'),
  ('relation','private.supplier_order_document_no_seq')
), checks AS (
  SELECT 'pdr3_dependency_ledger'::text check_name,
    CASE WHEN count(ledger.version)=6 THEN 'PASS' ELSE 'BLOCKER' END status,
    (6-count(ledger.version))::bigint violation_rows,
    jsonb_build_object('expected',6,'present',count(ledger.version),
      'missing',COALESCE(jsonb_agg(required.version)
        FILTER(WHERE ledger.version IS NULL),'[]'::jsonb)) details
  FROM required_versions required LEFT JOIN private.kgs_schema_migrations ledger USING(version)
  UNION ALL
  SELECT 'pdr3_runtime_dependency_contract',
    CASE WHEN count(*) FILTER(WHERE CASE WHEN kind='routine'
        THEN to_regprocedure(name) IS NOT NULL ELSE to_regclass(name) IS NOT NULL END)=5
      THEN 'PASS' ELSE 'BLOCKER' END,
    (5-count(*) FILTER(WHERE CASE WHEN kind='routine'
      THEN to_regprocedure(name) IS NOT NULL ELSE to_regclass(name) IS NOT NULL END))::bigint,
    jsonb_build_object('expected',5,'present',count(*) FILTER(WHERE CASE WHEN kind='routine'
      THEN to_regprocedure(name) IS NOT NULL ELSE to_regclass(name) IS NOT NULL END),
      'missing',COALESCE(jsonb_agg(name) FILTER(WHERE CASE WHEN kind='routine'
        THEN to_regprocedure(name) IS NULL ELSE to_regclass(name) IS NULL END),'[]'::jsonb))
  FROM runtime_dependencies
  UNION ALL
  SELECT 'pdr3_relation_collision',CASE WHEN count(actual.oid)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(actual.oid)::bigint,jsonb_build_object('existing',COALESCE(jsonb_agg(required.name)
      FILTER(WHERE actual.oid IS NOT NULL),'[]'::jsonb))
  FROM new_relations required LEFT JOIN pg_class actual
    ON actual.oid=to_regclass('public.'||required.name)
  UNION ALL
  SELECT 'pdr3_column_collision',CASE WHEN count(actual.column_name)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(actual.column_name)::bigint,jsonb_build_object('existing',COALESCE(jsonb_agg(
      required.table_name||'.'||required.column_name)
      FILTER(WHERE actual.column_name IS NOT NULL),'[]'::jsonb))
  FROM new_columns required LEFT JOIN information_schema.columns actual
    ON actual.table_schema='public' AND actual.table_name=required.table_name
   AND actual.column_name=required.column_name
  UNION ALL
  SELECT 'pdr3_routine_collision',CASE WHEN count(to_regprocedure(signature))=0
      THEN 'PASS' ELSE 'BLOCKER' END,count(to_regprocedure(signature))::bigint,
    jsonb_build_object('existing',COALESCE(jsonb_agg(signature)
      FILTER(WHERE to_regprocedure(signature) IS NOT NULL),'[]'::jsonb))
  FROM new_routines
  UNION ALL
  SELECT 'pdr3_inert_batch_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('existingBatchRows',count(*),
      'rule','Step 2 had no generator; rows must be absent before Step 3 runtime')
  FROM public.purchase_daily_batches
  UNION ALL
  SELECT 'pdr3_supplier_order_header_contract',
    CASE WHEN count(*)=3 AND bool_and(is_nullable='NO') THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN count(*)=3 AND bool_and(is_nullable='NO') THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('expectedNotNull',jsonb_build_array('store_id',
      'destination_warehouse_id','supplier_id'),'present',count(*),
      'allNotNull',COALESCE(bool_and(is_nullable='NO'),false))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='supplier_order_documents'
    AND column_name IN('store_id','destination_warehouse_id','supplier_id')
  UNION ALL
  SELECT 'pdr3_existing_supplier_order_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.supplier_order_documents document
  WHERE document.store_id IS NULL OR document.destination_warehouse_id IS NULL
    OR document.supplier_id IS NULL
  UNION ALL
  SELECT 'pdr3_active_finance_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('runRows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'pdr3_nonterminal_offline',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('submissionRows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'pdr3_open_cutover_plan',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    count(*)::bigint,jsonb_build_object('openPlans',count(*))
  FROM public.sales_process_cutover_plans WHERE status IN('DRAFT','PREVIEWED','APPLYING')
  UNION ALL
  SELECT 'pdr3_candidate_inventory','INFO',0::bigint,jsonb_build_object(
    'companiesByMode',COALESCE((SELECT jsonb_object_agg(mode,row_count) FROM (
      SELECT replenishment_mode mode,count(*) row_count
      FROM public.company_purchase_replenishment_settings GROUP BY replenishment_mode) grouped),'{}'::jsonb),
    'negativeOnHandRows',(SELECT count(*) FROM public.product_stocks WHERE stock_qty<0),
    'supplierPendingCandidates',(SELECT count(*) FROM public.product_stocks stock
      WHERE stock.stock_qty<0 AND NOT EXISTS(SELECT 1 FROM public.product_suppliers relation
        JOIN public.suppliers supplier ON supplier.company_id=relation.company_id
          AND supplier.id=relation.supplier_id AND supplier.is_active
        WHERE relation.company_id=stock.company_id AND relation.product_id=stock.product_id
          AND relation.is_active)),
    'requiredProjectRef','fkywtxucmyjvpwdiqpix')
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
