-- Purchase Daily Replenishment Step 3/6: SELECT-only postflight.
WITH required_relations(name) AS (VALUES
  ('purchase_daily_batch_operations'::text),('purchase_daily_batch_audit'),
  ('purchase_daily_batch_order_allocations')
), required_columns(table_name,column_name) AS (VALUES
  ('purchase_daily_batches'::text,'generation_operation_id'::text),
  ('purchase_daily_batches','confirmed_by'),('purchase_daily_batches','confirmed_at'),
  ('purchase_daily_batches','confirmation_operation_id'),
  ('purchase_daily_batch_lines','readiness_status'),
  ('purchase_daily_batch_lines','master_version'),
  ('supplier_order_documents','order_source'),
  ('supplier_order_documents','document_scope'),
  ('supplier_order_documents','purchase_daily_batch_id'),
  ('supplier_order_documents','supplier_assignment_status')
), required_routines(signature) AS (VALUES
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
), checks AS (
  SELECT 'pdr3_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260913120000'
  UNION ALL
  SELECT 'pdr3_relation_contract',CASE WHEN count(to_regclass('public.'||name))=3
      THEN 'PASS' ELSE 'FAIL' END,(3-count(to_regclass('public.'||name)))::bigint,
    jsonb_build_object('expected',3,'present',count(to_regclass('public.'||name)),
      'missing',COALESCE(jsonb_agg(name)
        FILTER(WHERE to_regclass('public.'||name) IS NULL),'[]'::jsonb))
  FROM required_relations
  UNION ALL
  SELECT 'pdr3_column_contract',CASE WHEN count(actual.column_name)=10 THEN 'PASS' ELSE 'FAIL' END,
    (10-count(actual.column_name))::bigint,jsonb_build_object('expected',10,
      'present',count(actual.column_name),'missing',COALESCE(jsonb_agg(
        required.table_name||'.'||required.column_name)
        FILTER(WHERE actual.column_name IS NULL),'[]'::jsonb))
  FROM required_columns required LEFT JOIN information_schema.columns actual
    ON actual.table_schema='public' AND actual.table_name=required.table_name
   AND actual.column_name=required.column_name
  UNION ALL
  SELECT 'pdr3_routine_contract',CASE WHEN count(to_regprocedure(signature))=10
      THEN 'PASS' ELSE 'FAIL' END,(10-count(to_regprocedure(signature)))::bigint,
    jsonb_build_object('expected',10,'present',count(to_regprocedure(signature)),
      'missing',COALESCE(jsonb_agg(signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::jsonb))
  FROM required_routines
  UNION ALL
  SELECT 'pdr3_preview_call_chain_contract',
    CASE WHEN count(*)=1 AND bool_and(pg_get_functiondef(routine.oid)
        LIKE '%private.get_purchase_daily_auto_ro_candidates_core(v_company,v_date)%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(pg_get_functiondef(routine.oid)
        LIKE '%private.get_purchase_daily_auto_ro_candidates_core(v_company,v_date)%')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'step3ResolverActive',COALESCE(bool_and(
      pg_get_functiondef(routine.oid)
        LIKE '%private.get_purchase_daily_auto_ro_candidates_core(v_company,v_date)%'),false))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public'
    AND routine.oid=to_regprocedure('public.get_purchase_daily_replenishment_preview()')
  UNION ALL
  SELECT 'pdr3_public_security_contract',
    CASE WHEN count(*)=3 AND bool_and(routine.prosecdef) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=3 AND bool_and(routine.prosecdef) THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('expected',3,'present',count(*),
      'allSecurityDefiner',COALESCE(bool_and(routine.prosecdef),false))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname IN(
    'generate_purchase_daily_auto_ro','confirm_purchase_daily_auto_ro',
    'get_purchase_daily_auto_ro_workspace')
  UNION ALL
  SELECT 'pdr3_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.routine_name IN('purchase_daily_batch_snapshot',
      'get_purchase_daily_auto_ro_candidates_core','generate_purchase_daily_auto_ro_core',
      'confirm_purchase_daily_auto_ro_core')
  UNION ALL
  SELECT 'pdr3_immutable_trigger_contract',CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
    (5-count(*))::bigint,jsonb_build_object('expected',5,'present',count(*))
  FROM pg_trigger trigger_row WHERE NOT trigger_row.tgisinternal AND trigger_row.tgname IN(
    'guard_purchase_daily_batch_history','guard_purchase_daily_batch_line_history',
    'guard_purchase_daily_operation_history','guard_purchase_daily_audit_history',
    'guard_purchase_daily_order_allocation_history')
  UNION ALL
  SELECT 'pdr3_manual_supplier_order_compatibility',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*),
      'rule','Existing/manual PO remains Store-scoped with one header Supplier and destination')
  FROM public.supplier_order_documents document
  WHERE document.order_source='MANUAL' AND (document.document_scope<>'STORE'
    OR document.store_id IS NULL OR document.destination_warehouse_id IS NULL
    OR document.supplier_id IS NULL OR document.purchase_daily_batch_id IS NOT NULL
    OR document.supplier_assignment_status<>'ASSIGNED')
  UNION ALL
  SELECT 'pdr3_daily_supplier_order_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.supplier_order_documents document
  WHERE document.order_source='DAILY_REPLENISHMENT' AND (
    document.document_scope<>'COMPANY_MULTI_WAREHOUSE' OR document.store_id IS NOT NULL
    OR document.destination_warehouse_id IS NOT NULL OR document.purchase_daily_batch_id IS NULL
      OR (document.supplier_id IS NULL)<>(document.supplier_assignment_status='SUPPLIER_PENDING'))
  UNION ALL
  SELECT 'pdr3_operation_audit_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidOperations',count(*))
  FROM public.purchase_daily_batch_operations operation
  LEFT JOIN public.purchase_daily_batch_audit audit
    ON audit.company_id=operation.company_id AND audit.operation_id=operation.id
  WHERE operation.batch_id IS NOT NULL AND audit.id IS NULL
  UNION ALL
  SELECT 'pdr3_batch_order_quantity_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidLines',count(*))
  FROM (SELECT line.company_id,line.id,line.requested_base_qty,
      COALESCE(sum(allocation.allocated_base_qty),0) allocated
    FROM public.purchase_daily_batch_lines line
    JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
      AND batch.id=line.batch_id AND batch.status<>'DRAFT'
    LEFT JOIN public.purchase_daily_batch_order_allocations allocation
      ON allocation.company_id=line.company_id AND allocation.batch_line_id=line.id
    GROUP BY line.company_id,line.id,line.requested_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)<>line.requested_base_qty) invalid
  UNION ALL
  SELECT 'pdr3_zero_final_effect_contract',
    CASE WHEN receipt_count+movement_count+event_count=0 THEN 'PASS' ELSE 'FAIL' END,
    (receipt_count+movement_count+event_count)::bigint,jsonb_build_object(
    'rule','Step 3 creates only RO/PO and lineage; Goods Receipt, Stock Movement, FIFO, AP and Finance remain closed',
    'dailyGoodsReceipts',receipt_count,'dailySourceStockMovements',movement_count,
    'dailySourceFinanceEvents',event_count)
  FROM (SELECT
    (SELECT count(*) FROM public.goods_receipt_documents receipt
      JOIN public.supplier_order_documents document ON document.company_id=receipt.company_id
        AND document.id=receipt.supplier_order_id
      WHERE document.order_source='DAILY_REPLENISHMENT') receipt_count,
    (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.reference_table IN('purchase_daily_batches',
        'purchase_daily_batch_lines','purchase_daily_batch_order_allocations')) movement_count,
    (SELECT count(*) FROM public.financial_events event
      WHERE event.source_table IN('purchase_daily_batches',
        'purchase_daily_batch_lines','purchase_daily_batch_order_allocations')) event_count) boundary
  UNION ALL
  SELECT 'pdr3_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'draftAutoRo',(SELECT count(*) FROM public.purchase_daily_batches
      WHERE mode_snapshot='AUTO_RO' AND status='DRAFT'),
    'confirmedAutoRo',(SELECT count(*) FROM public.purchase_daily_batches
      WHERE mode_snapshot='AUTO_RO' AND status<>'DRAFT'),
    'dailySupplierOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE order_source='DAILY_REPLENISHMENT'),
    'supplierPendingOrders',(SELECT count(*) FROM public.supplier_order_documents
      WHERE order_source='DAILY_REPLENISHMENT' AND supplier_assignment_status='SUPPLIER_PENDING'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
