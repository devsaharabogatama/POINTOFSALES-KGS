-- ODR-4A foundation behavioral boundary. Always rolled back.
BEGIN;
DO $test$
DECLARE v_denied BOOLEAN:=FALSE;v_scope_guard BOOLEAN:=FALSE;
  v_error TEXT;
BEGIN
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO public.sales_order_procurement_demands(
      company_id,store_id,warehouse_id,cashier_session_id,status,
      created_by)
    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      gen_random_uuid(),'OPEN',gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege THEN v_denied:=TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_denied THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated procurement demand write allowed';
  END IF;

  BEGIN
    INSERT INTO public.sales_order_procurement_demands(
      company_id,store_id,warehouse_id,cashier_session_id,status,
      created_by)
    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      gen_random_uuid(),'OPEN',gen_random_uuid());
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    v_scope_guard:=v_error='PROCUREMENT_DEMAND_SESSION_SCOPE_MISMATCH';
  END;
  IF NOT v_scope_guard THEN
    RAISE EXCEPTION 'TEST_FAILED: procurement demand Session scope guard missing';
  END IF;
END
$test$;
SELECT 'odr_phase4a_procurement_demand_foundation_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'authenticated write denial','Session scope mismatch denial']) details;
ROLLBACK;
