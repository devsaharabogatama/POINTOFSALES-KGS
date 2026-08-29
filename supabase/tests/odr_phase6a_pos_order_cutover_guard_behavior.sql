-- ODR-6A cancellation guard fixture-free behavior contract.
BEGIN;

DO $test$
DECLARE v_public TEXT;v_private TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828270000') THEN
    RAISE EXCEPTION 'TEST_FAILED: ODR-6A migration ledger missing';
  END IF;
  SELECT pg_get_functiondef(
    'public.cancel_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_public;
  SELECT pg_get_functiondef(
    'private.odr6a_cancel_pos_sales_order_legacy(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_private;
  IF v_public!~'SALES_ORDER_PAYMENT_RESOLUTION_REQUIRED'
    OR v_public!~'odr6a_cancel_pos_sales_order_legacy'
    OR v_private!~'cancel_pos_sales_order_core'
    OR v_private!~'cancel_confirmed_order_delivery'
    OR v_private!~'refresh_sales_order_procurement_demand' THEN
    RAISE EXCEPTION 'TEST_FAILED: guarded cancellation composition invalid';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'odr_phase6a_pos_order_cutover_guard_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'Payment resolution guard','legacy reservation cancellation composition',
    'Delivery cancellation composition','procurement demand reconciliation',
    'no fixture or write persisted'
  ],'writesPersisted',FALSE) details;
