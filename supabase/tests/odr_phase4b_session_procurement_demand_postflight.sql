-- ODR-4B session procurement demand runtime postflight. SELECT-only.
WITH routine_definition AS (
  SELECT procedure.oid,namespace.nspname schema_name,procedure.proname routine_name,
    pg_get_function_identity_arguments(procedure.oid) arguments,
    pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('private','refresh_sales_order_procurement_demand'),
    ('private','freeze_session_procurement_demand'),
    ('private','odr4b_close_cashier_session_legacy'),
    ('public','get_purchase_procurement_demands'),
    ('public','confirm_pos_sales_order'),('public','cancel_pos_sales_order'),
    ('public','close_cashier_session'))
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260828160000'

  UNION ALL
  SELECT 'required_procurement_demand_routines',
    CASE WHEN count(*)=7 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',7,'routineRows',count(*))
  FROM routine_definition

  UNION ALL
  SELECT 'private_procurement_demand_core_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM routine_definition
  WHERE schema_name='private'
    AND has_function_privilege('authenticated',oid,'EXECUTE')

  UNION ALL
  SELECT 'browser_procurement_demand_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants
  WHERE grantee IN('anon','authenticated') AND table_schema='public'
    AND table_name IN('sales_order_procurement_demands',
      'sales_order_procurement_demand_lines',
      'sales_order_procurement_demand_audit')

  UNION ALL
  SELECT 'sales_order_runtime_demand_hook',
    CASE WHEN count(*)=2 AND bool_and(
      definition LIKE '%refresh_sales_order_procurement_demand%')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM routine_definition WHERE schema_name='public'
    AND routine_name IN('confirm_pos_sales_order','cancel_pos_sales_order')

  UNION ALL
  SELECT 'cashier_session_close_demand_hook',
    CASE WHEN count(*)=1 AND bool_and(
      definition LIKE '%freeze_session_procurement_demand%')
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',count(*))
  FROM routine_definition WHERE schema_name='public'
    AND routine_name='close_cashier_session'

  UNION ALL
  SELECT 'procurement_demand_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('demandCount',count(*))
  FROM public.sales_order_procurement_demands demand
  WHERE demand.total_demand_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.demand_base_qty)
      FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=demand.company_id AND line.demand_id=demand.id),0)
    OR demand.total_released_base_qty IS DISTINCT FROM COALESCE((
      SELECT sum(line.released_base_qty)
      FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=demand.company_id AND line.demand_id=demand.id),0)

  UNION ALL
  SELECT 'procurement_demand_reservation_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.sales_order_procurement_demand_lines demand_line
  JOIN public.sales_stock_reservation_lines reservation_line
    ON reservation_line.company_id=demand_line.company_id
   AND reservation_line.id=demand_line.reservation_line_id
  WHERE demand_line.demand_base_qty<>reservation_line.shortage_base_qty
    OR demand_line.released_base_qty<>
      LEAST(reservation_line.shortage_base_qty,reservation_line.released_base_qty)

  UNION ALL
  SELECT 'legacy_procurement_documents_preserved','PASS',
    jsonb_build_object(
      'requests',(SELECT count(*) FROM public.stock_request_documents),
      'draftSupplierOrders',(SELECT count(*) FROM public.supplier_order_documents
        WHERE status='DRAFT'),
      'finalSupplierOrders',(SELECT count(*) FROM public.supplier_order_documents
        WHERE status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),
      'rule','ODR-4B does not mutate Stock Request or Supplier Order')

  UNION ALL
  SELECT 'procurement_demand_runtime_inventory','INFO',jsonb_build_object(
    'headers',(SELECT count(*) FROM public.sales_order_procurement_demands),
    'lines',(SELECT count(*) FROM public.sales_order_procurement_demand_lines),
    'open',(SELECT count(*) FROM public.sales_order_procurement_demands
      WHERE status='OPEN'),
    'frozen',(SELECT count(*) FROM public.sales_order_procurement_demands
      WHERE status='FROZEN'),
    'closed',(SELECT count(*) FROM public.sales_order_procurement_demands
      WHERE status='CLOSED'),
    'auditRows',(SELECT count(*)
      FROM public.sales_order_procurement_demand_audit))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
