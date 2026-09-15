-- Read-only preflight for canonical POS + Backoffice Reserved Out read model.
WITH dependency AS (
  SELECT
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909147000') confirm_runtime_exists,
    to_regprocedure('public.get_inventory_stock_overview()') IS NOT NULL overview_exists,
    (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_name IN(
        'sales_stock_reservations','sales_stock_reservation_lines',
        'backoffice_sales_reservations','backoffice_sales_reservation_lines',
        'backoffice_sales_orders','backoffice_sales_delivery_orders',
        'backoffice_sales_delivery_order_lines')) fulfillment_relations
), checks AS (
  SELECT 'inventory_read_model_dependencies'::text check_name,
    CASE WHEN confirm_runtime_exists AND overview_exists
      AND fulfillment_relations=7 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('confirmRuntimeExists',confirm_runtime_exists,
      'overviewExists',overview_exists,'fulfillmentRelations',fulfillment_relations,
      'expectedRelations',7) details FROM dependency
  UNION ALL
  SELECT 'canonical_stock_overview_source_contract',
    CASE WHEN definition LIKE '%sales_stock_reservation_lines%'
      AND definition LIKE '%reserved_out_base_qty%'
      AND definition LIKE '%available_to_sell_base_qty%'
      AND definition LIKE '%reservationReadModelVersion%'
      THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('posReservationSource',definition LIKE '%sales_stock_reservation_lines%',
      'reservedOutField',definition LIKE '%reserved_out_base_qty%',
      'availableField',definition LIKE '%available_to_sell_base_qty%')
  FROM (SELECT pg_get_functiondef(
    'public.get_inventory_stock_overview()'::regprocedure) definition) routine
  UNION ALL
  SELECT 'backoffice_reservation_header_line_reconciliation',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('reservationCount',count(*))
  FROM (SELECT reservation.id
    FROM public.backoffice_sales_reservations reservation
    LEFT JOIN public.backoffice_sales_reservation_lines line
      ON line.company_id=reservation.company_id
     AND line.reservation_id=reservation.id
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
  SELECT 'backoffice_active_reservation_quantity_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('lineCount',count(*))
  FROM public.backoffice_sales_reservation_lines line
  JOIN public.backoffice_sales_reservations reservation
    ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
  WHERE reservation.status<>'RELEASED'
    AND line.reserved_base_qty-line.released_base_qty-
      line.in_transit_base_qty-line.completed_base_qty<0
  UNION ALL
  SELECT 'inventory_read_model_operational_boundary',
    CASE WHEN active_finance=0 AND offline_pending=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('activeFinanceQueues',active_finance,
      'nonterminalOfflineSubmissions',offline_pending)
  FROM (SELECT
    (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) active_finance,
    (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) offline_pending) runtime
), inventory AS (
  SELECT 'inventory_reservation_read_model_scope'::text check_name,'INFO'::text status,
    jsonb_build_object(
      'posActiveLines',(SELECT count(*) FROM public.sales_stock_reservation_lines line
        JOIN public.sales_stock_reservations reservation
          ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
        WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
          AND line.released_base_qty+line.dispatched_base_qty<line.reserved_base_qty),
      'backofficeActiveLines',(SELECT count(*) FROM public.backoffice_sales_reservation_lines line
        JOIN public.backoffice_sales_reservations reservation
          ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
        WHERE reservation.status<>'RELEASED'
          AND line.released_base_qty+line.in_transit_base_qty+
            line.completed_base_qty<line.reserved_base_qty),
      'rule','Read-only union; no Stock/FIFO/Movement/Delivery/Invoice/Finance mutation') details
)
SELECT * FROM (SELECT * FROM checks UNION ALL SELECT * FROM inventory) result
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;

