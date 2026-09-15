-- Add Backoffice Sales reservations to the canonical Inventory Stock Real read model.
-- Read-only runtime: no Reservation, Stock, FIFO, Movement, Delivery, Invoice, or Finance mutation.
BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909147000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Confirm fulfillment runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909148000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909148000';
  END IF;
  IF to_regprocedure('public.get_inventory_stock_overview()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Stock Overview RPC missing';
  END IF;
  SELECT pg_get_functiondef('public.get_inventory_stock_overview()'::regprocedure)
    INTO v_definition;
  IF v_definition NOT LIKE '%sales_stock_reservation_lines%'
    OR v_definition NOT LIKE '%available_to_sell_base_qty%'
    OR v_definition NOT LIKE '%reservationReadModelVersion%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Stock Overview definition drift';
  END IF;
  IF (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_name IN(
        'backoffice_sales_orders','backoffice_sales_reservations',
        'backoffice_sales_reservation_lines','backoffice_sales_delivery_orders',
        'backoffice_sales_delivery_order_lines'))<>5 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice fulfillment schema incomplete';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_inventory_stock_overview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_balances jsonb;v_warehouses jsonb;v_allocations jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_real','VIEW');

  WITH pos_reserved AS (
    SELECT line.stock_product_id product_id,line.warehouse_id,
      sum(GREATEST(line.reserved_base_qty-line.released_base_qty-
        line.dispatched_base_qty,0)) reserved_out_base_qty,
      max(line.updated_at) updated_at
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id
     AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company
      AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
      AND line.released_base_qty+line.dispatched_base_qty<line.reserved_base_qty
    GROUP BY line.stock_product_id,line.warehouse_id
  ), backoffice_reserved AS (
    SELECT line.product_id,line.warehouse_id,
      sum(GREATEST(line.reserved_base_qty-line.released_base_qty-
        line.in_transit_base_qty-line.completed_base_qty,0)) reserved_out_base_qty,
      max(line.updated_at) updated_at
    FROM public.backoffice_sales_reservation_lines line
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=line.company_id
     AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND reservation.status<>'RELEASED'
      AND line.released_base_qty+line.in_transit_base_qty+
        line.completed_base_qty<line.reserved_base_qty
    GROUP BY line.product_id,line.warehouse_id
  ), pair_rows AS (
    SELECT stock.product_id,stock.warehouse_id
    FROM public.product_stocks stock WHERE stock.company_id=v_company
    UNION SELECT product_id,warehouse_id FROM pos_reserved
    UNION SELECT product_id,warehouse_id FROM backoffice_reserved
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',balance_row.id,'product_id',balance_row.product_id,
    'warehouse_id',balance_row.warehouse_id,'stock_qty',balance_row.stock_qty,
    'reserved_out_base_qty',balance_row.reserved_out_base_qty,
    'pos_reserved_out_base_qty',balance_row.pos_reserved_out_base_qty,
    'backoffice_reserved_out_base_qty',balance_row.backoffice_reserved_out_base_qty,
    'available_to_sell_base_qty',balance_row.available_to_sell_base_qty,
    'updated_at',balance_row.updated_at,'fifo_value',balance_row.fifo_value,
    'minimum_stock_base_qty',balance_row.minimum_stock_base_qty,
    'low_stock_alert_enabled',balance_row.low_stock_alert_enabled,
    'last_movement_type',balance_row.last_movement_type,
    'last_movement_at',balance_row.last_movement_at)
    ORDER BY balance_row.updated_at DESC NULLS LAST,balance_row.product_id,
      balance_row.warehouse_id),'[]'::jsonb)
  INTO v_balances
  FROM (
    SELECT stock.id,pair.product_id,pair.warehouse_id,
      COALESCE(stock.stock_qty,0) stock_qty,
      COALESCE(pos.reserved_out_base_qty,0) pos_reserved_out_base_qty,
      COALESCE(backoffice.reserved_out_base_qty,0) backoffice_reserved_out_base_qty,
      COALESCE(pos.reserved_out_base_qty,0)+
        COALESCE(backoffice.reserved_out_base_qty,0) reserved_out_base_qty,
      COALESCE(stock.stock_qty,0)-COALESCE(pos.reserved_out_base_qty,0)-
        COALESCE(backoffice.reserved_out_base_qty,0) available_to_sell_base_qty,
      COALESCE(GREATEST(stock.updated_at,pos.updated_at,backoffice.updated_at),
        stock.updated_at,pos.updated_at,backoffice.updated_at) updated_at,
      COALESCE(fifo.fifo_value,0) fifo_value,
      setting.minimum_stock_base_qty,
      COALESCE(setting.low_stock_alert_enabled,false) low_stock_alert_enabled,
      movement.movement_type::text last_movement_type,
      movement.movement_at last_movement_at
    FROM pair_rows pair
    LEFT JOIN public.product_stocks stock
      ON stock.company_id=v_company AND stock.product_id=pair.product_id
     AND stock.warehouse_id=pair.warehouse_id
    LEFT JOIN pos_reserved pos ON pos.product_id=pair.product_id
      AND pos.warehouse_id=pair.warehouse_id
    LEFT JOIN backoffice_reserved backoffice
      ON backoffice.product_id=pair.product_id
     AND backoffice.warehouse_id=pair.warehouse_id
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(batch.qty_remaining*batch.cogs_unit),0) fifo_value
      FROM public.product_batches batch
      WHERE batch.company_id=v_company AND batch.product_id=pair.product_id
        AND batch.warehouse_id=pair.warehouse_id AND batch.qty_remaining>0
    ) fifo ON true
    LEFT JOIN public.product_warehouse_stock_settings setting
      ON setting.company_id=v_company AND setting.product_id=pair.product_id
     AND setting.warehouse_id=pair.warehouse_id
    LEFT JOIN LATERAL (
      SELECT stock_movement.movement_type,
        COALESCE(stock_movement.posted_at,stock_movement.created_at) movement_at
      FROM public.stock_movements stock_movement
      WHERE stock_movement.company_id=v_company
        AND stock_movement.product_id=pair.product_id
        AND stock_movement.warehouse_id=pair.warehouse_id
        AND stock_movement.movement_status='POSTED'
      ORDER BY COALESCE(stock_movement.posted_at,stock_movement.created_at) DESC,
        stock_movement.id DESC LIMIT 1
    ) movement ON true
    ORDER BY updated_at DESC NULLS LAST,pair.product_id,pair.warehouse_id
    LIMIT 20000
  ) balance_row;

  WITH allocation_rows AS (
    SELECT 'POS'::text source,line.id reservation_line_id,
      line.stock_product_id product_id,line.warehouse_id,
      reservation.id reservation_id,reservation.sales_id sales_order_id,
      sale.invoice_no sales_order_no,
      COALESCE(customer.code,'WALK-IN') customer_code,
      COALESCE(customer.name,'Pelanggan Umum') customer_name,
      reservation.status reservation_status,
      GREATEST(line.reserved_base_qty-line.released_base_qty-
        line.dispatched_base_qty,0) reserved_out_base_qty,
      line.shortage_base_qty,COALESCE(delivery.scheduled_at::date,
        sale.planned_order_date,sale.transaction_date::date) scheduled_date,
      CASE WHEN delivery.id IS NULL THEN '[]'::jsonb
        ELSE jsonb_build_array(jsonb_build_object(
          'id',delivery.id,'deliveryNo',delivery.delivery_no,
          'status',delivery.status)) END delivery_orders,line.updated_at
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id
     AND reservation.id=line.reservation_id
    JOIN public.sales_headers sale ON sale.company_id=line.company_id
      AND sale.id=line.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
    WHERE line.company_id=v_company
      AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
      AND line.released_base_qty+line.dispatched_base_qty<line.reserved_base_qty
    UNION ALL
    SELECT 'BACKOFFICE',line.id,line.product_id,line.warehouse_id,
      reservation.id,reservation.sales_order_id,document.order_no,
      COALESCE(document.customer_snapshot->>'code','WALK-IN'),
      COALESCE(document.customer_snapshot->>'name','Pelanggan Umum'),
      reservation.status,
      GREATEST(line.reserved_base_qty-line.released_base_qty-
        line.in_transit_base_qty-line.completed_base_qty,0),
      line.shortage_base_qty,document.planned_delivery_date,
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
          'id',delivery.id,'deliveryNo',delivery.delivery_no,
          'status',delivery.status,'kind',delivery.delivery_kind)
          ORDER BY delivery.sequence_no)
        FROM public.backoffice_sales_delivery_order_lines delivery_line
        JOIN public.backoffice_sales_delivery_orders delivery
          ON delivery.company_id=delivery_line.company_id
         AND delivery.id=delivery_line.delivery_order_id
        WHERE delivery_line.company_id=line.company_id
          AND delivery_line.reservation_line_id=line.id),'[]'::jsonb),line.updated_at
    FROM public.backoffice_sales_reservation_lines line
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=line.company_id
     AND reservation.id=line.reservation_id
    JOIN public.backoffice_sales_orders document
      ON document.company_id=reservation.company_id
     AND document.id=reservation.sales_order_id
    WHERE line.company_id=v_company AND reservation.status<>'RELEASED'
      AND line.released_base_qty+line.in_transit_base_qty+
        line.completed_base_qty<line.reserved_base_qty
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'company_id',v_company,'source',allocation.source,
    'reservation_line_id',allocation.reservation_line_id,
    'product_id',allocation.product_id,'warehouse_id',allocation.warehouse_id,
    'reservation_id',allocation.reservation_id,
    'sales_order_id',allocation.sales_order_id,
    'sales_order_no',allocation.sales_order_no,
    'customer_code',allocation.customer_code,
    'customer_name',allocation.customer_name,
    'reservation_status',allocation.reservation_status,
    'reserved_out_base_qty',allocation.reserved_out_base_qty,
    'shortage_base_qty',allocation.shortage_base_qty,
    'scheduled_date',allocation.scheduled_date,
    'delivery_orders',allocation.delivery_orders,
    'updated_at',allocation.updated_at)
    ORDER BY allocation.scheduled_date,allocation.sales_order_no,
      allocation.reservation_line_id),'[]'::jsonb)
  INTO v_allocations FROM allocation_rows allocation;

  SELECT COALESCE(jsonb_agg(to_jsonb(warehouse_row)
    ORDER BY warehouse_row.name,warehouse_row.id),'[]'::jsonb)
  INTO v_warehouses FROM (
    SELECT warehouse.id,warehouse.name,warehouse.warehouse_type,
      warehouse.location,warehouse.is_active
    FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
    ORDER BY warehouse.name,warehouse.id LIMIT 5000
  ) warehouse_row;

  RETURN jsonb_build_object('companyId',v_company,
    'reservationReadModelVersion',2,'balances',v_balances,
    'reservationAllocations',v_allocations,'warehouses',v_warehouses);
END
$$;

REVOKE ALL ON FUNCTION public.get_inventory_stock_overview()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_stock_overview()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909148000','backoffice_sales_inventory_reservation_read_model',
  'Canonical Stock Real combines POS and Backoffice remaining Reserved Out and exposes tenant-scoped allocation lineage; read-only with no operational or Finance mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
