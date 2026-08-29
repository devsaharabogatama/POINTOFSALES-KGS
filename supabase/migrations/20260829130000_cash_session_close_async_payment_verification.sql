-- Allow Cashier session close while Finance payment verification remains asynchronous.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended(
  '20260829130000_cash_session_close_async_payment_verification',0));

DO $$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260829130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828240000')
    OR to_regprocedure('public.close_cashier_session(uuid,bigint,numeric)') IS NULL
    OR to_regprocedure(
      'private.odr5d_close_cashier_session_legacy(uuid,bigint,numeric)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5D close runtime required';
  END IF;
  IF pg_get_functiondef(
      'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure)
      !~'odr5d_close_cashier_session_legacy' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: close runtime drift';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.close_cashier_session(
  p_cashier_session_id UUID,p_master_version BIGINT,
  p_closing_cash_actual NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_pending BIGINT;v_result JSONB;
BEGIN
  SELECT count(*) INTO v_pending
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=v_company
    AND request.cashier_session_id=p_cashier_session_id
    AND request.status='PENDING';

  -- Payment review and Journal posting are asynchronous Finance work. Cash is
  -- already represented exactly once by SALE_PAYMENT_INTENT drawer movement.
  v_result:=private.odr5d_close_cashier_session_legacy(
    p_cashier_session_id,p_master_version,p_closing_cash_actual);
  RETURN v_result||jsonb_build_object(
    'paymentVerificationDeferred',v_pending>0,
    'pendingPaymentVerificationCount',v_pending);
END
$$;

REVOKE ALL ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260829130000','cash_session_close_async_payment_verification',
  'Remove real-time Finance payment-verification dependency from Cashier session close; preserve exact-once drawer movement, closing count, procurement projection, pending Finance queue, audit and controlled Journal posting');

NOTIFY pgrst,'reload schema';
COMMIT;
