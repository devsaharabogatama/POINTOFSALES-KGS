-- Purchase Daily Replenishment Step 4/6: SELECT-only postflight.
WITH required_routines(signature) AS (VALUES
  ('private.get_purchase_daily_automatic_candidates_core(uuid,date)'::text),
  ('private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)'),
  ('public.generate_purchase_daily_auto_po(date,uuid)')
), checks AS (
  SELECT 'pdr4_migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260913130000'
  UNION ALL
  SELECT 'pdr4_routine_contract',CASE WHEN count(to_regprocedure(signature))=3
      THEN 'PASS' ELSE 'FAIL' END,(3-count(to_regprocedure(signature)))::bigint,
    jsonb_build_object('expected',3,'present',count(to_regprocedure(signature)),
      'missing',COALESCE(jsonb_agg(signature)
        FILTER(WHERE to_regprocedure(signature) IS NULL),'[]'::jsonb))
  FROM required_routines
  UNION ALL
  SELECT 'pdr4_operation_constraint_contract',
    CASE WHEN count(*)=1 AND bool_and(position('GENERATE_AUTO_PO' in pg_get_constraintdef(oid))>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(position('GENERATE_AUTO_PO' in pg_get_constraintdef(oid))>0)
      THEN 0 ELSE 1 END::bigint,jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_operations'::regclass
    AND conname='purchase_daily_batch_operations_operation_type_check'
  UNION ALL
  SELECT 'pdr4_line_readiness_constraint_contract',
    CASE WHEN count(*)=1 AND bool_and(position(
        'PURCHASE_UOM_QUANTITY_NOT_EXACT' in pg_get_constraintdef(oid))>0
        AND position('PRODUCT_UOM_SETUP_REQUIRED' in pg_get_constraintdef(oid))>0)
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(position(
        'PURCHASE_UOM_QUANTITY_NOT_EXACT' in pg_get_constraintdef(oid))>0
        AND position('PRODUCT_UOM_SETUP_REQUIRED' in pg_get_constraintdef(oid))>0)
      THEN 0 ELSE 1 END::bigint,jsonb_build_object('constraintRows',count(*))
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_lines'::regclass
    AND conname='purchase_daily_batch_line_readiness_check'
  UNION ALL
  SELECT 'pdr4_preview_call_chain_contract',
    CASE WHEN public_wrapper AND compatibility_wrapper
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN public_wrapper AND compatibility_wrapper
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('publicCompatibilityCall',public_wrapper,
      'automaticResolverActive',compatibility_wrapper)
  FROM (SELECT
    COALESCE(pg_get_functiondef(to_regprocedure(
      'public.get_purchase_daily_replenishment_preview()'))
      LIKE '%private.get_purchase_daily_auto_ro_candidates_core(v_company,v_date)%',false)
      public_wrapper,
    COALESCE(pg_get_functiondef(to_regprocedure(
      'private.get_purchase_daily_auto_ro_candidates_core(uuid,date)'))
      LIKE '%private.get_purchase_daily_automatic_candidates_core%',false)
      compatibility_wrapper) source
  UNION ALL
  SELECT 'pdr4_public_security_contract',
    CASE WHEN count(*)=1 AND bool_and(prosecdef) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(prosecdef) THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineRows',count(*),'securityDefiner',COALESCE(bool_and(prosecdef),false))
  FROM pg_proc WHERE oid=to_regprocedure('public.generate_purchase_daily_auto_po(date,uuid)')
  UNION ALL
  SELECT 'pdr4_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.specific_schema='private' AND privilege.grantee='authenticated'
    AND privilege.routine_name IN('get_purchase_daily_automatic_candidates_core',
      'generate_purchase_daily_auto_po_core')
  UNION ALL
  SELECT 'pdr4_auto_po_batch_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.purchase_daily_batches batch WHERE batch.mode_snapshot='AUTO_PO' AND (
    (batch.status='READY' AND (batch.confirmed_by IS NULL OR batch.confirmed_at IS NULL
      OR batch.confirmation_operation_id IS NULL))
    OR (batch.status='DRAFT' AND NOT EXISTS(SELECT 1 FROM public.purchase_daily_batch_lines line
      WHERE line.company_id=batch.company_id AND line.batch_id=batch.id
        AND line.readiness_status<>'ORDERED')))
  UNION ALL
  SELECT 'pdr4_ready_line_allocation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidLines',count(*))
  FROM (SELECT line.company_id,line.id,line.requested_base_qty,
      COALESCE(sum(allocation.allocated_base_qty),0) allocated
    FROM public.purchase_daily_batch_lines line
    JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
      AND batch.id=line.batch_id AND batch.mode_snapshot='AUTO_PO'
    LEFT JOIN public.purchase_daily_batch_order_allocations allocation
      ON allocation.company_id=line.company_id AND allocation.batch_line_id=line.id
    WHERE line.readiness_status='ORDERED'
    GROUP BY line.company_id,line.id,line.requested_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty),0)<>line.requested_base_qty) invalid
  UNION ALL
  SELECT 'pdr4_blocked_line_zero_allocation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidLines',count(*))
  FROM public.purchase_daily_batch_lines line
  JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
    AND batch.id=line.batch_id AND batch.mode_snapshot='AUTO_PO'
  WHERE line.readiness_status<>'ORDERED' AND EXISTS(
    SELECT 1 FROM public.purchase_daily_batch_order_allocations allocation
    WHERE allocation.company_id=line.company_id AND allocation.batch_line_id=line.id)
  UNION ALL
  SELECT 'pdr4_manual_auto_ro_compatibility',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.purchase_daily_batches batch
  WHERE batch.mode_snapshot='AUTO_RO' AND batch.status='DRAFT'
    AND batch.confirmation_operation_id IS NOT NULL
  UNION ALL
  SELECT 'pdr4_zero_final_effect_contract',
    CASE WHEN receipt_count+movement_count+event_count=0 THEN 'PASS' ELSE 'FAIL' END,
    (receipt_count+movement_count+event_count)::bigint,jsonb_build_object(
      'dailyGoodsReceipts',receipt_count,'dailySourceStockMovements',movement_count,
      'dailySourceFinanceEvents',event_count)
  FROM (SELECT
    (SELECT count(*) FROM public.goods_receipt_documents receipt
      JOIN public.supplier_order_documents document ON document.company_id=receipt.company_id
        AND document.id=receipt.supplier_order_id
      JOIN public.purchase_daily_batches batch ON batch.company_id=document.company_id
        AND batch.id=document.purchase_daily_batch_id AND batch.mode_snapshot='AUTO_PO') receipt_count,
    (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.reference_table IN('purchase_daily_batches',
        'purchase_daily_batch_lines','purchase_daily_batch_order_allocations')) movement_count,
    (SELECT count(*) FROM public.financial_events event
      WHERE event.source_table IN('purchase_daily_batches',
        'purchase_daily_batch_lines','purchase_daily_batch_order_allocations')) event_count) boundary
  UNION ALL
  SELECT 'pdr4_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'readyAutoPo',(SELECT count(*) FROM public.purchase_daily_batches
      WHERE mode_snapshot='AUTO_PO' AND status='READY'),
    'partialHeldAutoPo',(SELECT count(*) FROM public.purchase_daily_batches
      WHERE mode_snapshot='AUTO_PO' AND status='DRAFT'),
    'heldLines',(SELECT count(*) FROM public.purchase_daily_batch_lines line
      JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
        AND batch.id=line.batch_id AND batch.mode_snapshot='AUTO_PO'
      WHERE line.readiness_status<>'ORDERED'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
