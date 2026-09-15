-- Read-only postflight for migration 20260909147000.
WITH definitions AS (
  SELECT
    pg_get_functiondef('public.confirm_backoffice_sales_order(uuid,bigint,uuid)'::regprocedure) confirm_definition,
    pg_get_functiondef('private.compose_backoffice_sales_confirm_fulfillment(uuid,uuid)'::regprocedure) compose_definition,
    pg_get_functiondef('private.backoffice_sales_stock_requirements(uuid,uuid)'::regprocedure) requirement_definition
), checks AS (
  SELECT 'migration_ledger'::text check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1)::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260909147000'
  UNION ALL
  SELECT 'required_confirm_fulfillment_columns',CASE WHEN count(*)=8 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-8)::bigint,jsonb_build_object('expected',8,'columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public' AND
    ((table_name='backoffice_sales_reservations' AND column_name='shortage_base_qty')
      OR (table_name='backoffice_sales_reservation_lines' AND column_name=ANY(ARRAY[
        'stock_uom_id','stock_uom_name_snapshot','quantity_uom','factor_to_base',
        'available_base_qty_snapshot','shortage_base_qty','bundle_component_line_no'])))
  UNION ALL
  SELECT 'required_confirm_fulfillment_routines',CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    abs(count(*)-3)::bigint,jsonb_build_object('expected',3,'routineRows',count(*))
  FROM (VALUES
    (to_regprocedure('public.confirm_backoffice_sales_order(uuid,bigint,uuid)')),
    (to_regprocedure('private.compose_backoffice_sales_confirm_fulfillment(uuid,uuid)')),
    (to_regprocedure('private.backoffice_sales_stock_requirements(uuid,uuid)'))
  ) routine(oid) WHERE oid IS NOT NULL
  UNION ALL
  SELECT 'confirm_fulfillment_definition_contract',
    CASE WHEN confirm_definition LIKE '%compose_backoffice_sales_confirm_fulfillment%'
      AND compose_definition LIKE '%allow_negative_stock%'
      AND compose_definition LIKE '%sales_stock_reservation_lines%'
      AND compose_definition LIKE '%backoffice_sales_reservation_lines%'
      AND compose_definition LIKE '%next_sales_delivery_no%'
      AND requirement_definition LIKE '%resolve_bundle_components%' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN confirm_definition LIKE '%compose_backoffice_sales_confirm_fulfillment%'
      AND compose_definition LIKE '%allow_negative_stock%'
      AND compose_definition LIKE '%sales_stock_reservation_lines%'
      AND compose_definition LIKE '%backoffice_sales_reservation_lines%'
      AND compose_definition LIKE '%next_sales_delivery_no%'
      AND requirement_definition LIKE '%resolve_bundle_components%' THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('publicConfirmComposes',confirm_definition LIKE '%compose_backoffice_sales_confirm_fulfillment%',
      'warehouseNegativeGuard',compose_definition LIKE '%allow_negative_stock%',
      'posReservationIncluded',compose_definition LIKE '%sales_stock_reservation_lines%',
      'backofficeReservationIncluded',compose_definition LIKE '%backoffice_sales_reservation_lines%',
      'canonicalDeliveryNumber',compose_definition LIKE '%next_sales_delivery_no%',
      'canonicalBundleResolver',requirement_definition LIKE '%resolve_bundle_components%')
  FROM definitions
  UNION ALL
  SELECT 'confirm_fulfillment_rpc_boundary',
    CASE WHEN NOT has_function_privilege('anon','public.confirm_backoffice_sales_order(uuid,bigint,uuid)','EXECUTE')
      AND has_function_privilege('authenticated','public.confirm_backoffice_sales_order(uuid,bigint,uuid)','EXECUTE')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN NOT has_function_privilege('anon','public.confirm_backoffice_sales_order(uuid,bigint,uuid)','EXECUTE')
      AND has_function_privilege('authenticated','public.confirm_backoffice_sales_order(uuid,bigint,uuid)','EXECUTE')
      THEN 0 ELSE 1 END::bigint,
    jsonb_build_object('anonExecute',has_function_privilege('anon','public.confirm_backoffice_sales_order(uuid,bigint,uuid)','EXECUTE'),
      'authenticatedExecute',has_function_privilege('authenticated','public.confirm_backoffice_sales_order(uuid,bigint,uuid)','EXECUTE'))
  UNION ALL
  SELECT 'private_confirm_fulfillment_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::bigint,
    jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM (VALUES
    ('private.compose_backoffice_sales_confirm_fulfillment(uuid,uuid)'::regprocedure),
    ('private.backoffice_sales_stock_requirements(uuid,uuid)'::regprocedure)
  ) routine(oid) WHERE has_function_privilege('authenticated',oid,'EXECUTE')
  UNION ALL
  SELECT 'confirm_fulfillment_runtime_reconciliation',
    CASE WHEN NOT EXISTS(
      SELECT 1 FROM public.backoffice_sales_reservations reservation
      LEFT JOIN public.backoffice_sales_delivery_orders delivery
        ON delivery.company_id=reservation.company_id
       AND delivery.sales_order_id=reservation.sales_order_id
       AND delivery.delivery_kind='INITIAL' AND delivery.parent_delivery_order_id IS NULL
      WHERE delivery.id IS NULL OR delivery.status<>'READY'
        OR reservation.total_reserved_base_qty<>reservation.total_ordered_base_qty)
      THEN 'PASS' ELSE 'FAIL' END,
    (SELECT count(*) FROM public.backoffice_sales_reservations reservation
      LEFT JOIN public.backoffice_sales_delivery_orders delivery
        ON delivery.company_id=reservation.company_id
       AND delivery.sales_order_id=reservation.sales_order_id
       AND delivery.delivery_kind='INITIAL' AND delivery.parent_delivery_order_id IS NULL
      WHERE delivery.id IS NULL OR delivery.status<>'READY'
        OR reservation.total_reserved_base_qty<>reservation.total_ordered_base_qty)::bigint,
    jsonb_build_object('reservationRows',(SELECT count(*) FROM public.backoffice_sales_reservations),
      'initialDeliveryRows',(SELECT count(*) FROM public.backoffice_sales_delivery_orders WHERE delivery_kind='INITIAL'))
  UNION ALL
  SELECT 'active_finance_posting_queue',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('runCount',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'confirm_fulfillment_runtime_inventory','INFO',0,
    jsonb_build_object(
      'historicalConfirmedWithoutReservation',(SELECT count(*) FROM public.backoffice_sales_orders document
        WHERE document.status='CONFIRMED' AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
          WHERE reservation.company_id=document.company_id AND reservation.sales_order_id=document.id)),
      'reservations',(SELECT count(*) FROM public.backoffice_sales_reservations),
      'reservationLines',(SELECT count(*) FROM public.backoffice_sales_reservation_lines),
      'deliveries',(SELECT count(*) FROM public.backoffice_sales_delivery_orders),
      'deliveryLines',(SELECT count(*) FROM public.backoffice_sales_delivery_order_lines),
      'shortageBaseQty',(SELECT COALESCE(sum(shortage_base_qty),0) FROM public.backoffice_sales_reservations))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
