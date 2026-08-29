-- ODR-6B.1: expose canonical Reserved Out and Available to Sell in Stock Real.
-- Read-model only: no Stock, FIFO, Movement, Reservation, or Finance mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828280000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-6A.1 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260829090000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260829090000';
  END IF;
  IF to_regprocedure('public.get_inventory_stock_overview()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Stock overview RPC missing';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND (
        (table_name='sales_stock_reservations' AND column_name IN(
          'id','company_id','status')) OR
        (table_name='sales_stock_reservation_lines' AND column_name IN(
          'company_id','reservation_id','stock_product_id','warehouse_id',
          'reserved_base_qty','released_base_qty','dispatched_base_qty','updated_at'))
      ))<>11 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Reservation schema incomplete';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_inventory_stock_overview()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_balances JSONB;v_warehouses JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.stock_real','VIEW');

  WITH pair_rows AS (
    SELECT stock.product_id,stock.warehouse_id
    FROM public.product_stocks stock WHERE stock.company_id=v_company
    UNION
    SELECT line.stock_product_id,line.warehouse_id
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id
     AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company
      AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
      AND line.released_base_qty+line.dispatched_base_qty<line.reserved_base_qty
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id',balance_row.id,'product_id',balance_row.product_id,
    'warehouse_id',balance_row.warehouse_id,'stock_qty',balance_row.stock_qty,
    'reserved_out_base_qty',balance_row.reserved_out_base_qty,
    'available_to_sell_base_qty',balance_row.available_to_sell_base_qty,
    'updated_at',balance_row.updated_at,'fifo_value',balance_row.fifo_value,
    'minimum_stock_base_qty',balance_row.minimum_stock_base_qty,
    'low_stock_alert_enabled',balance_row.low_stock_alert_enabled,
    'last_movement_type',balance_row.last_movement_type,
    'last_movement_at',balance_row.last_movement_at)
    ORDER BY balance_row.updated_at DESC NULLS LAST,balance_row.product_id,
      balance_row.warehouse_id),'[]'::JSONB)
  INTO v_balances
  FROM (
    SELECT stock.id,pair.product_id,pair.warehouse_id,
      COALESCE(stock.stock_qty,0) stock_qty,
      COALESCE(reserved.reserved_out_base_qty,0) reserved_out_base_qty,
      COALESCE(stock.stock_qty,0)-COALESCE(reserved.reserved_out_base_qty,0)
        available_to_sell_base_qty,
      COALESCE(GREATEST(stock.updated_at,reserved.updated_at),
        stock.updated_at,reserved.updated_at) updated_at,
      COALESCE(fifo.fifo_value,0) fifo_value,
      setting.minimum_stock_base_qty,
      COALESCE(setting.low_stock_alert_enabled,FALSE) low_stock_alert_enabled,
      movement.movement_type::TEXT last_movement_type,
      movement.movement_at last_movement_at
    FROM pair_rows pair
    LEFT JOIN public.product_stocks stock
      ON stock.company_id=v_company AND stock.product_id=pair.product_id
     AND stock.warehouse_id=pair.warehouse_id
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(GREATEST(line.reserved_base_qty-
          line.released_base_qty-line.dispatched_base_qty,0)),0)
          reserved_out_base_qty,max(line.updated_at) updated_at
      FROM public.sales_stock_reservation_lines line
      JOIN public.sales_stock_reservations reservation
        ON reservation.company_id=line.company_id
       AND reservation.id=line.reservation_id
      WHERE line.company_id=v_company AND line.stock_product_id=pair.product_id
        AND line.warehouse_id=pair.warehouse_id
        AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
    ) reserved ON TRUE
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(batch.qty_remaining*batch.cogs_unit),0) fifo_value
      FROM public.product_batches batch
      WHERE batch.company_id=v_company AND batch.product_id=pair.product_id
        AND batch.warehouse_id=pair.warehouse_id AND batch.qty_remaining>0
    ) fifo ON TRUE
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
    ) movement ON TRUE
    ORDER BY updated_at DESC NULLS LAST,pair.product_id,pair.warehouse_id
    LIMIT 20000
  ) balance_row;

  SELECT COALESCE(jsonb_agg(to_jsonb(warehouse_row)
    ORDER BY warehouse_row.name,warehouse_row.id),'[]'::JSONB)
  INTO v_warehouses FROM (
    SELECT warehouse.id,warehouse.name,warehouse.warehouse_type,
      warehouse.location,warehouse.is_active
    FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
    ORDER BY warehouse.name,warehouse.id LIMIT 5000
  ) warehouse_row;

  RETURN jsonb_build_object('companyId',v_company,
    'reservationReadModelVersion',1,'balances',v_balances,
    'warehouses',v_warehouses);
END
$$;

REVOKE ALL ON FUNCTION public.get_inventory_stock_overview()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_stock_overview()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260829090000','odr_phase6b_reservation_stock_read_model',
  'Expose server-derived Reserved Out and Available to Sell per Product/Warehouse through guarded Stock Real RPC, including reservation-only pairs; read-model and UI contract only');

NOTIFY pgrst,'reload schema';
COMMIT;
