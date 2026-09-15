-- Pure rollback-free behavior for the Purchase Order Bill-status classifier.
DO $test$
DECLARE v_invalid bigint;
BEGIN
  IF to_regprocedure('private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Purchase Order Bill classifier missing';
  END IF;
  SELECT count(*) INTO v_invalid
  FROM (VALUES
    (10::numeric,0::numeric,0,0,false,'NOT_READY'),
    (0,0,0,0,true,'NOT_READY'),
    (10,0,0,0,true,'READY'),
    (10,0,1,0,true,'DRAFT'),
    (10,0,0,1,true,'HOLD'),
    (10,4,0,0,true,'PARTIALLY_BILLED'),
    (10,10,0,0,true,'BILLED'),
    (10,12,0,0,true,'BILLED')
  ) scenario(billable_qty,validated_qty,draft_count,hold_count,supplier_ready,expected_status)
  WHERE private.classify_purchase_order_bill_status(
    scenario.billable_qty,scenario.validated_qty,
    scenario.draft_count,scenario.hold_count,scenario.supplier_ready)<>scenario.expected_status;
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Purchase Order Bill status classifier mismatch';
  END IF;
  RAISE NOTICE 'TEST PASSED: 8 deterministic Purchase Order Bill lifecycle scenarios';
END
$test$;
