-- ODR-6A: protect Sales Order cancellation after Payment capture.
-- A pending/verified Payment must be resolved by Finance before reservation,
-- Delivery, and procurement demand may be canceled.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828260000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5F required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828270000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828270000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    JOIN public.sales_headers sale ON sale.company_id=request.company_id
      AND sale.id=request.sales_id
    WHERE sale.order_runtime_status='CANCELED'
      AND request.status IN('PENDING','VERIFIED')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canceled Order with unresolved Payment';
  END IF;
END
$guard$;

ALTER FUNCTION public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT)
  RENAME TO odr6a_cancel_pos_sales_order_legacy;
ALTER FUNCTION public.odr6a_cancel_pos_sales_order_legacy(UUID,BIGINT,UUID,TEXT)
  SET SCHEMA private;

CREATE FUNCTION public.cancel_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company AND request.sales_id=p_sales_id
      AND request.status IN('PENDING','VERIFIED')) THEN
    RAISE EXCEPTION 'SALES_ORDER_PAYMENT_RESOLUTION_REQUIRED';
  END IF;
  RETURN private.odr6a_cancel_pos_sales_order_legacy(
    p_sales_id,p_master_version,p_idempotency_key,p_reason);
END
$$;

REVOKE ALL ON FUNCTION
  private.odr6a_cancel_pos_sales_order_legacy(UUID,BIGINT,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.odr6a_cancel_pos_sales_order_legacy(UUID,BIGINT,UUID,TEXT)
TO service_role;
REVOKE ALL ON FUNCTION
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828270000','odr_phase6a_pos_order_cutover_guard',
  'Block Sales Order cancellation while Payment verification is PENDING or VERIFIED; Finance rejection/reversal or no captured Payment is required before Reservation, Delivery and Procurement cancellation');

NOTIFY pgrst,'reload schema';
COMMIT;
