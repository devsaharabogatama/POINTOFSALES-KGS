-- Behavioral test. Creates fixtures only inside this transaction and always rolls back.
BEGIN;

DO $fixture$
DECLARE v_actor UUID;v_company UUID;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE public.private_is_super_admin(profile.id)
  ORDER BY profile.id LIMIT 1;

  IF v_actor IS NOT NULL THEN
    SELECT company.id INTO v_company FROM public.companies company
    WHERE company.status='ACTIVE' ORDER BY company.id LIMIT 1;
  ELSE
    SELECT membership.user_id,membership.company_id INTO v_actor,v_company
    FROM public.company_memberships membership
    JOIN auth.users auth_user ON auth_user.id=membership.user_id
    JOIN public.companies company ON company.id=membership.company_id
    WHERE membership.status='ACTIVE'
      AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
      AND company.status='ACTIVE'
    ORDER BY membership.company_id,membership.user_id LIMIT 1;
  END IF;

  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Owner/Admin or Super Admin required';
  END IF;

  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE')
  ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
END
$fixture$;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_company UUID:=public.private_active_company_id();v_store JSONB;v_terminal JSONB;v_setup JSONB;
  v_store_id UUID;v_terminal_id UUID;v_version BIGINT;
BEGIN

  v_store:=public.save_platform_pos_store(NULL,NULL,'UAT-POS-STORE','UAT POS Store',
    'Alamat rollback','Asia/Jakarta','ACTIVE');
  v_store_id:=(v_store->>'storeId')::UUID;
  IF (v_store->>'action')<>'CREATE' THEN RAISE EXCEPTION 'TEST_FAILED: Store create'; END IF;

  v_store:=public.save_platform_pos_store(v_store_id,1,'UAT-POS-STORE','UAT POS Store',
    'Alamat rollback','Asia/Jakarta','ACTIVE');
  IF (v_store->>'action')<>'EXACT_RETRY' THEN RAISE EXCEPTION 'TEST_FAILED: Store exact retry'; END IF;

  v_terminal:=public.save_platform_pos_terminal(NULL,NULL,v_store_id,'POS-UAT-1',
    'Terminal UAT','DEVICE-UAT','ACTIVE');
  v_terminal_id:=(v_terminal->>'terminalId')::UUID;
  IF (v_terminal->>'action')<>'CREATE' THEN RAISE EXCEPTION 'TEST_FAILED: Terminal create'; END IF;

  v_terminal:=public.save_platform_pos_terminal(v_terminal_id,1,v_store_id,'POS-UAT-1',
    'Terminal UAT Baru','DEVICE-UAT','ACTIVE');
  v_version:=(v_terminal->>'masterVersion')::BIGINT;
  IF (v_terminal->>'action')<>'UPDATE' OR v_version<>2 THEN RAISE EXCEPTION 'TEST_FAILED: Terminal update'; END IF;

  v_setup:=public.get_platform_pos_setup();
  IF NOT COALESCE((v_setup->'stores') @> jsonb_build_array(jsonb_build_object('id',v_store_id)),FALSE)
    OR NOT COALESCE((v_setup->'terminals') @> jsonb_build_array(jsonb_build_object('id',v_terminal_id)),FALSE) THEN
    RAISE EXCEPTION 'TEST_FAILED: composed response';
  END IF;

  BEGIN
    PERFORM public.save_platform_pos_store(v_store_id,1,'UAT-POS-STORE','UAT POS Store',
      'Alamat rollback','Asia/Jakarta','INACTIVE');
    RAISE EXCEPTION 'TEST_FAILED: active dependency guard missing';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%STORE_HAS_ACTIVE_OPERATIONAL_DEPENDENCY%' THEN RAISE; END IF;
  END;

  PERFORM public.save_platform_pos_terminal(v_terminal_id,v_version,v_store_id,'POS-UAT-1',
    'Terminal UAT Baru','DEVICE-UAT','INACTIVE');
  PERFORM public.save_platform_pos_store(v_store_id,1,'UAT-POS-STORE','UAT POS Store',
    'Alamat rollback','Asia/Jakarta','INACTIVE');
END
$test$;

ROLLBACK;

SELECT 'platform_pos_store_terminal_behavioral_test' AS check_name,'PASS' AS status,
  jsonb_build_object('rolledBack',TRUE) AS details;
