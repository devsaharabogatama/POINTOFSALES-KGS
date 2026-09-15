-- SELECT-only verification for Step 4/6.5B.
WITH checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*)) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260912120000'
  UNION ALL
  SELECT 'required_shortage_resolution_routines',CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
    abs(2-count(*)),jsonb_build_object('expected',2,'routineRows',count(*))
  FROM pg_proc WHERE oid IN(
    to_regprocedure('private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)'),
    to_regprocedure('public.resolve_backoffice_sales_shortage(uuid,bigint,uuid,date,text)'))
  UNION ALL
  SELECT 'shortage_resolution_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE grantee='authenticated' AND privilege_type='EXECUTE')=1
      AND count(*) FILTER(WHERE grantee='anon' AND privilege_type='EXECUTE')=0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*) FILTER(WHERE grantee='authenticated' AND privilege_type='EXECUTE')=1
      AND count(*) FILTER(WHERE grantee='anon' AND privilege_type='EXECUTE')=0 THEN 0 ELSE 1 END,
    jsonb_build_object('authenticatedExecute',count(*) FILTER(WHERE grantee='authenticated'),
      'anonExecute',count(*) FILTER(WHERE grantee='anon'))
  FROM information_schema.routine_privileges
  WHERE routine_schema='public' AND routine_name='resolve_backoffice_sales_shortage'
  UNION ALL
  SELECT 'resolved_shortage_effect_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidLines',count(*))
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.discrepancy_type='SHORT' AND line.warehouse_resolution_status='RESOLVED'
    AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_stock_effects effect
      WHERE effect.company_id=line.company_id AND effect.discrepancy_line_id=line.id
        AND effect.effect_type IN('EXPECTED_RETURN_TO_SOURCE','EXPECTED_WRITE_OFF'))
  UNION ALL
  SELECT 'backorder_lineage_reconciliation',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.backoffice_sales_discrepancy_backorder_lines lineage
  JOIN public.backoffice_sales_discrepancy_backorders header
    ON header.company_id=lineage.company_id AND header.id=lineage.backorder_id
  JOIN public.backoffice_sales_delivery_orders delivery
    ON delivery.company_id=header.company_id AND delivery.id=header.backorder_delivery_order_id
  JOIN public.backoffice_sales_delivery_order_lines delivery_line
    ON delivery_line.company_id=lineage.company_id AND delivery_line.id=lineage.backorder_delivery_order_line_id
  WHERE delivery.delivery_kind<>'BACKORDER' OR delivery.parent_delivery_order_id<>header.source_delivery_order_id
    OR delivery_line.delivery_order_id<>delivery.id OR delivery_line.planned_base_qty<>lineage.quantity_base
  UNION ALL
  SELECT 'shortage_resolution_runtime_inventory','INFO',0,
    jsonb_build_object('resolvedShortLines',count(*) FILTER(WHERE line.warehouse_resolution_status='RESOLVED'),
      'pendingShortLines',count(*) FILTER(WHERE line.warehouse_resolution_status='PENDING'),
      'backorders',(SELECT count(*) FROM public.backoffice_sales_discrepancy_backorders))
  FROM public.backoffice_sales_delivery_discrepancy_lines line WHERE line.discrepancy_type='SHORT'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
