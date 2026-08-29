-- ODR-6B.1 forward-fix: canonical POS Available to Sell read model.
-- Read-only runtime: no Stock, FIFO, Movement, Reservation, or Finance mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260829090000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-6B.1 Stock Real required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260829100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260829100000';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND (
        (table_name='cashier_sessions' AND column_name IN(
          'id','company_id','cashier_id','store_id','sales_warehouse_id',
          'status','opened_at')) OR
        (table_name='sales_stock_reservations' AND column_name IN(
          'id','company_id','status')) OR
        (table_name='sales_stock_reservation_lines' AND column_name IN(
          'company_id','reservation_id','stock_product_id','warehouse_id',
          'reserved_base_qty','released_base_qty','dispatched_base_qty'))
      ))<>17 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: POS Reservation schema incomplete';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_pos_stock_availability(
  p_store_id UUID,p_warehouse_id UUID
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_session_id UUID;
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_store_id IS NULL OR p_warehouse_id IS NULL THEN
    RAISE EXCEPTION 'POS_STOCK_SCOPE_REQUIRED';
  END IF;

  SELECT session.id INTO v_session_id
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.cashier_id=auth.uid()
    AND session.store_id=p_store_id
    AND session.sales_warehouse_id=p_warehouse_id
    AND session.status='OPEN'::public.session_status
  ORDER BY session.opened_at DESC,session.id LIMIT 1;
  IF v_session_id IS NULL THEN
    RAISE EXCEPTION 'ACTIVE_CASHIER_SESSION_REQUIRED';
  END IF;

  RETURN jsonb_build_object(
    'companyId',v_company,'storeId',p_store_id,'warehouseId',p_warehouse_id,
    'cashierSessionId',v_session_id,'reservationReadModelVersion',1,
    'availability',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'stock_product_id',product.id,
      'on_hand_base_qty',COALESCE(stock.stock_qty,0),
      'reserved_out_base_qty',COALESCE(reserved.reserved_out_base_qty,0),
      'available_to_sell_base_qty',COALESCE(stock.stock_qty,0)-
        COALESCE(reserved.reserved_out_base_qty,0))
      ORDER BY product.sku,product.id),'[]'::JSONB)
    FROM public.products product
    LEFT JOIN public.product_stocks stock
      ON stock.company_id=product.company_id AND stock.product_id=product.id
     AND stock.warehouse_id=p_warehouse_id
    LEFT JOIN LATERAL (
      SELECT COALESCE(sum(GREATEST(line.reserved_base_qty-
        line.released_base_qty-line.dispatched_base_qty,0)),0)
        reserved_out_base_qty
      FROM public.sales_stock_reservation_lines line
      JOIN public.sales_stock_reservations reservation
        ON reservation.company_id=line.company_id
       AND reservation.id=line.reservation_id
      WHERE line.company_id=v_company AND line.stock_product_id=product.id
        AND line.warehouse_id=p_warehouse_id
        AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
    ) reserved ON TRUE
    WHERE product.company_id=v_company AND product.is_active
      AND NOT product.is_bundle));
END
$$;

REVOKE ALL ON FUNCTION public.get_pos_stock_availability(UUID,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_pos_stock_availability(UUID,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260829100000','odr_phase6b_pos_stock_availability_forward_fix',
  'Add active-session guarded POS Available to Sell read model across all open Reservations in the selected Warehouse; no Stock/FIFO/Movement/Finance mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
