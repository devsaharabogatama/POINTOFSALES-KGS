-- ODR-6B.1 reservation Stock Real postflight. SELECT-only.
WITH expected AS (
  SELECT line.company_id,line.stock_product_id product_id,line.warehouse_id,
    sum(GREATEST(line.reserved_base_qty-line.released_base_qty-
      line.dispatched_base_qty,0)) reserved_out_base_qty
  FROM public.sales_stock_reservation_lines line
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
    AND line.released_base_qty+line.dispatched_base_qty<line.reserved_base_qty
  GROUP BY line.company_id,line.stock_product_id,line.warehouse_id
),checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-2)::BIGINT violation_rows,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260829090000','20260829100000')

  UNION ALL
  SELECT 'stock_overview_reservation_definition',
    CASE WHEN definition~'reserved_out_base_qty'
      AND definition~'available_to_sell_base_qty'
      AND definition~'reservationReadModelVersion' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'reserved_out_base_qty'
      AND definition~'available_to_sell_base_qty'
      AND definition~'reservationReadModelVersion' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM (SELECT pg_get_functiondef(
    'public.get_inventory_stock_overview()'::regprocedure) definition) runtime

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
      THEN 0 ELSE 1 END,
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
      THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',routine.prosecdef,
      'volatility',routine.provolatile,'config',routine.proconfig)
  FROM pg_proc routine
  JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='get_inventory_stock_overview'
    AND pg_get_function_identity_arguments(routine.oid)=''

  UNION ALL
  SELECT 'pos_stock_availability_rpc_boundary',
    CASE WHEN has_function_privilege('authenticated',
        'public.get_pos_stock_availability(uuid,uuid)','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_pos_stock_availability(uuid,uuid)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN has_function_privilege('authenticated',
        'public.get_pos_stock_availability(uuid,uuid)','EXECUTE')
      AND NOT has_function_privilege('anon',
        'public.get_pos_stock_availability(uuid,uuid)','EXECUTE')
      THEN 0 ELSE 1 END,
    jsonb_build_object('authenticatedExecute',has_function_privilege(
      'authenticated','public.get_pos_stock_availability(uuid,uuid)','EXECUTE'),
      'anonExecute',has_function_privilege(
        'anon','public.get_pos_stock_availability(uuid,uuid)','EXECUTE'))

  UNION ALL
  SELECT 'pos_stock_availability_security_contract',
    CASE WHEN routine.prosecdef AND routine.provolatile='s'
      AND routine.proconfig @> ARRAY['search_path=public, pg_temp']
      AND pg_get_functiondef(routine.oid)~'ACTIVE_CASHIER_SESSION_REQUIRED'
      AND pg_get_functiondef(routine.oid)~'available_to_sell_base_qty'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN routine.prosecdef AND routine.provolatile='s'
      AND routine.proconfig @> ARRAY['search_path=public, pg_temp']
      AND pg_get_functiondef(routine.oid)~'ACTIVE_CASHIER_SESSION_REQUIRED'
      AND pg_get_functiondef(routine.oid)~'available_to_sell_base_qty'
      THEN 0 ELSE 1 END,
    jsonb_build_object('securityDefiner',routine.prosecdef,
      'volatility',routine.provolatile,'config',routine.proconfig)
  FROM pg_proc routine
  WHERE routine.oid=
    'public.get_pos_stock_availability(uuid,uuid)'::regprocedure

  UNION ALL
  SELECT 'reservation_remaining_quantity_contract',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pairCount',count(*))
  FROM expected WHERE reserved_out_base_qty<=0

  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('reservationCount',count(*))
  FROM (SELECT reservation.id
    FROM public.sales_stock_reservations reservation
    LEFT JOIN public.sales_stock_reservation_lines line
      ON line.company_id=reservation.company_id
     AND line.reservation_id=reservation.id
    GROUP BY reservation.id,reservation.total_reserved_base_qty,
      reservation.total_released_base_qty,reservation.total_dispatched_base_qty
    HAVING round(COALESCE(sum(line.reserved_base_qty),0),6)<>
        round(reservation.total_reserved_base_qty,6)
      OR round(COALESCE(sum(line.released_base_qty),0),6)<>
        round(reservation.total_released_base_qty,6)
      OR round(COALESCE(sum(line.dispatched_base_qty),0),6)<>
        round(reservation.total_dispatched_base_qty,6)) invalid

  UNION ALL
  SELECT 'stock_balance_movement_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('pairCount',count(*))
  FROM (SELECT stock.company_id,stock.product_id,stock.warehouse_id
    FROM public.product_stocks stock
    LEFT JOIN LATERAL (SELECT movement.balance_after_base_qty
      FROM public.stock_movements movement
      WHERE movement.company_id=stock.company_id
        AND movement.product_id=stock.product_id
        AND movement.warehouse_id=stock.warehouse_id
        AND movement.movement_status='POSTED'
      ORDER BY COALESCE(movement.posted_at,movement.created_at) DESC,
        movement.id DESC LIMIT 1) latest ON TRUE
    WHERE latest.balance_after_base_qty IS NOT NULL
      AND round(stock.stock_qty,6)<>round(latest.balance_after_base_qty,6)) invalid

  UNION ALL
  SELECT 'browser_reservation_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('sales_stock_reservations',
      'sales_stock_reservation_lines','sales_stock_reservation_audit')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')
),inventory AS (
  SELECT 'reservation_stock_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    0::BIGINT violation_rows,jsonb_build_object(
      'activeReservationPairs',(SELECT count(*) FROM expected),
      'reservedOutBaseQty',(SELECT COALESCE(sum(reserved_out_base_qty),0) FROM expected),
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='OPEN'),
      'partialReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='PARTIALLY_DISPATCHED')) details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
