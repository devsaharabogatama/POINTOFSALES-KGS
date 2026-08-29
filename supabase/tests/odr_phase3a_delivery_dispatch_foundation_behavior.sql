-- ODR-3A foundation behavioral boundary. Transaction is always rolled back.
BEGIN;
DO $test$
DECLARE v_denied BOOLEAN:=FALSE;v_fk_guard BOOLEAN:=FALSE;
BEGIN
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO public.sales_dispatch_allocations(company_id,delivery_document_id,
      delivery_line_id,reservation_id,reservation_line_id,dispatch_idempotency_key,
      allocation_no,allocation_kind,dispatched_base_qty,created_by)
    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      gen_random_uuid(),gen_random_uuid(),1,'NEGATIVE',1,gen_random_uuid());
  EXCEPTION WHEN insufficient_privilege THEN v_denied:=TRUE;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_denied THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated dispatch allocation write allowed';
  END IF;

  BEGIN
    INSERT INTO public.sales_dispatch_allocations(company_id,delivery_document_id,
      delivery_line_id,reservation_id,reservation_line_id,dispatch_idempotency_key,
      allocation_no,allocation_kind,dispatched_base_qty,created_by)
    VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
      gen_random_uuid(),gen_random_uuid(),1,'NEGATIVE',1,gen_random_uuid());
  EXCEPTION WHEN foreign_key_violation THEN v_fk_guard:=TRUE;
  END;
  IF NOT v_fk_guard THEN
    RAISE EXCEPTION 'TEST_FAILED: dispatch allocation tenant lineage not guarded';
  END IF;
END
$test$;
SELECT 'odr_phase3a_delivery_dispatch_foundation_behavior' check_name,'PASS' status,
  jsonb_build_object('tested',ARRAY[
    'authenticated write denial','tenant lineage foreign-key guard']) details;
ROLLBACK;
