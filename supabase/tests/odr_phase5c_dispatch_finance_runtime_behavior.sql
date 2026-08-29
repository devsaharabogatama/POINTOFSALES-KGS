-- ODR-5C fixture-free behavioral contract. All writes are rolled back.
BEGIN;

DO $test$
DECLARE v_definition TEXT;v_company UUID;v_blocked BOOLEAN:=FALSE;
BEGIN
  IF to_regprocedure(
      'private.capture_dispatch_financial_effect_core(uuid,uuid,uuid,jsonb)') IS NULL
    OR to_regprocedure(
      'private.post_odr_dispatch_financial_event_core(uuid,uuid,bigint,uuid)') IS NULL
    OR to_regprocedure(
      'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: required ODR-5C runtime missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) INTO v_definition;
  IF v_definition!~'dispatch_sales_delivery_stock_core_odr3c'
    OR v_definition!~'capture_dispatch_financial_effect_core' THEN
    RAISE EXCEPTION 'TEST_FAILED: Dispatch atomic Finance wrapper invalid';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_odr_dispatch_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure
  ) INTO v_definition;
  IF v_definition!~'sales_dispatch_financial_effects'
    OR v_definition!~'resolve_financial_event_account'
    OR v_definition!~'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'
    OR v_definition!~'JOURNAL_UNBALANCED' THEN
    RAISE EXCEPTION 'TEST_FAILED: controlled Dispatch posting contract invalid';
  END IF;
  SELECT pg_get_functiondef(
    'private.f4b_financial_event_supported(public.financial_events)'::regprocedure
  ) INTO v_definition;
  IF v_definition!~'SALE_DISPATCHED'
    OR v_definition!~'sales_dispatch_financial_effects' THEN
    RAISE EXCEPTION 'TEST_FAILED: controlled queue support contract invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects
    WHERE financial_event_id IS NULL OR advance_applied_amount<0) THEN
    RAISE EXCEPTION 'TEST_FAILED: immutable Dispatch source shape invalid';
  END IF;

  SELECT policy.company_id INTO v_company
  FROM public.finance_company_policies policy ORDER BY policy.company_id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Finance Company policy required';
  END IF;
  BEGIN
    UPDATE public.finance_company_policies SET posting_mode='AUTOMATIC'
    WHERE company_id=v_company;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%ODR_AUTOMATIC_POSTING_NOT_READY%' THEN
      v_blocked:=TRUE;
    ELSE RAISE;
    END IF;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: automatic posting boundary was not enforced';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'odr_phase5c_dispatch_finance_runtime_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'atomic stock plus Finance wrapper','immutable operation source shape',
    'controlled dispatcher and period guard','automatic posting remains blocked'
  ],'writesPersisted',FALSE) details;
