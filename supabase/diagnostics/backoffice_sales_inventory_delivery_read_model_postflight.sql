-- Read-only postflight for migration 20260909149000.
WITH definition AS (
  SELECT pg_get_functiondef(
    'public.get_inventory_backoffice_delivery_orders(date,date)'::regprocedure) body
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909149000'
  UNION ALL
  SELECT 'backoffice_delivery_read_routine',
    CASE WHEN to_regprocedure(
      'public.get_inventory_backoffice_delivery_orders(date,date)') IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN to_regprocedure(
      'public.get_inventory_backoffice_delivery_orders(date,date)') IS NOT NULL
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('routineExists',to_regprocedure(
      'public.get_inventory_backoffice_delivery_orders(date,date)') IS NOT NULL)
  UNION ALL
  SELECT 'backoffice_delivery_read_definition_contract',
    CASE WHEN body LIKE '%inventory.delivery_documents%'
      AND body LIKE '%backoffice_sales_delivery_orders%'
      AND body LIKE '%backoffice_sales_delivery_order_lines%'
      AND body LIKE '%operationsReady%false%'
      AND upper(body)!~'\m(INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\M'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN body LIKE '%inventory.delivery_documents%'
      AND body LIKE '%backoffice_sales_delivery_orders%'
      AND body LIKE '%backoffice_sales_delivery_order_lines%'
      AND body LIKE '%operationsReady%false%'
      AND upper(body)!~'\m(INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\M'
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('permissionGuard',body LIKE '%inventory.delivery_documents%',
      'deliverySource',body LIKE '%backoffice_sales_delivery_orders%',
      'lineSource',body LIKE '%backoffice_sales_delivery_order_lines%',
      'operationsClosed',body LIKE '%operationsReady%false%',
      'readOnly',upper(body)!~'\m(INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\M')
  FROM definition
  UNION ALL
  SELECT 'backoffice_delivery_read_rpc_boundary',
    CASE WHEN has_function_privilege('authenticated',
        'public.get_inventory_backoffice_delivery_orders(date,date)','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_inventory_backoffice_delivery_orders(date,date)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
        'public.get_inventory_backoffice_delivery_orders(date,date)','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_inventory_backoffice_delivery_orders(date,date)','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('authenticatedExecute',has_function_privilege('authenticated',
      'public.get_inventory_backoffice_delivery_orders(date,date)','EXECUTE'),
      'anonExecute',has_function_privilege('anon',
      'public.get_inventory_backoffice_delivery_orders(date,date)','EXECUTE'))
  UNION ALL
  SELECT 'backoffice_delivery_read_security_contract',
    CASE WHEN routine.prosecdef AND routine.provolatile='s'
      AND routine.proconfig @> ARRAY['search_path=public, pg_temp']
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN routine.prosecdef AND routine.provolatile='s'
      AND routine.proconfig @> ARRAY['search_path=public, pg_temp']
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('securityDefiner',routine.prosecdef,
      'volatility',routine.provolatile,'config',routine.proconfig)
  FROM pg_proc routine WHERE routine.oid=
    'public.get_inventory_backoffice_delivery_orders(date,date)'::regprocedure
  UNION ALL
  SELECT 'backoffice_delivery_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('deliveryCount',count(*))
  FROM (SELECT delivery.id
    FROM public.backoffice_sales_delivery_orders delivery
    LEFT JOIN public.backoffice_sales_delivery_order_lines line
      ON line.company_id=delivery.company_id AND line.delivery_order_id=delivery.id
    GROUP BY delivery.id,delivery.total_planned_base_qty,
      delivery.total_shipped_base_qty,delivery.total_received_base_qty
    HAVING round(COALESCE(sum(line.planned_base_qty),0),6)<>
        round(delivery.total_planned_base_qty,6)
      OR round(COALESCE(sum(line.shipped_base_qty),0),6)<>
        round(delivery.total_shipped_base_qty,6)
      OR round(COALESCE(sum(line.received_base_qty),0),6)<>
        round(delivery.total_received_base_qty,6)) invalid
  UNION ALL
  SELECT 'backoffice_delivery_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('backoffice_sales_delivery_orders',
      'backoffice_sales_delivery_order_lines')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
  UNION ALL
  SELECT 'backoffice_delivery_runtime_inventory','INFO',0,
    jsonb_build_object(
      'deliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders),
      'lines',(SELECT count(*) FROM public.backoffice_sales_delivery_order_lines),
      'ready',(SELECT count(*) FROM public.backoffice_sales_delivery_orders
        WHERE status='READY'),
      'operationsReady',false)
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

