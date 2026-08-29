-- ODR-4B fixture-free runtime contract behavior. Always rolled back.
BEGIN;
DO $test$
DECLARE v_count INTEGER;v_definition TEXT;
BEGIN
  SELECT count(*) INTO v_count FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname IN('refresh_sales_order_procurement_demand',
      'freeze_session_procurement_demand','odr4b_close_cashier_session_legacy')
    AND NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE');
  IF v_count<>3 THEN
    RAISE EXCEPTION 'TEST_FAILED: private procurement runtime boundary invalid';
  END IF;

  SELECT pg_get_functiondef(procedure.oid) INTO v_definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public' AND procedure.proname='confirm_pos_sales_order';
  IF v_definition NOT LIKE '%ensure_confirmed_order_documents%'
    OR v_definition NOT LIKE '%refresh_sales_order_procurement_demand%' THEN
    RAISE EXCEPTION 'TEST_FAILED: confirm atomic document/demand chain missing';
  END IF;

  IF NOT has_function_privilege('authenticated',
    'public.get_purchase_procurement_demands()','EXECUTE')
    OR has_function_privilege('anon',
      'public.get_purchase_procurement_demands()','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: procurement composed read boundary invalid';
  END IF;
END
$test$;
SELECT 'odr_phase4b_session_procurement_demand_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'private core boundary','atomic Confirm document-demand chain',
    'Purchasing composed read RPC boundary']) details;
ROLLBACK;
