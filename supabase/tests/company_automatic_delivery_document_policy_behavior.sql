-- Deterministic, fixture-free behavioral contract test. No persistent writes.
BEGIN;

DO $test$
DECLARE v_failed BOOLEAN:=FALSE;
BEGIN
  IF private.sales_delivery_document_required('PICKUP','DELIVERY_ONLY') THEN
    RAISE EXCEPTION 'TEST_FAILED: Pickup must stay document-free by default';
  END IF;
  IF NOT private.sales_delivery_document_required('PICKUP','ALL_POSTED_SALES')
    OR NOT private.sales_delivery_document_required('DELIVERY','DELIVERY_ONLY') THEN
    RAISE EXCEPTION 'TEST_FAILED: automatic delivery decision invalid';
  END IF;
  IF private.sales_delivery_transition_target('READY','PICKUP','DELIVER',NULL)
      <>'DELIVERED'
    OR private.sales_delivery_transition_target('READY','DELIVERY','DISPATCH',NULL)
      <>'DISPATCHED'
    OR private.sales_delivery_transition_target('DISPATCHED','DELIVERY','DELIVER',NULL)
      <>'DELIVERED'
    OR private.sales_delivery_transition_target('READY','PICKUP','CANCEL','Batal')
      <>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: delivery lifecycle decision invalid';
  END IF;
  BEGIN
    PERFORM private.sales_delivery_transition_target(
      'READY','PICKUP','DISPATCH',NULL);
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%INVALID_SALES_DELIVERY_TRANSITION%';
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'TEST_FAILED: Pickup dispatch must be rejected';
  END IF;
END
$test$;

SELECT 'company_automatic_delivery_document_policy_behavior' check_name,
  'PASS' status,jsonb_build_object('tested',jsonb_build_array(
    'default Delivery-only policy','all-Sale Pickup document decision',
    'Pickup direct handover','Delivery dispatch then deliver',
    'Pickup dispatch rejection')) details;

ROLLBACK;
