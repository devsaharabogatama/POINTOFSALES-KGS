-- Rollback-safe authority split behavior test. Requires one delivery document.
BEGIN;
DO $test$
DECLARE v_company UUID;v_actor UUID;v_sale UUID;v_delivery UUID;
  v_result JSONB;v_rejected BOOLEAN:=FALSE;
BEGIN
  SELECT membership.company_id,membership.user_id,delivery.sales_id,delivery.id
  INTO v_company,v_actor,v_sale,v_delivery
  FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  JOIN public.sales_delivery_documents delivery
    ON delivery.company_id=membership.company_id
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN')
  ORDER BY delivery.created_at DESC LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Inventory user and Surat Jalan required';
  END IF;

  INSERT INTO public.user_company_permission_overrides(
    company_id,user_id,permission_key,restriction_preset,created_by,updated_by)
  VALUES(v_company,v_actor,'inventory.delivery_documents','LIHAT_SAJA',v_actor,v_actor)
  ON CONFLICT(company_id,user_id,permission_key) DO UPDATE SET
    restriction_preset='LIHAT_SAJA',master_version=
      public.user_company_permission_overrides.master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp();

  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'ACP7_TEST');

  v_result:=public.get_inventory_delivery_documents();
  IF jsonb_typeof(v_result->'data')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: delivery list response invalid';
  END IF;
  v_result:=public.get_inventory_delivery_document(v_sale);
  IF (v_result->>'deliveryDocumentId')::UUID<>v_delivery THEN
    RAISE EXCEPTION 'TEST_FAILED: delivery detail identity invalid';
  END IF;
  PERFORM public.record_inventory_delivery_print(v_delivery);

  BEGIN
    PERFORM public.update_sales_delivery_status(v_delivery,1,'DISPATCH',NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA managed Surat Jalan';
  END IF;

  RAISE NOTICE 'TEST PASSED: Inventory Surat Jalan read/print and MANAGE are separated.';
END
$test$;
ROLLBACK;
