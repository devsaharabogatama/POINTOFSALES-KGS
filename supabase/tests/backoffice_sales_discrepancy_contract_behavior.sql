-- Rollback-only behavior for Step 4/6.1 normalized disposition contract.
BEGIN;
DO $test$
DECLARE
  v_line uuid:=gen_random_uuid();v_product uuid:=gen_random_uuid();v_result jsonb;
  v_failed boolean;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911164000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: discrepancy contract foundation required';
  END IF;

  v_result:=private.validate_backoffice_sales_receipt_disposition_payload(
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
      'acceptedBaseQty',8,'discrepancies',jsonb_build_array(jsonb_build_object(
        'discrepancyType','SHORT','requestedResolution','BACKORDER',
        'physicalState','NOT_LOADED','quantityBase',2)))));
  IF (v_result->>'acceptedBaseQty')::numeric<>8
    OR (v_result->>'discrepancyBaseQty')::numeric<>2
    OR (v_result->>'requiresWarehouseResolution')::boolean IS NOT TRUE
    OR (v_result->>'requiresSalesApproval')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: accepted 8 plus Backorder 2 contract drift %',v_result;
  END IF;

  v_result:=private.validate_backoffice_sales_receipt_disposition_payload(
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
      'acceptedBaseQty',10,'discrepancies',jsonb_build_array(jsonb_build_object(
        'discrepancyType','OVERAGE','requestedResolution','ACCEPT_OVERAGE',
        'quantityBase',1)))));
  IF (v_result->>'requiresSalesApproval')::boolean IS NOT TRUE
    OR (v_result->>'requiresWarehouseResolution')::boolean IS TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: Accept Overage approval contract drift %',v_result;
  END IF;

  v_result:=private.validate_backoffice_sales_receipt_disposition_payload(
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
      'acceptedBaseQty',7,'discrepancies',jsonb_build_array(
        jsonb_build_object('discrepancyType','WRONG_ITEM',
          'requestedResolution','REPLACE_WRONG_ITEM','quantityBase',1,
          'actualProductId',v_product,'actualUomId',gen_random_uuid(),
          'actualQuantityUom',1,'actualQuantityBase',1),
        jsonb_build_object('discrepancyType','SHORT',
          'requestedResolution','ACCEPT_SHORT','physicalState','DAMAGED',
          'quantityBase',2)))));
  IF (v_result->>'discrepancyCount')::integer<>2
    OR (v_result->>'requiresWarehouseResolution')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: wrong/damaged warehouse contract drift %',v_result;
  END IF;

  v_failed:=false;
  BEGIN
    PERFORM private.validate_backoffice_sales_receipt_disposition_payload(
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
        'acceptedBaseQty',8,'discrepancies',jsonb_build_array(jsonb_build_object(
          'discrepancyType','SHORT','requestedResolution','ACCEPT_OVERAGE',
          'quantityBase',2)))));
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%BACKOFFICE_DISCREPANCY_ACTION_INVALID%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: invalid type/action pair accepted'; END IF;

  v_failed:=false;
  BEGIN
    PERFORM private.validate_backoffice_sales_receipt_disposition_payload(
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
        'acceptedBaseQty',8,'discrepancies',jsonb_build_array(jsonb_build_object(
          'discrepancyType','WRONG_ITEM','requestedResolution','REPLACE_WRONG_ITEM',
          'quantityBase',2)))));
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_REQUIRED%'
    OR SQLERRM LIKE '%BACKOFFICE_DISCREPANCY_ACTUAL_ITEM%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: Wrong Item without actual Product accepted'; END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_discrepancy_contract_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'accepted 8 becomes immediately invoiceable contract','Backorder 2 remains operationally open',
    'Accept Overage requires Sales approval','Wrong Item requires actual Product',
    'Short physical state and Return/Backorder require Warehouse resolution',
    'invalid type/action pair rejected','all test work rolled back']) details;
