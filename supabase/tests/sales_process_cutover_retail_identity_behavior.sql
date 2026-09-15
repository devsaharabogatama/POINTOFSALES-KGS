-- Rollback-only behavior for 20260910130000.
BEGIN;
DO $test$
DECLARE v_result jsonb;v_uuid uuid:=gen_random_uuid();v_blocked boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910130000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260910130000 required';
  END IF;

  IF NOT private.sales_process_retail_identity_is_valid(
      'POS','RETAIL_CONFIRM_INVOICE',v_uuid,v_uuid,v_uuid)
    OR private.sales_process_retail_identity_is_valid(
      'POS','RETAIL_CONFIRM_INVOICE',NULL,v_uuid,v_uuid)
    OR NOT private.sales_process_retail_identity_is_valid(
      'BACKOFFICE_CUTOVER','RETAIL_CONFIRM_INVOICE',NULL,NULL,NULL)
    OR private.sales_process_retail_identity_is_valid(
      'BACKOFFICE_CUTOVER','RETAIL_CONFIRM_INVOICE',v_uuid,NULL,NULL)
    OR private.sales_process_retail_identity_is_valid(
      'BACKOFFICE_CUTOVER','BACKOFFICE_DELIVERED_QTY_INVOICE',NULL,NULL,NULL) THEN
    RAISE EXCEPTION 'TEST_FAILED: conditional Retail identity contract invalid';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    false,false,false,false,false,true,false);
  IF v_result->>'decision'<>'BLOCKED'
    OR NOT (v_result->'blockerCodes' ? 'PENDING_REVISION_MUST_RESOLVE')
    OR v_result->'requirementCodes' ? 'CONVERT_REVISION_PAIR' THEN
    RAISE EXCEPTION 'TEST_FAILED: pending Retail revision was not grandfathered';
  END IF;

  v_result:=private.classify_sales_process_conversion_candidate(
    'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,
    false,false,false,false,true,false,true);
  IF v_result->>'decision'<>'CONVERT'
    OR NOT (v_result->'requirementCodes' ? 'FORMAL_CANCEL_SOURCE_INVOICE')
    OR NOT (v_result->'requirementCodes' ? 'TRANSFER_PROCUREMENT_LINEAGE')
    OR jsonb_array_length(v_result->'blockerCodes')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: eligible conversion requirements drift';
  END IF;

  BEGIN
    PERFORM private.classify_sales_process_conversion_candidate(
      'RETAIL_CONFIRM_INVOICE','RETAIL_CONFIRM_INVOICE',false,
      false,false,false,false,false,false,false);
  EXCEPTION WHEN OTHERS THEN
    v_blocked:=SQLERRM LIKE '%SALES_PROCESS_CONVERSION_MODE_INVALID%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: same-mode conversion accepted';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'sales_process_cutover_retail_identity_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'normal POS requires Cashier Session POS and created Session identities',
    'BACKOFFICE_CUTOVER Retail identity accepts no fabricated POS context',
    'BACKOFFICE_CUTOVER rejects mixed or wrong-mode identity',
    'pending Retail revision is BLOCKED and grandfathered',
    'eligible Invoice and Procurement requirements remain classified',
    'same-mode conversion rejected','no fixture writes committed']) details;
