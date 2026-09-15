-- SELECT-only verification after 20260911140000.
WITH checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260911140000'
  UNION ALL
  SELECT 'negative_dispatch_relation_contract',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-2)::bigint,jsonb_build_object('present',count(*),'expected',2)
  FROM information_schema.tables WHERE table_schema='public'
    AND table_name IN('backoffice_negative_stock_allocations',
      'backoffice_negative_stock_replenishments')
  UNION ALL
  SELECT 'negative_dispatch_routine_contract',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-4)::bigint,jsonb_build_object('present',count(*),'expected',4)
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname IN(
    'post_backoffice_sales_stock_transfer','reconcile_negative_stock_replenishment',
    'trg_g4_guard_negative_sale_movement','trg_nsc_goods_receipt_cost_source')
  UNION ALL
  SELECT 'negative_dispatch_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges WHERE grantee IN('anon','authenticated')
    AND specific_schema='private' AND routine_name='post_backoffice_sales_stock_transfer'
  UNION ALL
  SELECT 'negative_dispatch_table_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('browserPrivilegeRows',count(*))
  FROM information_schema.role_table_grants WHERE grantee IN('anon','authenticated')
    AND table_schema='public' AND table_name IN(
      'backoffice_negative_stock_allocations','backoffice_negative_stock_replenishments')
  UNION ALL
  SELECT 'negative_dispatch_call_chain',
    CASE WHEN definition~'post_backoffice_sales_stock_transfer' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'post_backoffice_sales_stock_transfer' THEN 0 ELSE 1 END,
    jsonb_build_object('dedicatedPostCall',definition~'post_backoffice_sales_stock_transfer')
  FROM (SELECT pg_get_functiondef(
    'private.dispatch_backoffice_sales_delivery_to_transit(uuid,bigint,uuid,jsonb,text)'::regprocedure)
    definition) source
  UNION ALL
  SELECT 'ordinary_transfer_nonnegative_contract',
    CASE WHEN definition~'v_source_before < v_line.quantity_base'
      AND definition~'INSUFFICIENT_STOCK' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'v_source_before < v_line.quantity_base'
      AND definition~'INSUFFICIENT_STOCK' THEN 0 ELSE 1 END,
    jsonb_build_object('ordinaryPostStillStrict',definition~'v_source_before < v_line.quantity_base')
  FROM (SELECT pg_get_functiondef(
    'private.post_stock_transfer(uuid,bigint,uuid)'::regprocedure) definition) source
  UNION ALL
  SELECT 'negative_dispatch_allocation_shape',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_negative_stock_allocations allocation
  LEFT JOIN public.product_batches source ON source.company_id=allocation.company_id
    AND source.id=allocation.provisional_source_batch_id
  LEFT JOIN public.product_batches transit ON transit.company_id=allocation.company_id
    AND transit.id=allocation.transit_batch_id
  LEFT JOIN public.stock_transfer_fifo_allocations fifo
    ON fifo.company_id=allocation.company_id AND fifo.line_id=allocation.stock_transfer_line_id
    AND fifo.source_batch_id=allocation.provisional_source_batch_id
    AND fifo.destination_batch_id=allocation.transit_batch_id
  WHERE source.id IS NULL OR transit.id IS NULL OR fifo.id IS NULL
    OR source.backoffice_negative_allocation_id<>allocation.id
    OR source.qty_remaining<>0 OR source.warehouse_id<>allocation.source_warehouse_id
    OR transit.warehouse_id<>allocation.transit_warehouse_id
    OR fifo.quantity_base<>allocation.shortage_base_qty
  UNION ALL
  SELECT 'negative_dispatch_replenishment_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('invalidRows',count(*))
  FROM (SELECT allocation.id,allocation.replenished_base_qty,
      allocation.actual_cost_total,allocation.inventory_revaluation_total,
      allocation.cogs_variance_total,COALESCE(sum(replenishment.replenished_base_qty),0) qty,
      COALESCE(sum(round(replenishment.replenished_base_qty*replenishment.actual_unit_cost,4)),0) actual,
      COALESCE(sum(replenishment.inventory_revaluation),0) inventory_variance,
      COALESCE(sum(replenishment.cogs_variance),0) cogs_variance
    FROM public.backoffice_negative_stock_allocations allocation
    LEFT JOIN public.backoffice_negative_stock_replenishments replenishment
      ON replenishment.company_id=allocation.company_id
     AND replenishment.negative_allocation_id=allocation.id
    GROUP BY allocation.id) state
  WHERE state.replenished_base_qty<>state.qty OR state.actual_cost_total<>state.actual
    OR state.inventory_revaluation_total<>state.inventory_variance
    OR state.cogs_variance_total<>state.cogs_variance
), inventory AS (
  SELECT 'negative_dispatch_runtime_inventory'::text check_name,'INFO'::text status,
    0::bigint violation_rows,jsonb_build_object(
      'openAllocations',(SELECT count(*) FROM public.backoffice_negative_stock_allocations
        WHERE reconciled_at IS NULL),
      'reconciledAllocations',(SELECT count(*) FROM public.backoffice_negative_stock_allocations
        WHERE reconciled_at IS NOT NULL),
      'replenishmentRows',(SELECT count(*) FROM public.backoffice_negative_stock_replenishments)) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

