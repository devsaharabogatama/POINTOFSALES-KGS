-- ODR-4D fixture-free amendment foundation behavior. Always rolled back.
BEGIN;
DO $test$
DECLARE v_count INTEGER;
BEGIN
  SELECT count(*) INTO v_count FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname='private'
    AND procedure.proname IN('trg_odr_guard_procurement_amendment',
      'trg_odr_guard_procurement_amendment_audit')
    AND NOT has_function_privilege('authenticated',procedure.oid,'EXECUTE');
  IF v_count<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: private amendment trigger boundary invalid';
  END IF;
  IF has_table_privilege('authenticated',
      'public.sales_order_procurement_amendments','SELECT')
    OR has_table_privilege('authenticated',
      'public.sales_order_procurement_amendments','INSERT')
    OR has_table_privilege('authenticated',
      'public.sales_order_procurement_amendment_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: browser amendment table boundary invalid';
  END IF;
END
$test$;
SELECT 'odr_phase4d_amendment_foundation_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY['private trigger boundary',
    'browser table closure','zero-write fixture-free execution']) details;
ROLLBACK;
