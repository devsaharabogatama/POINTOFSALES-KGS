-- Rollback-safe behavior: name-only Delivery is valid; blank recipient remains rejected.
BEGIN;
DO $test$
DECLARE v_name TEXT;
BEGIN
  v_name:=private.require_delivery_recipient_name('  Penerima Test  ');
  IF v_name<>'Penerima Test' THEN
    RAISE EXCEPTION 'TEST_FAILED: recipient name normalization invalid';
  END IF;
  BEGIN
    PERFORM private.require_delivery_recipient_name('   ');
    RAISE EXCEPTION 'TEST_FAILED: blank recipient name accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%DELIVERY_RECIPIENT_REQUIRED%' THEN RAISE; END IF;
  END;
  CREATE TEMP TABLE delivery_contact_shape_test
    (LIKE public.sales_delivery_documents INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
    ON COMMIT DROP;
  INSERT INTO delivery_contact_shape_test(company_id,delivery_no,sales_id,
    invoice_snapshot_id,store_id,warehouse_id,recipient_name,recipient_phone,
    delivery_address,snapshot_payload,created_by)
  VALUES('00000000-0000-0000-0000-000000152001','SJ/TEST/152',
    '00000000-0000-0000-0000-000000152002',
    '00000000-0000-0000-0000-000000152003',
    '00000000-0000-0000-0000-000000152004',
    '00000000-0000-0000-0000-000000152005','Penerima Test',NULL,NULL,
    '{}'::JSONB,'00000000-0000-0000-0000-000000152006');
  IF NOT EXISTS(SELECT 1 FROM delivery_contact_shape_test
    WHERE recipient_name='Penerima Test' AND recipient_phone IS NULL
      AND delivery_address IS NULL) THEN
    RAISE EXCEPTION 'TEST_FAILED: name-only Delivery row not retained';
  END IF;
END
$test$;
ROLLBACK;
