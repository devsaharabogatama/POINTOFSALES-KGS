-- ACP-6G behavior: VIEW/MANAGE/EXPORT and POS/Expense authority separation.
-- SAFETY: override and attempted mutation fully rolled back.

BEGIN;

DO $test$
DECLARE v_actor UUID;v_company UUID;v_method RECORD;v_result JSONB;
  v_cashier UUID;v_cashier_company UUID;v_store UUID;v_rejected BOOLEAN:=FALSE;
BEGIN
  SELECT membership.user_id,membership.company_id INTO v_actor,v_company
  FROM public.company_memberships membership
  JOIN auth.users auth_user ON auth_user.id=membership.user_id
  WHERE membership.status='ACTIVE'
    AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN')
    AND EXISTS(SELECT 1 FROM public.payment_methods method
      WHERE method.company_id=membership.company_id AND NOT method.is_system_method)
  ORDER BY membership.company_id,membership.user_id LIMIT 1;
  IF v_actor IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: Payment Method manager required'; END IF;
  SELECT method.* INTO v_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND NOT method.is_system_method
  ORDER BY method.is_default DESC,method.id LIMIT 1;

  SELECT session.cashier_id,session.company_id,session.store_id
  INTO v_cashier,v_cashier_company,v_store FROM public.cashier_sessions session
  JOIN auth.users auth_user ON auth_user.id=session.cashier_id
  WHERE session.status='OPEN'::public.session_status
  ORDER BY session.opened_at DESC,session.id LIMIT 1;
  IF v_cashier IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: open Cashier Session required'; END IF;

  -- Test setup runs with the SQL runner authority. Do not call the public
  -- administrator workflow as the target user itself: that workflow correctly
  -- rejects self-targeting. This fixture row is transaction-local and the
  -- final ROLLBACK restores any pre-existing override unchanged.
  INSERT INTO public.user_company_permission_overrides(
    company_id,user_id,permission_key,restriction_preset,created_by,updated_by
  ) VALUES(v_company,v_actor,'finance.payment_methods','LIHAT_SAJA',
    v_actor,v_actor)
  ON CONFLICT(company_id,user_id,permission_key) DO UPDATE SET
    restriction_preset='LIHAT_SAJA',
    master_version=public.user_company_permission_overrides.master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp();

  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_company,'ACP6G_TEST');
  v_result:=public.get_finance_payment_methods();
  IF (v_result->>'companyId')::UUID<>v_company
     OR jsonb_typeof(v_result->'data')<>'array'
     OR jsonb_typeof(v_result->'stores')<>'array'
     OR jsonb_typeof(v_result->'audit')<>'array' THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Payment Method response invalid';
  END IF;

  v_result:=public.get_finance_payment_methods();
  IF jsonb_typeof(v_result->'data')<>'array' THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA Payment Method response invalid'; END IF;

  BEGIN
    PERFORM public.save_payment_method(v_method.id,v_method.master_version,
      v_method.payment_method_name,v_method.method_type,
      v_method.settlement_route,v_method.is_default,
      v_method.available_all_stores,'{}'::UUID[],v_method.proof_mode,
      v_method.fee_enabled,v_method.fee_bearer,v_method.fee_type,
      v_method.fee_percent,v_method.fee_fixed_amount,
      v_method.clearing_account_function,v_method.bank_account_function,
      v_method.effective_from,v_method.effective_to,v_method.is_active);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA managed Payment Method'; END IF;

  v_rejected:=FALSE;
  BEGIN PERFORM public.export_finance_payment_methods();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA exported Payment Method'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_cashier,'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(v_cashier_company,'ACP6G_TEST');
  v_result:=public.get_pos_payment_method_references(v_store);
  IF jsonb_typeof(v_result)<>'array' OR EXISTS(SELECT 1
    FROM jsonb_array_elements(v_result) method
    WHERE method->>'method_type' IN('KETUL_OFFSET','TEMPO')) THEN
    RAISE EXCEPTION 'TEST_FAILED: POS Payment Method reference invalid';
  END IF;

  IF has_table_privilege('authenticated','public.payment_methods','SELECT')
    OR has_table_privilege('authenticated',
      'public.payment_method_store_assignments','SELECT')
    OR has_table_privilege('authenticated',
      'public.payment_method_master_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Payment Method read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Payment Method VIEW/MANAGE/EXPORT and POS authority are separated.';
END
$test$;

ROLLBACK;
