-- ACP-4E postflight: guarded Stock Transfer read and mutation boundary.
-- SAFETY: SELECT-only aggregate/catalog metadata.

WITH routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_function_identity_arguments(procedure.oid) arguments,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'get_inventory_stock_transfers','save_stock_transfer_document',
    'post_stock_transfer','cancel_stock_transfer')
), movement_groups AS (
  SELECT company_id,reference_id,product_id,
    count(*) FILTER(WHERE movement_type='TRANSFER_OUT') out_rows,
    count(*) FILTER(WHERE movement_type='TRANSFER_IN') in_rows,
    COALESCE(sum(qty_change) FILTER(WHERE movement_type='TRANSFER_OUT'),0) out_qty,
    COALESCE(sum(qty_change) FILTER(WHERE movement_type='TRANSFER_IN'),0) in_qty
  FROM public.stock_movements
  WHERE reference_table='stock_transfer_documents'
  GROUP BY company_id,reference_id,product_id
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
  FROM private.kgs_schema_migrations WHERE version='20260812170000'

  UNION ALL
  SELECT 'stock_transfer_permission_enforced',
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND bool_and(enforcement_status='ENFORCED')
      THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'statuses',jsonb_agg(enforcement_status))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.stock_transfers'

  UNION ALL
  SELECT 'remaining_inventory_permission_state',
    CASE WHEN count(*) FILTER(WHERE
      (permission_key IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers') AND enforcement_status<>'ENFORCED') OR
      (permission_key NOT IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers') AND enforcement_status<>'SHADOW'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE
      (permission_key IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers') AND enforcement_status<>'ENFORCED') OR
      (permission_key NOT IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements',
        'inventory.stock_transfers') AND enforcement_status<>'SHADOW')),
    jsonb_build_object('inventory_rows',count(*))
  FROM public.access_permission_catalog WHERE permission_key LIKE 'inventory.%'

  UNION ALL
  SELECT 'required_stock_transfer_routines',
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.stock_transfers%')=4
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=4 AND count(*) FILTER(WHERE
      definition ILIKE '%acp_require_permission_capability%'
      AND definition ILIKE '%inventory.stock_transfers%')=4
      THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND definition ILIKE '%inventory.stock_transfers%'))
  FROM routines

  UNION ALL
  SELECT 'browser_stock_transfer_rpc_boundary',
    CASE WHEN count(*)=4
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=4
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=4
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=4
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('authenticated_rows',count(*) FILTER(WHERE
      has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE
      has_function_privilege('anon',oid,'EXECUTE')))
  FROM routines

  UNION ALL
  SELECT 'browser_direct_stock_transfer_read_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'SELECT'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'SELECT')),
    jsonb_build_object('readable_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'SELECT')),'[]'::JSONB))
  FROM (VALUES('stock_transfer_documents'),('stock_transfer_lines'),
    ('stock_transfer_fifo_allocations'),('stock_transfer_audit')) relation(relation_name)

  UNION ALL
  SELECT 'stock_transfer_movement_pair_integrity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('group_count',count(*))
  FROM movement_groups WHERE out_rows<>1 OR in_rows<>1 OR out_qty<>-in_qty

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
  SELECT 'stock_transfer_runtime_inventory','INFO',0,jsonb_build_object(
    'documents',(SELECT count(*) FROM public.stock_transfer_documents),
    'posted',(SELECT count(*) FROM public.stock_transfer_documents
      WHERE status='POSTED'),
    'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key='inventory.stock_transfers'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
