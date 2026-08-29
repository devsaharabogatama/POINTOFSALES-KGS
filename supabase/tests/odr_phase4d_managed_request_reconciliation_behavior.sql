-- ODR-4D fixture-free managed request behavior. Always rolled back.
BEGIN;
DO $test$
DECLARE v_count INTEGER;v_definition TEXT;
BEGIN
  SELECT count(*) INTO v_count FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname IN('reconcile_session_procurement_request',
      'odr4d_refresh_procurement_demand_core',
      'refresh_sales_order_procurement_demand',
      'odr4d_get_purchase_supplier_orders_core')
    AND NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE');
  IF v_count<>4 THEN
    RAISE EXCEPTION 'TEST_FAILED: private reconciliation boundary invalid';
  END IF;

  SELECT procedure.prosrc INTO v_definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='refresh_sales_order_procurement_demand';
  IF v_definition NOT LIKE '%odr4d_refresh_procurement_demand_core%'
    OR v_definition NOT LIKE '%reconcile_session_procurement_request%' THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic demand-request chain missing';
  END IF;

  SELECT procedure.prosrc INTO v_definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='reconcile_session_procurement_request';
  IF v_definition LIKE '%UPDATE public.supplier_order_documents%'
    OR v_definition LIKE '%INSERT INTO public.supplier_order_documents%'
    OR v_definition LIKE '%DELETE FROM public.supplier_order_documents%'
    OR v_definition LIKE '%UPDATE public.supplier_order_lines%'
    OR v_definition LIKE '%INSERT INTO public.supplier_order_lines%'
    OR v_definition LIKE '%DELETE FROM public.supplier_order_lines%'
    OR v_definition LIKE '%UPDATE public.supplier_order_request_allocations%'
    OR v_definition LIKE '%INSERT INTO public.supplier_order_request_allocations%'
    OR v_definition LIKE '%DELETE FROM public.supplier_order_request_allocations%'
    OR v_definition LIKE '%product_stocks%'
    OR v_definition LIKE '%product_batches%'
    OR v_definition LIKE '%stock_movements%'
    OR v_definition LIKE '%financial_events%' THEN
    RAISE EXCEPTION 'TEST_FAILED: reconciliation crossed protected boundary';
  END IF;

  SELECT procedure.prosrc INTO v_definition
  FROM pg_proc procedure JOIN pg_namespace namespace
    ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='public'
    AND procedure.proname='get_purchase_supplier_orders';
  IF v_definition NOT LIKE '%line.is_active%' THEN
    RAISE EXCEPTION 'TEST_FAILED: inactive request line remained visible';
  END IF;
END
$test$;
SELECT 'odr_phase4d_managed_request_reconciliation_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'private boundary','atomic demand-request reconciliation',
    'no PO Stock Finance mutation','inactive request-line read filter']) details;
ROLLBACK;
