-- Rollback-only regression for the authenticated deferred-trigger boundary.
-- It deliberately queues the existing non-cash guard as postgres, then forces
-- deferred execution as authenticated. Before 20261102140000 this exact step
-- fails with permission denied for sales_payment_verification_requests.
BEGIN;

DO $fixture$
DECLARE v_request public.sales_payment_verification_requests%rowtype;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261102140000')<>1 THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: deferred guard privilege migration missing';
  END IF;
  SELECT request.* INTO v_request
  FROM public.sales_payment_verification_requests request
  WHERE request.status='PENDING'
    AND request.settlement_route_snapshot IN('DIRECT_BANK','CLEARING')
  ORDER BY request.requested_at,request.id LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: pending non-cash request required';
  END IF;
  PERFORM set_config('pos.guard.test.request',v_request.id::text,true);
  PERFORM set_config('pos.guard.test.company',v_request.company_id::text,true);
  PERFORM set_config('pos.guard.test.actor',v_request.requested_by::text,true);
  PERFORM set_config('kgs.odr5_payment_verification_mutation','1',true);
  UPDATE public.sales_payment_verification_requests
  SET status=status
  WHERE company_id=v_request.company_id AND id=v_request.id;
  PERFORM set_config('kgs.odr5_payment_verification_mutation','',true);
END
$fixture$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub',current_setting('pos.guard.test.actor'),'role','authenticated')::text,true);
SELECT set_config('request.jwt.claim.sub',
  current_setting('pos.guard.test.actor'),true);
SELECT public.set_active_company_context(
  current_setting('pos.guard.test.company')::uuid,'F4A_TEST');
SET CONSTRAINTS enforce_no_pending_pos_cash IMMEDIATE;
SET CONSTRAINTS enforce_no_pending_pos_cash DEFERRED;
RESET ROLE;

ROLLBACK;

SELECT 'pos_retail_non_cash_deferred_guard_privilege_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'installed exact forward migration',
    'pending non-cash request under unchanged status',
    'deferred trigger forced as authenticated cashier',
    'no direct verification-table privilege granted',
    'guard body and trigger timing preserved',
    'all test effects rolled back')) details;
