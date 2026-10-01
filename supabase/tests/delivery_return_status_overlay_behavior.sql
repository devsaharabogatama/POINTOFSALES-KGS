-- Authenticated read behavior with a rollback-only Backoffice Return fixture.
BEGIN;

DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_payload jsonb;v_invalid bigint;v_rows bigint;
  v_backoffice_delivery uuid;v_sales_order uuid;v_customer uuid;
  v_fixture_return uuid:=gen_random_uuid();v_branch_rows bigint;
BEGIN
  SELECT membership.user_id,membership.company_id,delivery.id,
    delivery.sales_order_id,sales_order.customer_id
  INTO v_actor,v_company,v_backoffice_delivery,v_sales_order,v_customer
  FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  JOIN public.profiles profile ON profile.id=membership.user_id
  JOIN LATERAL (
    SELECT candidate.id,candidate.sales_order_id
    FROM public.backoffice_sales_delivery_orders candidate
    WHERE candidate.company_id=membership.company_id
    ORDER BY candidate.created_at DESC,candidate.id LIMIT 1
  ) delivery ON true
  JOIN public.backoffice_sales_orders sales_order
    ON sales_order.company_id=membership.company_id
    AND sales_order.id=delivery.sales_order_id
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER')
    AND EXISTS(
      SELECT 1
      FROM public.backoffice_sales_returns document
      JOIN public.sales_delivery_documents retail_delivery
        ON retail_delivery.company_id=document.company_id
        AND retail_delivery.sales_id=document.retail_sales_id
      WHERE document.company_id=membership.company_id
        AND document.source_kind='RETAINED_RETAIL')
  ORDER BY membership.company_id,membership.user_id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: Company with manager, retained Retail Return and Backoffice Delivery required';
  END IF;

  INSERT INTO public.backoffice_sales_returns(
    id,company_id,return_no,sales_order_id,source_kind,retail_sales_id,
    source_document_snapshot,customer_id,status,reason,
    total_requested_base_qty,created_by,updated_by
  ) VALUES(
    v_fixture_return,v_company,
    'TEST-DO-RETURN-'||left(replace(v_fixture_return::text,'-',''),12),
    v_sales_order,'BACKOFFICE',NULL,NULL,v_customer,'DRAFT',
    'Rollback-only Delivery Return overlay branch test',0,v_actor,v_actor
  );

  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(
    v_company,'DELIVERY_RETURN_OVERLAY_TEST');

  v_payload:=public.get_inventory_delivery_return_overlays(NULL,NULL);
  IF (v_payload->>'workspaceVersion')::integer<>1
    OR (v_payload->>'companyId')::uuid<>v_company
    OR jsonb_typeof(v_payload->'data')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: payload contract invalid';
  END IF;
  SELECT count(*) INTO v_rows
  FROM jsonb_array_elements(v_payload->'data') row_data;
  IF v_rows=0 THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: no linked Delivery/Return overlay row';
  END IF;

  SELECT count(*) INTO v_branch_rows
  FROM jsonb_array_elements(v_payload->'data') row_data
  CROSS JOIN LATERAL jsonb_array_elements(row_data->'returns') return_data
  WHERE row_data->>'sourceChannel'='POS'
    AND row_data->>'attribution'='EXACT_DELIVERY'
    AND nullif(return_data->>'returnId','') IS NOT NULL;
  IF v_branch_rows=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Retail exact Delivery branch absent';
  END IF;

  SELECT count(*) INTO v_branch_rows
  FROM jsonb_array_elements(v_payload->'data') row_data
  CROSS JOIN LATERAL jsonb_array_elements(row_data->'returns') return_data
  WHERE row_data->>'sourceChannel'='BACKOFFICE_SALES'
    AND row_data->>'attribution'='SALES_ORDER'
    AND (row_data->>'deliveryDocumentId')::uuid=v_backoffice_delivery
    AND (return_data->>'returnId')::uuid=v_fixture_return
    AND return_data->>'status'='DRAFT';
  IF v_branch_rows<>1 THEN
    RAISE EXCEPTION
      'TEST_FAILED: Backoffice SO-level fixture branch rows %',v_branch_rows;
  END IF;

  SELECT count(*) INTO v_invalid
  FROM jsonb_array_elements(v_payload->'data') row_data
  CROSS JOIN LATERAL jsonb_array_elements(row_data->'returns') return_data
  WHERE row_data->>'sourceChannel' NOT IN('POS','BACKOFFICE_SALES')
    OR row_data->>'attribution' NOT IN('EXACT_DELIVERY','SALES_ORDER')
    OR nullif(return_data->>'returnNo','') IS NULL
    OR return_data->>'status' NOT IN('DRAFT','SUBMITTED','APPROVED',
      'PARTIALLY_RECEIVED','RECEIVED','CREDIT_PENDING','REFUND_PENDING',
      'COMPLETED','CANCELED')
    OR (return_data->>'requestedBaseQty')::numeric<0
    OR (return_data->>'receivedBaseQty')::numeric<0
    OR (return_data->>'restockedBaseQty')::numeric<0
    OR (return_data->>'destroyedBaseQty')::numeric<0;
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: invalid overlay rows (%)',v_invalid;
  END IF;

  BEGIN
    PERFORM public.get_inventory_delivery_return_overlays(
      date '2026-10-02',date '2026-10-01');
    RAISE EXCEPTION 'TEST_FAILED: invalid date range accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM<>'INVALID_DELIVERY_DATE_RANGE' THEN RAISE; END IF;
  END;

  RAISE NOTICE
    'TEST PASSED: real Retail exact Delivery branch and rollback-only Backoffice SO-level Delivery branch';
END
$test$;

ROLLBACK;

SELECT 'delivery_return_status_overlay_behavior' AS check_name,
  'PASS' AS status,0 AS violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'authenticated active-Company scope',
    'real retained Retail Return exact Delivery attribution',
    'rollback-only Backoffice Return fixture SO-level attribution',
    'Return status and quantity shape',
    'invalid date range rejection',
    'all fixture/context writes rolled back')) AS details;

