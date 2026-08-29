-- ODR-6B.1 Reservation Stock Real read-model preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'odr6a_dependency'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*),'requiredVersion','20260828280000') details
  FROM private.kgs_schema_migrations WHERE version='20260828280000'

  UNION ALL
  SELECT 'canonical_stock_overview_runtime',
    CASE WHEN to_regprocedure('public.get_inventory_stock_overview()') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineExists',to_regprocedure(
      'public.get_inventory_stock_overview()') IS NOT NULL)

  UNION ALL
  SELECT 'canonical_pos_order_runtime',
    CASE WHEN to_regprocedure('public.get_pos_sales_orders(uuid)') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineExists',to_regprocedure(
      'public.get_pos_sales_orders(uuid)') IS NOT NULL)

  UNION ALL
  SELECT 'canonical_pos_stock_availability_runtime','SETUP',
    jsonb_build_object('routineExists',to_regprocedure(
      'public.get_pos_stock_availability(uuid,uuid)') IS NOT NULL,
      'requiredDesign',ARRAY['active Cashier session scope',
        'all open Reservation in selected Warehouse',
        'On Hand minus Reserved Out'])

  UNION ALL
  SELECT 'stock_real_permission_state',
    CASE WHEN count(*)=1 AND min(enforcement_status)='ENFORCED'
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rows',count(*),'statuses',
      COALESCE(jsonb_agg(DISTINCT enforcement_status),'[]'::JSONB))
  FROM public.access_permission_catalog
  WHERE permission_key='inventory.stock_real'

  UNION ALL
  SELECT 'reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
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
  SELECT 'active_reservation_quantity_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.sales_stock_reservation_lines line
  JOIN public.sales_stock_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
    AND line.reserved_base_qty-line.released_base_qty-line.dispatched_base_qty<0

  UNION ALL
  SELECT 'browser_reservation_table_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('privilegeRows',count(*))
  FROM information_schema.role_table_grants privilege
  WHERE privilege.table_schema='public'
    AND privilege.table_name IN('sales_stock_reservations',
      'sales_stock_reservation_lines','sales_stock_reservation_audit')
    AND privilege.grantee IN('anon','authenticated','PUBLIC')

  UNION ALL
  SELECT 'reservation_stock_read_model_state','SETUP',
    jsonb_build_object('requiredFields',ARRAY[
      'reserved_out_base_qty','available_to_sell_base_qty',
      'reservationReadModelVersion'])
),inventory AS (
  SELECT 'reservation_runtime_inventory'::TEXT check_name,'INFO'::TEXT status,
    jsonb_build_object(
      'openReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='OPEN'),
      'partialReservations',(SELECT count(*) FROM public.sales_stock_reservations
        WHERE status='PARTIALLY_DISPATCHED'),
      'activeLines',(SELECT count(*) FROM public.sales_stock_reservation_lines line
        JOIN public.sales_stock_reservations reservation
          ON reservation.company_id=line.company_id
         AND reservation.id=line.reservation_id
        WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')),
      'reservedOutBaseQty',(SELECT COALESCE(sum(GREATEST(
        line.reserved_base_qty-line.released_base_qty-line.dispatched_base_qty,0)),0)
        FROM public.sales_stock_reservation_lines line
        JOIN public.sales_stock_reservations reservation
          ON reservation.company_id=line.company_id
         AND reservation.id=line.reservation_id
        WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')))
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY check_name;
