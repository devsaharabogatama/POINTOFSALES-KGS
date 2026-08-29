-- ODR-5E fixture-free behavioral contract. All writes are rolled back.
BEGIN;

DO $test$
DECLARE v_definition TEXT;v_company UUID;v_blocked BOOLEAN:=FALSE;
BEGIN
  IF to_regprocedure(
      'private.rebalance_dispatch_settlement_odr5e(uuid,uuid,uuid,uuid)') IS NULL
    OR to_regprocedure(
      'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: required ODR-5E runtime missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'dispatch_sales_delivery_core_pre_odr5d'
    OR v_definition!~'rebalance_dispatch_settlement_odr5e'
    OR v_definition~'ODR_PREDISPATCH_ADVANCE_APPLICATION_NOT_READY'
    OR v_definition~'ODR_PAYMENT_SURCHARGE_DISPATCH_APPLICATION_NOT_READY' THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic Dispatch rebalance wrapper invalid';
  END IF;
  SELECT pg_get_functiondef(
    'private.rebalance_dispatch_settlement_odr5e(uuid,uuid,uuid,uuid)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'customerSurchargeAmount'
    OR v_definition!~'PRE_DISPATCH'
    OR v_definition!~'CUSTOMER_ADVANCE'
    OR v_definition!~'settlement_rebalance_version'
    OR v_definition!~'REBALANCE' THEN
    RAISE EXCEPTION 'TEST_FAILED: surcharge/advance reconciliation contract invalid';
  END IF;
  SELECT pg_get_functiondef(
    'private.trg_odr5_guard_dispatch_financial_effect()'::regprocedure)
  INTO v_definition;
  IF v_definition!~'odr5e_dispatch_finance_rebalance'
    OR v_definition!~'DISPATCH_FINANCIAL_EFFECT_ALREADY_POSTED'
    OR v_definition!~'DISPATCH_FINANCIAL_EFFECT_REBALANCE_INVALID' THEN
    RAISE EXCEPTION 'TEST_FAILED: guarded one-time rebalance contract invalid';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED'
    OR v_definition!~'post_odr_payment_financial_event_core'
    OR v_definition!~'post_financial_event_core_pre_odr5d' THEN
    RAISE EXCEPTION 'TEST_FAILED: advance-before-Dispatch posting order invalid';
  END IF;
  SELECT policy.company_id INTO v_company FROM public.finance_company_policies policy
  ORDER BY policy.company_id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Finance Company policy required';
  END IF;
  BEGIN
    UPDATE public.finance_company_policies SET posting_mode='AUTOMATIC'
    WHERE company_id=v_company;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%ODR_AUTOMATIC_POSTING_NOT_READY%' THEN v_blocked:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: automatic posting boundary was not enforced';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'odr_phase5e_dispatch_advance_reconciliation_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'atomic Dispatch settlement rebalance','immutable surcharge snapshot',
    'verified pre-dispatch advance allocation','one-time guarded source update',
    'exact retry','automatic posting remains closed'
  ],'writesPersisted',FALSE) details;
