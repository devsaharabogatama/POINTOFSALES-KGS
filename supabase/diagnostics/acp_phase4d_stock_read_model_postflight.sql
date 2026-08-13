-- ACP-4D postflight: Stock Real and Stock Movement guarded read models.
-- SAFETY: SELECT-only aggregate/catalog metadata.

WITH read_routines AS (
  SELECT procedure.oid,procedure.proname,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname IN(
    'get_inventory_stock_overview','get_inventory_stock_movements'
  )
), movement_totals AS (
  SELECT company_id,product_id,warehouse_id,
    COALESCE(sum(qty_change) FILTER(WHERE movement_status='POSTED'),0) movement_qty
  FROM public.stock_movements GROUP BY company_id,product_id,warehouse_id
), stock_reconciliation AS (
  SELECT COALESCE(stock.company_id,movement.company_id) company_id,
    COALESCE(stock.product_id,movement.product_id) product_id,
    COALESCE(stock.warehouse_id,movement.warehouse_id) warehouse_id,
    COALESCE(stock.stock_qty,0) stock_qty,
    COALESCE(movement.movement_qty,0) movement_qty
  FROM public.product_stocks stock FULL JOIN movement_totals movement
    ON movement.company_id=stock.company_id
   AND movement.product_id=stock.product_id
   AND movement.warehouse_id=stock.warehouse_id
), fifo_totals AS (
  SELECT company_id,product_id,warehouse_id,COALESCE(sum(qty_remaining),0) fifo_qty
  FROM public.product_batches GROUP BY company_id,product_id,warehouse_id
), fifo_reconciliation AS (
  SELECT COALESCE(stock.company_id,fifo.company_id) company_id,
    COALESCE(stock.product_id,fifo.product_id) product_id,
    COALESCE(stock.warehouse_id,fifo.warehouse_id) warehouse_id,
    COALESCE(stock.stock_qty,0) stock_qty,COALESCE(fifo.fifo_qty,0) fifo_qty
  FROM public.product_stocks stock FULL JOIN fifo_totals fifo
    ON fifo.company_id=stock.company_id
   AND fifo.product_id=stock.product_id
   AND fifo.warehouse_id=stock.warehouse_id
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledger_rows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260812160000'

  UNION ALL
  SELECT 'stock_read_permissions_enforced',
    CASE WHEN count(*)=2 AND count(*) FILTER(
      WHERE enforcement_status='ENFORCED')=2 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 AND count(*) FILTER(
      WHERE enforcement_status='ENFORCED')=2 THEN 0 ELSE 1 END,
    jsonb_build_object('rows',count(*),'enforced_rows',count(*) FILTER(
      WHERE enforcement_status='ENFORCED'))
  FROM public.access_permission_catalog
  WHERE permission_key IN('inventory.stock_real','inventory.stock_movements')

  UNION ALL
  SELECT 'remaining_inventory_permission_state',
    CASE WHEN count(*) FILTER(WHERE permission_key IN(
      'inventory.master_data','inventory.products','inventory.stock_real',
      'inventory.stock_movements') AND enforcement_status<>'ENFORCED')=0
      AND count(*) FILTER(WHERE permission_key NOT IN(
      'inventory.master_data','inventory.products','inventory.stock_real',
      'inventory.stock_movements') AND enforcement_status<>'SHADOW')=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE
      (permission_key IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements')
        AND enforcement_status<>'ENFORCED') OR
      (permission_key NOT IN('inventory.master_data','inventory.products',
        'inventory.stock_real','inventory.stock_movements')
        AND enforcement_status<>'SHADOW')),
    jsonb_build_object('inventory_rows',count(*))
  FROM public.access_permission_catalog WHERE permission_key LIKE 'inventory.%'

  UNION ALL
  SELECT 'required_stock_read_routines',
    CASE WHEN count(*)=2 AND count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND (definition ILIKE '%inventory.stock_real%'
          OR definition ILIKE '%inventory.stock_movements%')
        AND definition ILIKE '%VIEW%')=2 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2 AND count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND (definition ILIKE '%inventory.stock_real%'
          OR definition ILIKE '%inventory.stock_movements%')
        AND definition ILIKE '%VIEW%')=2 THEN 0 ELSE 1 END,
    jsonb_build_object('routine_rows',count(*),'hooked_rows',count(*) FILTER(
      WHERE definition ILIKE '%acp_require_permission_capability%'
        AND (definition ILIKE '%inventory.stock_real%'
          OR definition ILIKE '%inventory.stock_movements%')
        AND definition ILIKE '%VIEW%'))
  FROM read_routines

  UNION ALL
  SELECT 'browser_stock_read_rpc_boundary',
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=2
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=2
      AND count(*) FILTER(WHERE has_function_privilege(
        'authenticated',oid,'EXECUTE'))=2
      AND count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE'))=0
      THEN 0 ELSE 1 END,
    jsonb_build_object('authenticated_rows',count(*) FILTER(
      WHERE has_function_privilege('authenticated',oid,'EXECUTE')),
      'anon_rows',count(*) FILTER(WHERE has_function_privilege('anon',oid,'EXECUTE')))
  FROM read_routines

  UNION ALL
  SELECT 'stock_operational_reference_compatibility',
    CASE WHEN count(*) FILTER(WHERE NOT has_table_privilege(
      'authenticated',format('public.%I',relation_name),'SELECT'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE NOT has_table_privilege(
      'authenticated',format('public.%I',relation_name),'SELECT')),
    jsonb_build_object('readable_relations',count(*) FILTER(
      WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'SELECT')))
  FROM (VALUES('product_stocks'),('product_batches'),('stock_movements'))
    relation(relation_name)

  UNION ALL
  SELECT 'stock_read_direct_write_boundary',
    CASE WHEN count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE'))=0
      THEN 'PASS' ELSE 'FAIL' END,
    count(*) FILTER(WHERE has_table_privilege(
      'authenticated',format('public.%I',relation_name),'INSERT,UPDATE,DELETE')),
    jsonb_build_object('direct_write_relations',COALESCE(jsonb_agg(relation_name)
      FILTER(WHERE has_table_privilege('authenticated',
        format('public.%I',relation_name),'INSERT,UPDATE,DELETE')),'[]'::JSONB))
  FROM (VALUES('product_stocks'),('product_batches'),('stock_movements'))
    relation(relation_name)

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pair_count',count(*))
  FROM stock_reconciliation WHERE stock_qty<>movement_qty

  UNION ALL
  SELECT 'stock_balance_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pair_count',count(*))
  FROM fifo_reconciliation WHERE stock_qty<>fifo_qty

  UNION ALL
  SELECT 'stock_read_runtime_inventory','INFO',0,jsonb_build_object(
    'balance_rows',(SELECT count(*) FROM public.product_stocks),
    'positive_fifo_layers',(SELECT count(*) FROM public.product_batches
      WHERE qty_remaining>0),
    'posted_movements',(SELECT count(*) FROM public.stock_movements
      WHERE movement_status='POSTED'),
    'override_rows',(SELECT count(*) FROM public.user_company_permission_overrides
      WHERE permission_key IN('inventory.stock_real','inventory.stock_movements')))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
