-- Rollback-only classifier behavior for 20260910140000.
BEGIN;
DO $test$
DECLARE v_result jsonb;v_rejected boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910140000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260910140000 required';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    false,false,false,false,false,false,true);
  IF v_result->>'decision'<>'BLOCKED'
    OR NOT (v_result->'blockerCodes' ? 'OPEN_PROCUREMENT_MUST_FINISH')
    OR jsonb_array_length(v_result->'requirementCodes')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: open procurement candidate was not grandfathered';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    true,false,false,false,true,true,true);
  IF v_result->>'decision'<>'BLOCKED'
    OR NOT (v_result->'blockerCodes' ? 'DISPATCH_STARTED')
    OR NOT (v_result->'blockerCodes' ? 'PENDING_REVISION_MUST_RESOLVE')
    OR NOT (v_result->'blockerCodes' ? 'OPEN_PROCUREMENT_MUST_FINISH')
    OR jsonb_array_length(v_result->'requirementCodes')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: combined blockers were not retained';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'BACKOFFICE_DELIVERED_QTY_INVOICE','RETAIL_CONFIRM_INVOICE',false,
    false,false,false,false,true,false,false);
  IF v_result->>'decision'<>'CONVERT'
    OR NOT (v_result->'requirementCodes' ? 'FORMAL_CANCEL_SOURCE_INVOICE')
    OR jsonb_array_length(v_result->'blockerCodes')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: clean conversion classification drift';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'BACKOFFICE_DELIVERED_QTY_INVOICE','RETAIL_CONFIRM_INVOICE',true,
    false,false,false,false,false,false,true);
  IF v_result->>'decision'<>'KEEP_SOURCE'
    OR jsonb_array_length(v_result->'blockerCodes')<>0
    OR jsonb_array_length(v_result->'requirementCodes')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: final source classification drift';
  END IF;

  BEGIN
    PERFORM private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','RETAIL_CONFIRM_INVOICE',false,
      false,false,false,false,false,false,false);
  EXCEPTION WHEN OTHERS THEN
    v_rejected:=SQLERRM LIKE '%SALES_PROCESS_CONVERSION_MODE_INVALID%';
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: same-mode conversion accepted';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'sales_process_cutover_procurement_blocker_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'open procurement is BLOCKED and grandfathered',
    'dispatch revision and procurement blockers coexist',
    'blocked candidates receive no conversion requirements',
    'clean issued-Invoice candidate retains formal cancellation requirement',
    'final source remains KEEP_SOURCE','same-mode conversion rejected',
    'no fixture writes committed']) details;
