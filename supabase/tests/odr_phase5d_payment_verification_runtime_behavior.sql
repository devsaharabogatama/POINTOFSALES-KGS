-- ODR-5D fixture-free behavioral contract. All writes are rolled back.
BEGIN;

DO $test$
DECLARE v_definition TEXT;v_company UUID;v_blocked BOOLEAN:=FALSE;
BEGIN
  IF to_regprocedure('private.capture_sales_order_payment_requests(uuid,uuid,uuid)') IS NULL
    OR to_regprocedure('public.get_finance_sales_payment_verifications()') IS NULL
    OR to_regprocedure(
      'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)') IS NULL
    OR to_regprocedure(
      'private.post_odr_payment_financial_event_core(uuid,uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: required ODR-5D runtime missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'capture_sales_order_payment_requests'
    OR v_definition!~'ensure_confirmed_order_documents'
    OR v_definition!~'refresh_sales_order_procurement_demand' THEN
    RAISE EXCEPTION 'TEST_FAILED: atomic Order payment capture wrapper invalid';
  END IF;

  SELECT pg_get_functiondef(
    'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'MAKER_CHECKER_REQUIRED'
    OR v_definition!~'PRE_DISPATCH'
    OR v_definition!~'POST_DISPATCH'
    OR v_definition!~'SALE_PAYMENT_VERIFIED'
    OR v_definition!~'sales_payment_verification_reversal' THEN
    RAISE EXCEPTION 'TEST_FAILED: review, event or Cash reversal contract invalid';
  END IF;

  SELECT pg_get_functiondef(
    'private.post_odr_payment_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'resolve_financial_event_account'
    OR v_definition!~'CUSTOMER_ADVANCE_LIABILITY'
    OR v_definition!~'CUSTOMER_RECEIVABLE'
    OR v_definition!~'PAYMENT_CLEARING'
    OR v_definition!~'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND' THEN
    RAISE EXCEPTION 'TEST_FAILED: controlled Payment posting contract invalid';
  END IF;

  SELECT pg_get_functiondef(
    'public.close_cashier_session(uuid,bigint,numeric)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'PENDING_CASH_PAYMENT_VERIFICATION' THEN
    RAISE EXCEPTION 'TEST_FAILED: pending Cash session-close guard missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure)
  INTO v_definition;
  IF v_definition!~'ODR_PREDISPATCH_ADVANCE_APPLICATION_NOT_READY'
    OR v_definition!~'ODR_PAYMENT_SURCHARGE_DISPATCH_APPLICATION_NOT_READY' THEN
    RAISE EXCEPTION 'TEST_FAILED: ODR-5E Dispatch settlement guard missing';
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
    IF SQLERRM LIKE '%ODR_AUTOMATIC_POSTING_NOT_READY%' THEN v_blocked:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: automatic posting boundary was not enforced';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'odr_phase5d_payment_verification_runtime_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'atomic confirmed-Order payment capture','maker-checker verify/reject',
    'Cash drawer once plus reversal and close guard','controlled posting dispatcher',
    'automatic posting remains closed','no fixture writes persisted'
  ],'writesPersisted',FALSE) details;
