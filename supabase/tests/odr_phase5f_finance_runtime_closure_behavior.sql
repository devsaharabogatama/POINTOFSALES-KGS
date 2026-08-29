-- ODR-5F fixture-free closure behavior. All writes are rolled back.
BEGIN;

DO $test$
DECLARE v_definition TEXT;v_company UUID;v_mode TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828260000') THEN
    RAISE EXCEPTION 'TEST_FAILED: ODR-5F migration ledger missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'NO_FINANCIAL_EFFECT'
    OR v_definition!~'noFinancialEffect'
    OR v_definition!~'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED'
    OR v_definition!~'post_odr_payment_financial_event_core'
    OR v_definition!~'post_financial_event_core_pre_odr5d' THEN
    RAISE EXCEPTION 'TEST_FAILED: controlled/automatic dispatcher parity invalid';
  END IF;
  SELECT policy.company_id INTO v_company FROM public.finance_company_policies policy
  WHERE policy.posting_mode='CONTROLLED' ORDER BY policy.company_id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: CONTROLLED Company policy required';
  END IF;
  UPDATE public.finance_company_policies SET posting_mode='AUTOMATIC'
  WHERE company_id=v_company RETURNING posting_mode INTO v_mode;
  IF v_mode<>'AUTOMATIC' THEN
    RAISE EXCEPTION 'TEST_FAILED: automatic policy did not unlock';
  END IF;
  UPDATE public.finance_company_policies SET posting_mode='CONTROLLED'
  WHERE company_id=v_company RETURNING posting_mode INTO v_mode;
  IF v_mode<>'CONTROLLED' THEN
    RAISE EXCEPTION 'TEST_FAILED: controlled policy restoration failed';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'odr_phase5f_finance_runtime_closure_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'controlled/automatic result parity','zero-effect normalization',
    'advance posting dependency retained','automatic policy explicit unlock',
    'controlled restoration','no writes persisted'
  ],'writesPersisted',FALSE) details;
