-- ODR-4E fixture-free structural behavior. Always rolled back.
BEGIN;
DO $test$
DECLARE v_count INTEGER;v_definition TEXT;
BEGIN
  SELECT count(*) INTO v_count FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private' AND procedure.proname IN(
    'sync_managed_request_single_draft_po',
    'odr4e_refresh_procurement_demand_core',
    'refresh_sales_order_procurement_demand')
    AND NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE');
  IF v_count<>3 THEN
    RAISE EXCEPTION 'TEST_FAILED: private Draft PO sync boundary invalid';
  END IF;

  SELECT procedure.prosrc INTO v_definition FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='refresh_sales_order_procurement_demand';
  IF v_definition NOT LIKE '%odr4e_refresh_procurement_demand_core%'
    OR v_definition NOT LIKE '%sync_managed_request_single_draft_po%' THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic request-to-Draft-PO chain missing';
  END IF;

  SELECT procedure.prosrc INTO v_definition FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname='sync_managed_request_single_draft_po';
  IF v_definition NOT LIKE '%order_document.status=''DRAFT''%'
    OR v_definition NOT LIKE '%v_line_allocated<>v_target.ordered_base_qty%'
    OR v_definition NOT LIKE '%DRAFT_UOM_CONVERSION_REQUIRES_REVIEW%'
    OR v_definition NOT LIKE '%supplier_order_audit%'
    OR v_definition LIKE '%UPDATE public.product_stocks%'
    OR v_definition LIKE '%INSERT INTO public.stock_movements%'
    OR v_definition LIKE '%INSERT INTO public.financial_events%'
    OR v_definition LIKE '%INSERT INTO public.canonical_journal%'
    OR v_definition LIKE '%UPDATE public.supplier_order_documents SET status%' THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft PO sync protected boundary invalid';
  END IF;
END
$test$;
SELECT 'odr_phase4e_single_draft_po_sync_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'private routine boundary','atomic reconciliation hook',
    'single fully allocation-backed Draft target','UOM precision review',
    'no final PO Stock FIFO Movement or Finance mutation']) details;
ROLLBACK;
