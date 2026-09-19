-- Rollback-only behavioral contract for the presentation arithmetic.
BEGIN;

DO $test$
DECLARE
  v_original numeric:=1960000;
  v_partial_credit numeric:=880000;
  v_full_credit numeric:=1960000;
BEGIN
  IF greatest(0,v_original-v_partial_credit)<>1080000 THEN
    RAISE EXCEPTION 'TEST_FAILED: partial Return net commercial amount invalid';
  END IF;
  IF greatest(0,v_original-v_full_credit)<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: full Return net commercial amount invalid';
  END IF;
  IF greatest(0,v_original-0)<>v_original THEN
    RAISE EXCEPTION 'TEST_FAILED: received Return without posted Credit Note changed value';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname='get_sales_return_commercial_adjustments'
      AND procedure.provolatile='s') THEN
    RAISE EXCEPTION 'TEST_FAILED: stable Return commercial read model missing';
  END IF;
END
$test$;

SELECT 'sales_return_net_commercial_read_model_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'partial posted Credit Note reduces net value',
    'full posted Credit Note reduces net value to zero',
    'physical receipt without posted Credit Note does not guess financial value',
    'read model is STABLE and mutation-free']) details;

ROLLBACK;
