-- Data-adaptive authenticated behavior. Audit mutation is rolled back.
BEGIN;

DO $test$
DECLARE v_actor UUID;v_company UUID;v_sales UUID;v_delivery UUID;
  v_delivery_no TEXT;v_before BIGINT;v_after BIGINT;v_result JSONB;
BEGIN
  SELECT membership.user_id,membership.company_id,delivery.sales_id,delivery.id,
    delivery.delivery_no
  INTO v_actor,v_company,v_sales,v_delivery,v_delivery_no
  FROM public.company_memberships membership
  JOIN public.user_active_company_contexts context
    ON context.user_id=membership.user_id AND context.company_id=membership.company_id
  JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=membership.company_id AND delivery.reservation_id IS NOT NULL
  WHERE membership.status='ACTIVE' AND membership.role_code='WAREHOUSE_ADMIN'
  ORDER BY delivery.created_at DESC LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Warehouse Admin and linked Delivery required';
  END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);

  v_result:=public.get_inventory_delivery_document(v_sales);
  IF v_result->>'deliveryDocumentId'<>v_delivery::TEXT
    OR v_result->>'deliveryNo'<>v_delivery_no
    OR jsonb_typeof(v_result->'snapshot')<>'object'
    OR jsonb_typeof(v_result->'lines')<>'array'
    OR jsonb_array_length(v_result->'lines')=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse Admin ODR Delivery payload invalid';
  END IF;

  SELECT count(*) INTO v_before FROM public.sales_document_audit audit
  WHERE audit.company_id=v_company AND audit.document_type='SALES_DELIVERY'
    AND audit.document_id=v_delivery AND audit.action='PRINT';
  v_result:=public.record_inventory_delivery_print(v_delivery);
  SELECT count(*) INTO v_after FROM public.sales_document_audit audit
  WHERE audit.company_id=v_company AND audit.document_type='SALES_DELIVERY'
    AND audit.document_id=v_delivery AND audit.action='PRINT';
  IF v_result->>'documentNo'<>v_delivery_no OR v_result->>'printRecorded'<>'true'
    OR v_after<>v_before+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse Admin print audit invalid';
  END IF;

  RAISE NOTICE 'PASS: Warehouse Admin can read and record print for ODR Surat Jalan %',v_delivery_no;
END
$test$;

ROLLBACK;
