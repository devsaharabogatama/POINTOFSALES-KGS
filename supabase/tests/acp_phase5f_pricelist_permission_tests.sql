-- ACP-5F behavior: Pricelist restriction and independent POS references.
-- SAFETY: permission override and attempted writes roll back.

BEGIN;

DO $test$
DECLARE v_actor UUID;v_company UUID;v_pricelist UUID;v_version BIGINT;
  v_cashier UUID;v_cashier_company UUID;v_store UUID;v_result JSONB;
  v_rejected BOOLEAN:=FALSE;
BEGIN
  SELECT membership.user_id,membership.company_id
  INTO v_actor,v_company FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER')
    AND EXISTS(SELECT 1 FROM public.pricelists pricelist
      WHERE pricelist.company_id=membership.company_id)
  ORDER BY membership.company_id,membership.user_id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: manager and Pricelist required';
  END IF;
  SELECT pricelist.id,pricelist.master_version INTO v_pricelist,v_version
  FROM public.pricelists pricelist WHERE pricelist.company_id=v_company
  ORDER BY pricelist.id LIMIT 1;

  SELECT session.cashier_id,session.company_id,session.store_id
  INTO v_cashier,v_cashier_company,v_store FROM public.cashier_sessions session
  JOIN auth.users auth_user ON auth_user.id=session.cashier_id
  WHERE session.status='OPEN'::public.session_status
  ORDER BY session.opened_at DESC,session.id LIMIT 1;
  IF v_cashier IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: open Cashier Session required';
  END IF;

  INSERT INTO public.user_company_permission_overrides(
    company_id,user_id,permission_key,restriction_preset,created_by,updated_by
  ) VALUES(v_company,v_actor,'sales.pricelists','LIHAT_SAJA',v_actor,v_actor)
  ON CONFLICT(company_id,user_id,permission_key) DO UPDATE SET
    restriction_preset='LIHAT_SAJA',master_version=
      public.user_company_permission_overrides.master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp();

  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'ACP5F_TEST');

  v_result:=public.get_sales_pricelists(FALSE);
  IF (v_result->>'companyId')::UUID<>v_company
     OR jsonb_typeof(v_result->'data')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: composed VIEW response invalid';
  END IF;

  BEGIN
    PERFORM public.export_sales_pricelists();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA exported Pricelist';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_reusable_pricelist_with_rules(
      v_pricelist,v_version,'Denied Update','GLOBAL',0,FALSE,TRUE,
      '{}'::UUID[],NULL,NULL,TRUE,NULL,'[]'::JSONB);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA managed Pricelist';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_cashier,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_cashier_company,'ACP5F_TEST');
  v_result:=public.get_pos_pricelist_references(v_store);
  IF jsonb_typeof(v_result)<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: POS Pricelist reference invalid';
  END IF;

  IF has_table_privilege('authenticated','public.pricelists','SELECT')
    OR has_table_privilege('authenticated','public.pricelist_rules','SELECT')
    OR has_table_privilege(
      'authenticated','public.pricelist_store_assignments','SELECT')
    OR has_table_privilege(
      'authenticated','public.pricelist_master_audit','SELECT')
  THEN RAISE EXCEPTION 'TEST_FAILED: direct Pricelist read remains'; END IF;
  IF has_function_privilege('authenticated',
    'public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
    'EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy Pricelist mutation remains executable';
  END IF;

  RAISE NOTICE 'TEST PASSED: Pricelist VIEW/MANAGE/EXPORT and POS authority are separated.';
END
$test$;

ROLLBACK;
