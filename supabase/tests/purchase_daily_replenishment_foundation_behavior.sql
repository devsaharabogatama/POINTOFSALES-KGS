-- Purchase Daily Replenishment Step 1/6: self-contained rollback-only behavior.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153131','purchase-replenishment-test@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase Replenishment Test"}'::jsonb,false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153131','purchase-replenishment-test@example.invalid',
  'Purchase Replenishment Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153131';v_company uuid;
  v_version bigint;v_result jsonb;v_failed boolean:=false;v_audit bigint;
  v_stock_before bigint;v_request_before bigint;v_order_before bigint;v_receipt_before bigint;
BEGIN
  SELECT company.id INTO v_company FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with provisioned setting required'; END IF;

  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);

  SELECT master_version INTO v_version FROM public.company_purchase_replenishment_settings
  WHERE company_id=v_company;
  SELECT count(*) INTO v_stock_before FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_request_before FROM public.stock_request_documents WHERE company_id=v_company;
  SELECT count(*) INTO v_order_before FROM public.supplier_order_documents WHERE company_id=v_company;
  SELECT count(*) INTO v_receipt_before FROM public.goods_receipt_documents WHERE company_id=v_company;

  v_result:=public.set_purchase_replenishment_mode('AUTO_RO',v_version);
  IF v_result->>'mode'<>'AUTO_RO' OR NOT (v_result->>'changed')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: AUTO_RO transition invalid';
  END IF;
  v_version:=(v_result->>'masterVersion')::bigint;
  v_result:=public.set_purchase_replenishment_mode('AUTO_PO',v_version);
  IF v_result->>'mode'<>'AUTO_PO' THEN RAISE EXCEPTION 'TEST_FAILED: AUTO_PO transition invalid'; END IF;
  v_version:=(v_result->>'masterVersion')::bigint;
  v_result:=public.set_purchase_replenishment_mode('MANUAL',v_version);
  IF v_result->>'mode'<>'MANUAL' THEN RAISE EXCEPTION 'TEST_FAILED: MANUAL transition invalid'; END IF;

  BEGIN
    PERFORM public.set_purchase_replenishment_mode('INVALID',(v_result->>'masterVersion')::bigint);
  EXCEPTION WHEN others THEN v_failed:=SQLERRM LIKE '%PURCHASE_REPLENISHMENT_MODE_INVALID%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: invalid mode accepted'; END IF;

  v_failed:=false;
  BEGIN
    PERFORM public.set_purchase_replenishment_mode('AUTO_RO',1);
  EXCEPTION WHEN others THEN v_failed:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale version accepted'; END IF;

  SELECT count(*) INTO v_audit FROM public.company_purchase_replenishment_setting_audit
  WHERE company_id=v_company AND actor_id=v_actor AND action='MODE_CHANGE';
  IF v_audit<>3 THEN RAISE EXCEPTION 'TEST_FAILED: mode change audit count invalid: %',v_audit; END IF;

  IF (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock_before
    OR (SELECT count(*) FROM public.stock_request_documents WHERE company_id=v_company)<>v_request_before
    OR (SELECT count(*) FROM public.supplier_order_documents WHERE company_id=v_company)<>v_order_before
    OR (SELECT count(*) FROM public.goods_receipt_documents WHERE company_id=v_company)<>v_receipt_before THEN
    RAISE EXCEPTION 'TEST_FAILED: setting mutation created operational effect';
  END IF;

  RAISE NOTICE 'TEST_PASS: MANUAL/AUTO_RO/AUTO_PO transitions, stale guard, audit and zero operational effect verified';
END
$test$;

ROLLBACK;
