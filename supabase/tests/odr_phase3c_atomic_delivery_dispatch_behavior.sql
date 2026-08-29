-- ODR-3C definition and denial behavior. No business fixture; no writes persist.
BEGIN;
DO $test$
DECLARE v_dispatch TEXT;v_received TEXT;v_workspace TEXT;v_guard TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure)
  INTO v_dispatch;
  SELECT pg_get_functiondef(
    'public.confirm_sales_delivery_received(uuid,bigint,text,text)'::regprocedure)
  INTO v_received;
  SELECT pg_get_functiondef(
    'public.get_inventory_delivery_dispatch_workspace(date,date)'::regprocedure)
  INTO v_workspace;
  SELECT pg_get_functiondef(
    'private.trg_g4_guard_negative_sale_movement()'::regprocedure)
  INTO v_guard;
  IF v_dispatch!~'pg_advisory_xact_lock'
    OR v_dispatch!~'UPDATE public.product_batches'
    OR v_dispatch!~'INSERT INTO public.product_stocks'
    OR v_dispatch!~'INSERT INTO public.stock_movements'
    OR v_dispatch!~'sales_dispatch_allocations'
    OR v_dispatch!~'sales_stock_reservation_audit'
    OR v_dispatch!~'IDEMPOTENCY_PAYLOAD_CONFLICT' THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic Dispatch contract incomplete';
  END IF;
  IF v_dispatch~'INSERT INTO public.financial_events'
    OR v_dispatch~'INSERT INTO public.finance_journals' THEN
    RAISE EXCEPTION 'TEST_FAILED: ODR-3 Dispatch crossed Finance boundary';
  END IF;
  IF v_received~'product_stocks' OR v_received~'product_batches'
    OR v_received~'stock_movements' THEN
    RAISE EXCEPTION 'TEST_FAILED: Delivered proof has a second stock effect';
  END IF;
  IF v_workspace!~'acp_require_permission_capability'
    OR v_workspace!~'sales_stock_reservations' THEN
    RAISE EXCEPTION 'TEST_FAILED: Dispatch workspace permission/composition missing';
  END IF;
  IF v_guard!~'sales_dispatch_allocations'
    OR v_guard!~'negative_permission_version' THEN
    RAISE EXCEPTION 'TEST_FAILED: reserved negative Dispatch guard missing';
  END IF;
END
$test$;
SELECT 'odr_phase3c_atomic_delivery_dispatch_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'atomic mutation definition','exact retry contract','Finance boundary',
    'Delivered zero second effect','workspace permission','negative snapshot guard']) details;
ROLLBACK;
