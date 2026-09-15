-- Step 1E-B2/6 rollback-only behavior for the Payment Term classifier.
-- Run only after migration 20260910152000 on isolated Development.
BEGIN;

DO $test$
DECLARE v_result jsonb;
BEGIN
  v_result:=private.classify_sales_process_conversion_candidate(
    'BACKOFFICE_DELIVERED_QTY_INVOICE','RETAIL_CONFIRM_INVOICE',false,
    false,false,false,false,false,false,false,false);
  IF v_result->>'decision'<>'CONVERT' OR jsonb_array_length(v_result->'blockerCodes')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: single-schedule Office candidate must remain convertible';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'BACKOFFICE_DELIVERED_QTY_INVOICE','RETAIL_CONFIRM_INVOICE',false,
    false,false,false,false,true,false,false,true);
  IF v_result->>'decision'<>'BLOCKED'
    OR NOT (v_result->'blockerCodes' ? 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE')
    OR jsonb_array_length(v_result->'requirementCodes')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: multi-installment Office candidate was not blocked cleanly';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'BACKOFFICE_DELIVERED_QTY_INVOICE','RETAIL_CONFIRM_INVOICE',false,
    true,false,false,false,false,false,false,true);
  IF v_result->>'decision'<>'BLOCKED'
    OR NOT (v_result->'blockerCodes' ? 'DISPATCH_STARTED')
    OR NOT (v_result->'blockerCodes' ? 'MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE') THEN
    RAISE EXCEPTION 'TEST_FAILED: combined blocker evidence was not preserved';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    false,false,false,false,false,false,false);
  IF v_result->>'decision'<>'CONVERT' THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy 10-argument classifier compatibility drift';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    false,false,false,false,false,false,true);
  IF v_result->>'decision'<>'BLOCKED'
    OR NOT (v_result->'blockerCodes' ? 'OPEN_PROCUREMENT_MUST_FINISH') THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy procurement blocker drift';
  END IF;
END
$test$;

SELECT 'sales_process_cutover_payment_term_boundary_behavior' check_name,
  'PASS' status,0::bigint violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'Office single schedule remains convertible',
    'Office multi installment is blocked',
    'combined blocker evidence is retained',
    'legacy classifier signature remains compatible',
    'legacy procurement blocker remains enforced'),
    'fixtureWrites',0,'transactionEnd','ROLLBACK') details;

ROLLBACK;

