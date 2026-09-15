-- Rollback-only behavior for Step 4/6.2. No operational fixture required.
BEGIN;
DO $test$
DECLARE
  v_line uuid:=gen_random_uuid();v_product uuid:=gen_random_uuid();
  v_uom uuid:=gen_random_uuid();v_result jsonb;v_failed boolean;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911165000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: physical-state contract required';
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
    RAISE EXCEPTION 'TEST_FAILED: Backorder physical-state contract drift %',v_result;
  END IF;

  v_result:=private.validate_backoffice_sales_receipt_disposition_payload(
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
      'acceptedBaseQty',8,'discrepancies',jsonb_build_array(jsonb_build_object(
        'discrepancyType','SHORT','requestedResolution','ACCEPT_SHORT',
        'physicalState','LOST','quantityBase',2)))));
  IF (v_result->>'requiresWarehouseResolution')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: Accept-short physical loss bypassed Warehouse %',v_result;
  END IF;

  v_result:=private.validate_backoffice_sales_receipt_disposition_payload(
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
      'acceptedBaseQty',7,'discrepancies',jsonb_build_array(jsonb_build_object(
        'discrepancyType','WRONG_ITEM','requestedResolution','REPLACE_WRONG_ITEM',
        'quantityBase',3,'actualProductId',v_product,'actualUomId',v_uom,
        'actualQuantityUom',2,'actualQuantityBase',4)))));
  IF (v_result->>'discrepancyBaseQty')::numeric<>3
    OR (v_result->>'actualWrongItemBaseQty')::numeric<>4 THEN
    RAISE EXCEPTION 'TEST_FAILED: independent expected/actual Wrong Item quantity drift %',v_result;
  END IF;

  v_failed:=false;
  BEGIN
    PERFORM private.validate_backoffice_sales_receipt_disposition_payload(
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
        'acceptedBaseQty',8,'discrepancies',jsonb_build_array(jsonb_build_object(
          'discrepancyType','SHORT','requestedResolution','BACKORDER',
          'quantityBase',2)))));
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%BACKOFFICE_DISCREPANCY_PHYSICAL_STATE_REQUIRED%';
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: Short without physical state accepted';
  END IF;

  v_failed:=false;
  BEGIN
    PERFORM private.validate_backoffice_sales_receipt_disposition_payload(
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
        'acceptedBaseQty',7,'discrepancies',jsonb_build_array(jsonb_build_object(
          'discrepancyType','WRONG_ITEM','requestedResolution','REPLACE_WRONG_ITEM',
          'quantityBase',3,'actualProductId',v_product)))));
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%BACKOFFICE_DISCREPANCY_ACTUAL_ITEM%';
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: Wrong Item without independent actual UOM/quantity accepted';
  END IF;

  v_failed:=false;
  BEGIN
    PERFORM private.validate_backoffice_sales_receipt_disposition_payload(
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_line,
        'acceptedBaseQty',10,'discrepancies',jsonb_build_array(jsonb_build_object(
          'discrepancyType','OVERAGE','requestedResolution','ACCEPT_OVERAGE',
          'physicalState','LOST','quantityBase',1)))));
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%BACKOFFICE_DISCREPANCY_ACTION_INVALID%';
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: shortage-only physical state accepted on Overage';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_discrepancy_physical_state_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'Backorder plus Not Loaded are separate facts',
    'Accept Short plus Lost still requires Warehouse resolution',
    'Wrong Item expected and actual quantities remain independent',
    'Short without physical state rejected',
    'Wrong Item without actual Product/UOM/quantity rejected',
    'physical state rejected outside shortage',
    'all test work rolled back']) details;

