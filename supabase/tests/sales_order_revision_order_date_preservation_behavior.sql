-- Deterministic revision Order-date preservation regression.
-- SAFETY: exercises the pure private date transformer and rolls back.
BEGIN;

DO $test$
DECLARE
  v_source_date TIMESTAMPTZ:='2026-08-28 16:57:51+00'::TIMESTAMPTZ;
  v_payload JSONB;
  v_replay JSONB;
  v_definition TEXT;
BEGIN
  IF to_regprocedure(
      'private.sales_order_revision_date_payload(jsonb,timestamptz,text)') IS NULL
    OR to_regprocedure(
      'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: revision date runtime missing';
  END IF;

  v_payload:=private.sales_order_revision_date_payload(
    jsonb_build_object('transactionAt','2099-01-01T00:00:00Z',
      'transactionDateIntent','CASHIER_SELECTED','marker','kept'),
    v_source_date,'SERVER_CREATED');
  IF (v_payload->>'transactionAt')::TIMESTAMPTZ IS DISTINCT FROM v_source_date
    OR v_payload->>'transactionDateIntent'<>'PRESERVE'
    OR v_payload->>'marker'<>'kept' THEN
    RAISE EXCEPTION 'TEST_FAILED: SERVER_CREATED date was not preserved';
  END IF;
  v_replay:=private.sales_order_revision_date_payload(
    v_payload,v_source_date,'SERVER_CREATED');
  IF v_replay IS DISTINCT FROM v_payload THEN
    RAISE EXCEPTION 'TEST_FAILED: date payload retry is not exact';
  END IF;

  v_payload:=private.sales_order_revision_date_payload(
    '{}'::JSONB,v_source_date,'CASHIER_SELECTED');
  IF (v_payload->>'transactionAt')::TIMESTAMPTZ IS DISTINCT FROM v_source_date
    OR v_payload->>'transactionDateIntent'<>'CASHIER_SELECTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: CASHIER_SELECTED date was not preserved';
  END IF;

  BEGIN
    PERFORM private.sales_order_revision_date_payload(
      '{}'::JSONB,v_source_date,'INVALID');
    RAISE EXCEPTION 'TEST_FAILED: invalid source accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM='TEST_FAILED: invalid source accepted' THEN RAISE; END IF;
    IF SQLERRM<>'SALES_ORDER_REVISION_DATE_IDENTITY_INVALID' THEN RAISE; END IF;
  END;

  SELECT lower(regexp_replace(pg_get_functiondef(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)'::regprocedure),
    '[[:space:]]+','','g')) INTO v_definition;
  IF position('transaction_date=v_source.transaction_date' IN v_definition)=0
    OR position('transaction_date_source=v_source.transaction_date_source'
      IN v_definition)=0
    OR position('transaction_date_selected_by=v_source.transaction_date_selected_by'
      IN v_definition)=0
    OR position('transaction_date_selected_at=v_source.transaction_date_selected_at'
      IN v_definition)=0
    OR position('sales_order_revision_date_payload' IN v_definition)=0
    OR position('created_at=v_source.created_at' IN v_definition)>0
    OR position('posted_at=v_source.posted_at' IN v_definition)>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: revision lifecycle/date boundary invalid';
  END IF;
END
$test$;

SELECT 'sales_order_revision_order_date_preservation_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'SERVER_CREATED Order date preservation',
    'CASHIER_SELECTED Order date preservation',
    'stale payload date replacement',
    'exact helper retry',
    'invalid date-source rejection',
    'replacement creation and posting timestamps remain independent']) details;

ROLLBACK;

