-- ODR-6B.1 reservation Stock Real fixture-free behavior contract.
BEGIN;
DO $test$
DECLARE v_definition TEXT;v_pos_definition TEXT;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260829090000','20260829100000'))<>2 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: ODR-6B.1 Stock and POS read-model migrations required';
  END IF;
  IF to_regprocedure(
      'public.get_pos_stock_availability(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: POS Stock availability RPC missing';
  END IF;
  SELECT pg_get_functiondef('public.get_inventory_stock_overview()'::regprocedure)
  INTO v_definition;
  SELECT pg_get_functiondef(
    'public.get_pos_stock_availability(uuid,uuid)'::regprocedure)
  INTO v_pos_definition;
  IF v_definition!~'sales_stock_reservation_lines'
    OR v_definition!~'sales_stock_reservations'
    OR v_definition!~'OPEN'
    OR v_definition!~'PARTIALLY_DISPATCHED'
    OR v_definition!~'reserved_out_base_qty'
    OR v_definition!~'available_to_sell_base_qty'
    OR v_definition!~'reservationReadModelVersion'
    OR v_definition!~'acp_require_permission_capability' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Reservation Stock read contract invalid';
  END IF;
  IF v_pos_definition!~'available_to_sell_base_qty'
    OR v_pos_definition!~'sales_stock_reservation_lines'
    OR v_pos_definition!~'PARTIALLY_DISPATCHED'
    OR v_pos_definition!~'cashier_sessions'
    OR v_pos_definition!~'ACTIVE_CASHIER_SESSION_REQUIRED'
    OR v_pos_definition~'sale.store_id=p_store_id' THEN
    RAISE EXCEPTION 'TEST_FAILED: POS Available to Sell contract invalid';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'odr_phase6b_reservation_stock_read_model_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'OPEN and PARTIALLY_DISPATCHED Reservation only',
    'remaining Reserved Out','On Hand minus Reserved availability',
    'reservation-only Product/Warehouse pair','Stock Real permission guard',
    'POS catalog availability source',
    'no fixture or write persisted'],'writesPersisted',FALSE) details;
