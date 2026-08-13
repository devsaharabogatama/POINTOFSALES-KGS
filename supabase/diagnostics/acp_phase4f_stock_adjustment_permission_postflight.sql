-- ACP-4F postflight: guarded Stock Adjustment and trusted Opname boundary.
-- SAFETY: SELECT-only aggregate/catalog metadata.

WITH routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'get_inventory_stock_adjustments','save_stock_adjustment_reason',
    'save_stock_adjustment_document','post_stock_adjustment',
    'cancel_stock_adjustment')
), private_opname AS (
  SELECT procedure.oid,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname='post_stock_opname'
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,
    COALESCE(sum(qty_change) FILTER(WHERE movement_status='POSTED'),0) qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812180000'

  UNION ALL
  SELECT 'stock_adjustment_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',jsonb_agg(enforcement_status))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.stock_adjustments'

  UNION ALL
  SELECT 'remaining_inventory_permission_state',
    CASE WHEN count(*) FILTER(WHERE
      (permission_key IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers','inventory.stock_adjustments')
        AND enforcement_status<>'ENFORCED') OR
      (permission_key NOT IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers','inventory.stock_adjustments')
        AND enforcement_status<>'SHADOW'))=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE
      (permission_key IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers','inventory.stock_adjustments')
        AND enforcement_status<>'ENFORCED') OR
      (permission_key NOT IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers','inventory.stock_adjustments')
        AND enforcement_status<>'SHADOW')),
    jsonb_build_object('inventory_rows',count(*))
  FROM public.access_permission_catalog WHERE permission_key LIKE 'inventory.%'

  UNION ALL
  SELECT 'required_stock_adjustment_routines',
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.stock_adjustments%')=5
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.stock_adjustments%')=5
      THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%inventory.stock_adjustments%'))
  FROM routines

  UNION ALL
  SELECT 'browser_stock_adjustment_rpc_boundary',
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',oid,'EXECUTE'))=5
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=5 AND count(*) FILTER(WHERE has_function_privilege(
      'authenticated',oid,'EXECUTE'))=5
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('authenticated_rows',count(*) FILTER(WHERE
      has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE
      has_function_privilege('anon',oid,'EXECUTE')))
  FROM routines

  UNION ALL
  SELECT 'browser_direct_stock_adjustment_read_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'SELECT'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'SELECT')),
    jsonb_build_object('readable_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'SELECT')),'[]'::JSONB))
  FROM (VALUES('stock_adjustment_reasons'),('stock_adjustment_documents'),
    ('stock_adjustment_lines'),('stock_adjustment_fifo_allocations'),
    ('stock_adjustment_audit')) relation(relation_name)

  UNION ALL
  SELECT 'stock_opname_adjustment_reference_rpc',
    CASE WHEN to_regprocedure(
      'public.get_stock_opname_adjustment_references()') IS NOT NULL
      AND has_function_privilege('authenticated',
        'public.get_stock_opname_adjustment_references()','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_stock_opname_adjustment_references()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
      'public.get_stock_opname_adjustment_references()') IS NOT NULL
      AND has_function_privilege('authenticated',
        'public.get_stock_opname_adjustment_references()','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_stock_opname_adjustment_references()','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('rpc_exists',to_regprocedure(
      'public.get_stock_opname_adjustment_references()') IS NOT NULL)

  UNION ALL
  SELECT 'stock_opname_trusted_adjustment_core',
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      definition ILIKE '%private.save_stock_adjustment_document%'
      AND definition ILIKE '%private.post_stock_adjustment%'
      AND definition NOT ILIKE '%public.save_stock_adjustment_document%'
      AND definition NOT ILIKE '%public.post_stock_adjustment%')=1
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND count(*) FILTER(WHERE
      definition ILIKE '%private.save_stock_adjustment_document%'
      AND definition ILIKE '%private.post_stock_adjustment%'
      AND definition NOT ILIKE '%public.save_stock_adjustment_document%'
      AND definition NOT ILIKE '%public.post_stock_adjustment%')=1
      THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'trusted_rows',count(*) FILTER(
      WHERE definition ILIKE '%private.save_stock_adjustment_document%'
        AND definition ILIKE '%private.post_stock_adjustment%'))
  FROM private_opname

  UNION ALL
  SELECT 'posted_adjustment_movement_coverage',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('line_count',count(*))
  FROM public.stock_adjustment_lines line
  JOIN public.stock_adjustment_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  WHERE document.status='POSTED' AND (SELECT count(*)
    FROM public.stock_movements movement
    WHERE movement.company_id=line.company_id
      AND movement.reference_table='stock_adjustment_documents'
      AND movement.reference_id=line.document_id
      AND movement.source_line_id=line.id
      AND movement.movement_type='ADJUSTMENT'::public.stock_movement_type)<>1

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pair_count',count(*))
  FROM public.product_stocks stock FULL JOIN movement_totals movement
    ON movement.company_id=stock.company_id AND movement.product_id=stock.product_id
   AND movement.warehouse_id=stock.warehouse_id
  WHERE COALESCE(stock.stock_qty,0)<>COALESCE(movement.qty,0)

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pair_count',count(*))
  FROM public.product_stocks stock FULL JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
  WHERE COALESCE(stock.stock_qty,0)<>COALESCE(fifo.qty,0)

  UNION ALL
  SELECT 'stock_adjustment_runtime_inventory','INFO',0,jsonb_build_object(
    'documents',(SELECT count(*) FROM public.stock_adjustment_documents),
    'posted',(SELECT count(*) FROM public.stock_adjustment_documents
      WHERE status='POSTED'),
    'opname_generated',(SELECT count(*) FROM public.stock_opnames
      WHERE adjustment_document_id IS NOT NULL),
    'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.stock_adjustments'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
