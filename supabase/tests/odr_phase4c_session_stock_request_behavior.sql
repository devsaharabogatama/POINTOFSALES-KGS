-- ODR-4C fixture-free runtime contract behavior. Always rolled back.
BEGIN;
DO $test$
DECLARE v_count INTEGER;v_definition TEXT;
BEGIN
  SELECT count(*) INTO v_count FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname IN('ensure_session_procurement_stock_request',
      'odr4c_close_cashier_session_legacy')
    AND NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE');
  IF v_count<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: private Session request boundary invalid';
  END IF;

  SELECT pg_get_functiondef(procedure.oid) INTO v_definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='close_cashier_session';
  IF v_definition NOT LIKE '%odr4c_close_cashier_session_legacy%'
    OR v_definition NOT LIKE '%ensure_session_procurement_stock_request%' THEN
    RAISE EXCEPTION 'TEST_FAILED: Session close request chain missing';
  END IF;

  SELECT pg_get_functiondef(procedure.oid) INTO v_definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='ensure_session_procurement_stock_request';
  IF v_definition LIKE '%supplier_order_documents%'
    OR v_definition LIKE '%supplier_order_lines%'
    OR v_definition LIKE '%product_stocks%'
    OR v_definition LIKE '%product_batches%'
    OR v_definition LIKE '%stock_movements%'
    OR v_definition LIKE '%financial_events%'
    OR v_definition LIKE '%canonical_journals%' THEN
    RAISE EXCEPTION 'TEST_FAILED: ODR-4C crossed PO, Stock or Finance boundary';
  END IF;

  BEGIN
    UPDATE public.stock_request_documents SET status='CANCELED'
    WHERE request_source='SALES_ORDER_RESERVATION'
      AND status='SUBMITTED';
    IF FOUND THEN
      RAISE EXCEPTION 'TEST_FAILED: managed request cancellation was accepted';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%MANAGED_RESERVATION_STOCK_REQUEST_CANNOT_BE_CANCELED%'
      AND SQLERRM NOT LIKE '%TEST_FAILED:%' THEN RAISE; END IF;
    IF SQLERRM LIKE '%TEST_FAILED:%' THEN RAISE; END IF;
  END;
END
$test$;
SELECT 'odr_phase4c_session_stock_request_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'private runtime boundary','atomic Session-close projection chain',
    'no PO Stock Finance mutation','managed request cancel guard']) details;
ROLLBACK;

