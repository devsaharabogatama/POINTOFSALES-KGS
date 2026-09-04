-- Deterministic revision Order-date authority regression. No business rows.
BEGIN;
DO $test$
DECLARE
  v_actor UUID:='00000000-0000-0000-0000-000000000123'::UUID;
  v_header TIMESTAMPTZ:='2026-08-28 20:35:53+00'::TIMESTAMPTZ;
  v_planned TIMESTAMPTZ:='2026-09-03 20:35:00+00'::TIMESTAMPTZ;
  v_delivery TIMESTAMPTZ:='2026-09-04 02:00:00+00'::TIMESTAMPTZ;
  v_scheduled JSONB;v_immediate JSONB;v_backorder JSONB;
  v_save JSONB;v_final JSONB;
  v_rejected BOOLEAN:=FALSE;
BEGIN
  v_scheduled:=private.resolve_sales_order_revision_date_identity(
    jsonb_build_object('order_timing_mode','SCHEDULED',
      'transaction_date',v_header,'transaction_date_source','SERVER_CREATED',
      'planned_order_date','2026-09-04','planned_order_selected_by',v_actor,
      'planned_order_selected_at','2026-08-28 20:35:53+00'::TIMESTAMPTZ,
      'payload_snapshot',jsonb_build_object('plannedOrderAt',v_planned)),
    'Asia/Jakarta');
  IF (v_scheduled->>'transactionAt')::TIMESTAMPTZ IS DISTINCT FROM v_planned
    OR v_scheduled->>'transactionDateSource'<>'CASHIER_SELECTED'
    OR v_scheduled->>'orderTimingMode'<>'SCHEDULED'
    OR (v_scheduled->>'plannedOrderDate')::DATE<>'2026-09-04'::DATE THEN
    RAISE EXCEPTION 'TEST_FAILED: Scheduled source did not resolve planned Order date';
  END IF;

  v_immediate:=private.resolve_sales_order_revision_date_identity(
    jsonb_build_object('order_timing_mode','IMMEDIATE',
      'transaction_date',v_header,'transaction_date_source','SERVER_CREATED'),
    'Asia/Jakarta');
  IF (v_immediate->>'transactionAt')::TIMESTAMPTZ IS DISTINCT FROM v_header
    OR v_immediate->>'transactionDateSource'<>'SERVER_CREATED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Immediate source date changed';
  END IF;

  v_backorder:=private.resolve_sales_order_revision_date_identity(
    jsonb_build_object('order_timing_mode','BACKORDER',
      'transaction_date','2026-08-27 17:00:00+00'::TIMESTAMPTZ,
      'transaction_date_source','CASHIER_SELECTED',
      'transaction_date_selected_by',v_actor,
      'transaction_date_selected_at','2026-08-28 01:00:00+00'::TIMESTAMPTZ,
      'planned_order_date','2026-08-28'),
    'Asia/Jakarta');
  IF (v_backorder->>'transactionAt')::TIMESTAMPTZ IS DISTINCT FROM
      '2026-08-27 17:00:00+00'::TIMESTAMPTZ
    OR v_backorder->>'orderTimingMode'<>'BACKORDER' THEN
    RAISE EXCEPTION 'TEST_FAILED: Backorder source date changed';
  END IF;

  v_save:=private.sales_order_revision_identity_payload(
    jsonb_build_object('marker','kept','deliveryScheduledAt',v_delivery),
    v_scheduled,TRUE);
  v_final:=private.sales_order_revision_identity_payload(v_save,v_scheduled,FALSE);
  IF (v_save->>'transactionAt')::TIMESTAMPTZ IS DISTINCT FROM v_planned
    OR v_save->>'transactionDateIntent'<>'CASHIER_SELECTED'
    OR v_save->>'orderTimingMode'<>'SCHEDULED'
    OR (v_save->>'plannedOrderDate')::DATE<>'2026-09-04'::DATE
    OR (v_save->>'deliveryScheduledAt')::TIMESTAMPTZ IS DISTINCT FROM v_delivery
    OR v_save->>'marker'<>'kept' THEN
    RAISE EXCEPTION 'TEST_FAILED: save payload lost Scheduled Order identity';
  END IF;
  IF (v_final->>'transactionAt')::TIMESTAMPTZ IS DISTINCT FROM v_planned
    OR v_final->>'transactionDateIntent'<>'CASHIER_SELECTED'
    OR v_final->>'plannedOrderAt' IS NULL
    OR (v_final->>'deliveryScheduledAt')::TIMESTAMPTZ IS DISTINCT FROM v_delivery THEN
    RAISE EXCEPTION 'TEST_FAILED: final Scheduled identity not preserved';
  END IF;
  IF private.sales_order_revision_identity_payload(
      v_save,v_scheduled,TRUE) IS DISTINCT FROM v_save THEN
    RAISE EXCEPTION 'TEST_FAILED: resolved save payload retry is not exact';
  END IF;

  BEGIN
    PERFORM private.resolve_sales_order_revision_date_identity(
      jsonb_build_object('order_timing_mode','SCHEDULED',
        'transaction_date',v_header,'transaction_date_source','SERVER_CREATED',
        'planned_order_date','2026-09-05','planned_order_selected_by',v_actor,
        'planned_order_selected_at',v_header,'payload_snapshot',
          jsonb_build_object('plannedOrderAt',v_planned)),
      'Asia/Jakarta');
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='SALES_ORDER_REVISION_SCHEDULED_DATE_MISMATCH' THEN
      v_rejected:=TRUE;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: inconsistent Scheduled identity accepted';
  END IF;

  IF to_regprocedure(
      'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)') IS NULL
    OR to_regprocedure(
      'private.build_confirmed_order_invoice_snapshot(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: revision or Invoice runtime missing';
  END IF;
END
$test$;
SELECT 'sales_order_revision_transient_date_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'Scheduled resolves planned Order timestamp instead of header creation date',
    'Immediate and Backorder preserve their canonical header date',
    'inconsistent Scheduled identity fails closed',
    'revision save payload receives the original Order timestamp',
    'delivery schedule survives revision payload transformation',
    'replacement preserves source timing classification',
    'resolved payload retry is exact',
    'revision and Invoice runtime dependencies exist']) details;
ROLLBACK;
