-- SELECT-only verification for 20260912110000.
WITH checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912110000'
  UNION ALL
  SELECT 'warehouse_resolution_relation_contract',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*)),jsonb_build_object('expected',4,'present',count(*))
  FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_discrepancy_stock_effects',
    'backoffice_sales_discrepancy_fifo_allocations',
    'backoffice_sales_discrepancy_backorders',
    'backoffice_sales_discrepancy_backorder_lines')
  UNION ALL
  SELECT 'warehouse_resolution_quantity_column',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    abs(1-count(*)),jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='backoffice_sales_order_lines' AND column_name='approved_overage_base_qty'
  UNION ALL
  SELECT 'warehouse_resolution_validator_contract',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*)),jsonb_build_object('expected',2,'present',count(*))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='private' AND p.oid IN(
    to_regprocedure('private.validate_backoffice_sales_discrepancy_stock_effect()'),
    to_regprocedure('private.validate_backoffice_sales_discrepancy_fifo_allocation()'))
  UNION ALL
  SELECT 'accepted_overage_warehouse_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  JOIN public.backoffice_sales_delivery_discrepancies discrepancy
    ON discrepancy.company_id=line.company_id AND discrepancy.id=line.discrepancy_id
  WHERE line.requested_resolution='ACCEPT_OVERAGE'
    AND (line.warehouse_resolution_status NOT IN('PENDING','RESOLVED','REJECTED')
      OR NOT discrepancy.requires_warehouse_resolution)
  UNION ALL
  SELECT 'approved_overage_quantity_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_order_lines
  WHERE approved_overage_base_qty<0 OR CASE
    WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260912137000')
      THEN accepted_base_qty>ordered_base_qty
    ELSE approved_overage_base_qty>accepted_base_qty
      OR accepted_base_qty>ordered_base_qty+approved_overage_base_qty END
  UNION ALL
  SELECT 'stock_effect_fifo_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('mismatchEffects',count(*))
  FROM public.backoffice_sales_discrepancy_stock_effects effect
  LEFT JOIN LATERAL(SELECT COALESCE(sum(allocation.quantity_base),0) quantity,
      COALESCE(sum(allocation.total_cost),0) cost
    FROM public.backoffice_sales_discrepancy_fifo_allocations allocation
    WHERE allocation.company_id=effect.company_id AND allocation.stock_effect_id=effect.id) fifo ON true
  WHERE fifo.quantity<>effect.quantity_base OR fifo.cost<>effect.total_cost
  UNION ALL
  SELECT 'warehouse_resolution_public_runtime_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('publicResolutionRoutines',count(*),'required',0)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='resolve_backoffice_sales_delivery_discrepancy'
  UNION ALL
  SELECT 'warehouse_resolution_runtime_inventory','INFO',0,
    jsonb_build_object('effects',count(*),'backorders',
      (SELECT count(*) FROM public.backoffice_sales_discrepancy_backorders))
  FROM public.backoffice_sales_discrepancy_stock_effects
)
SELECT check_name,status,violation_rows::bigint,details FROM checks ORDER BY check_name;
