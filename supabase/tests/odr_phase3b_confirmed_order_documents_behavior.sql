-- ODR-3B contract behavior. No business fixture and no persistent writes.
BEGIN;
DO $test$
DECLARE v_confirm TEXT;v_cancel TEXT;v_status TEXT;v_guarded BOOLEAN:=FALSE;
BEGIN
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_confirm;
  SELECT pg_get_functiondef(
    'public.cancel_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_cancel;
  SELECT pg_get_functiondef(
    'private.acp5e_update_sales_delivery_status_core(uuid,bigint,text,text)'::regprocedure)
  INTO v_status;
  IF v_confirm!~'confirm_pos_sales_order_core'
    OR v_confirm!~'ensure_confirmed_order_documents' THEN
    RAISE EXCEPTION 'TEST_FAILED: Confirm is not atomic with document snapshot';
  END IF;
  IF v_cancel!~'cancel_pos_sales_order_core'
    OR v_cancel!~'cancel_confirmed_order_delivery' THEN
    RAISE EXCEPTION 'TEST_FAILED: Cancel does not close linked READY Delivery';
  END IF;
  IF v_status!~'USE_CANONICAL_DISPATCH_RUNTIME' THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy linked-Delivery Dispatch bypass remains';
  END IF;
  BEGIN
    PERFORM private.ensure_confirmed_order_documents(gen_random_uuid(),gen_random_uuid());
  EXCEPTION WHEN raise_exception THEN
    v_guarded:=SQLERRM='SALES_ORDER_NOT_CONFIRMED';
  END;
  IF NOT v_guarded THEN
    RAISE EXCEPTION 'TEST_FAILED: unconfirmed document source was accepted';
  END IF;
  IF private.build_confirmed_order_invoice_snapshot(
    gen_random_uuid(),gen_random_uuid()) IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: nonexistent order produced a snapshot';
  END IF;
END
$test$;
SELECT 'odr_phase3b_confirmed_order_documents_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'Confirm-document atomic definition','Cancel-linked-Delivery definition',
    'legacy Dispatch bypass quarantine','unconfirmed source rejection']) details;
ROLLBACK;
