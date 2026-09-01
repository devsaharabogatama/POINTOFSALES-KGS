-- ODR Purchasing demand composed-read alias forward-fix postflight.
-- SAFETY: SELECT-only.
WITH routine AS (
  SELECT procedure.oid,procedure.prosecdef,procedure.provolatile,
    procedure.proconfig,pg_get_functiondef(procedure.oid) definition
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='get_purchase_procurement_demands'
    AND pg_get_function_identity_arguments(procedure.oid)=''
),checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260831100000'

  UNION ALL
  SELECT 'purchasing_demand_read_runtime_definition',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*))
  FROM routine
  WHERE definition ~
      'ORDER BY[[:space:]]+row_data\.demand_id[[:space:]]*,[[:space:]]*row_data\.product_name[[:space:]]*,[[:space:]]*row_data\.id'
    AND definition !~
      'ORDER BY[[:space:]]+row_data\.demand_id[[:space:]]*,[[:space:]]*product\.name[[:space:]]*,[[:space:]]*row_data\.id'

  UNION ALL
  SELECT 'purchasing_demand_read_security_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',COALESCE(bool_or(prosecdef),FALSE),
      'volatility',max(provolatile::TEXT),
      'config',COALESCE(jsonb_agg(proconfig),'[]'::JSONB))
  FROM routine
  HAVING bool_and(prosecdef) AND bool_and(provolatile='s')
    AND bool_and(proconfig @> ARRAY['search_path=public, pg_temp']::TEXT[])

  UNION ALL
  SELECT 'purchasing_demand_read_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_purchase_procurement_demands()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_purchase_procurement_demands()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon',
        'public.get_purchase_procurement_demands()','EXECUTE')
      AND has_function_privilege('authenticated',
        'public.get_purchase_procurement_demands()','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object(
      'anonExecute',has_function_privilege('anon',
        'public.get_purchase_procurement_demands()','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated',
        'public.get_purchase_procurement_demands()','EXECUTE'))

  UNION ALL
  SELECT 'purchasing_demand_data_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
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
  SELECT 'purchasing_demand_read_inventory','INFO',0,
    jsonb_build_object(
      'companies',(SELECT count(DISTINCT company_id)
        FROM public.sales_order_procurement_demands),
      'demands',(SELECT count(*) FROM public.sales_order_procurement_demands),
      'lines',(SELECT count(*)
        FROM public.sales_order_procurement_demand_lines),
      'openAmendments',(SELECT count(*)
        FROM public.sales_order_procurement_amendments WHERE status='OPEN'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
