-- Read-only postflight for migration 20260909148000.
WITH definitions AS (
  SELECT pg_get_functiondef(
    'public.get_inventory_stock_overview()'::regprocedure) overview_definition
), combined_expected AS (
  SELECT source.company_id,source.product_id,source.warehouse_id,
    sum(source.pos_reserved) pos_reserved,
    sum(source.backoffice_reserved) backoffice_reserved
  FROM (
    SELECT line.company_id,line.stock_product_id product_id,line.warehouse_id,
      GREATEST(line.reserved_base_qty-line.released_base_qty-
        line.dispatched_base_qty,0) pos_reserved,0::numeric backoffice_reserved
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
      AND line.released_base_qty+line.dispatched_base_qty<line.reserved_base_qty
    UNION ALL
    SELECT line.company_id,line.product_id,line.warehouse_id,0,
      GREATEST(line.reserved_base_qty-line.released_base_qty-
        line.in_transit_base_qty-line.completed_base_qty,0)
    FROM public.backoffice_sales_reservation_lines line
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE reservation.status<>'RELEASED'
      AND line.released_base_qty+line.in_transit_base_qty+
        line.completed_base_qty<line.reserved_base_qty
  ) source
  GROUP BY source.company_id,source.product_id,source.warehouse_id
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909148000'
  UNION ALL
  SELECT 'combined_inventory_reservation_definition',
    CASE WHEN overview_definition LIKE '%backoffice_sales_reservation_lines%'
      AND overview_definition LIKE '%pos_reserved_out_base_qty%'
      AND overview_definition LIKE '%backoffice_reserved_out_base_qty%'
      AND overview_definition LIKE '%reservationAllocations%'
      AND overview_definition LIKE '%reservationReadModelVersion%2%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN overview_definition LIKE '%backoffice_sales_reservation_lines%'
      AND overview_definition LIKE '%pos_reserved_out_base_qty%'
      AND overview_definition LIKE '%backoffice_reserved_out_base_qty%'
      AND overview_definition LIKE '%reservationAllocations%'
      AND overview_definition LIKE '%reservationReadModelVersion%2%'
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('backofficeSource',overview_definition LIKE '%backoffice_sales_reservation_lines%',
      'sourceBreakdown',overview_definition LIKE '%backoffice_reserved_out_base_qty%',
      'allocationDetail',overview_definition LIKE '%reservationAllocations%')
  FROM definitions
  UNION ALL
  SELECT 'inventory_read_model_no_mutation_definition',
    CASE WHEN upper(overview_definition)!~'\m(INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\M'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN upper(overview_definition)!~'\m(INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\M'
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('readOnlyDefinition',
      upper(overview_definition)!~'\m(INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\M')
  FROM definitions
  UNION ALL
  SELECT 'stock_overview_rpc_boundary',
    CASE WHEN has_function_privilege('authenticated',
        'public.get_inventory_stock_overview()','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_inventory_stock_overview()','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
        'public.get_inventory_stock_overview()','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_inventory_stock_overview()','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('authenticatedExecute',has_function_privilege(
      'authenticated','public.get_inventory_stock_overview()','EXECUTE'),
      'anonExecute',has_function_privilege(
      'anon','public.get_inventory_stock_overview()','EXECUTE'))
  UNION ALL
  SELECT 'stock_overview_security_contract',
    CASE WHEN routine.prosecdef AND routine.provolatile='s'
      AND routine.proconfig @> ARRAY['search_path=public, pg_temp']
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN routine.prosecdef AND routine.provolatile='s'
      AND routine.proconfig @> ARRAY['search_path=public, pg_temp']
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('securityDefiner',routine.prosecdef,
      'volatility',routine.provolatile,'config',routine.proconfig)
  FROM pg_proc routine WHERE routine.oid=
    'public.get_inventory_stock_overview()'::regprocedure
  UNION ALL
  SELECT 'combined_reservation_quantity_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('pairCount',count(*))
  FROM combined_expected
  WHERE pos_reserved<0 OR backoffice_reserved<0
    OR pos_reserved+backoffice_reserved<=0
  UNION ALL
  SELECT 'backoffice_reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('reservationCount',count(*))
  FROM (SELECT reservation.id
    FROM public.backoffice_sales_reservations reservation
    LEFT JOIN public.backoffice_sales_reservation_lines line
      ON line.company_id=reservation.company_id AND line.reservation_id=reservation.id
    GROUP BY reservation.id,reservation.total_reserved_base_qty,
      reservation.total_released_base_qty,reservation.total_in_transit_base_qty,
      reservation.total_completed_base_qty
    HAVING round(COALESCE(sum(line.reserved_base_qty),0),6)<>
        round(reservation.total_reserved_base_qty,6)
      OR round(COALESCE(sum(line.released_base_qty),0),6)<>
        round(reservation.total_released_base_qty,6)
      OR round(COALESCE(sum(line.in_transit_base_qty),0),6)<>
        round(reservation.total_in_transit_base_qty,6)
      OR round(COALESCE(sum(line.completed_base_qty),0),6)<>
        round(reservation.total_completed_base_qty,6)) invalid
  UNION ALL
  SELECT 'active_finance_posting_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'inventory_reservation_runtime_inventory','INFO',0,
    jsonb_build_object('pairs',(SELECT count(*) FROM combined_expected),
      'posReservedOut',(SELECT COALESCE(sum(pos_reserved),0) FROM combined_expected),
      'backofficeReservedOut',(SELECT COALESCE(sum(backoffice_reserved),0) FROM combined_expected),
      'backofficeReservations',(SELECT count(*) FROM public.backoffice_sales_reservations),
      'backofficeDeliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

