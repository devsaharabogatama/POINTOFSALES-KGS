-- PRD Company access lifecycle behavior. All fixture changes roll back.
BEGIN;

DO $setup$
DECLARE v_actor UUID;v_target UUID;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT profile.id INTO v_target FROM public.profiles profile
  WHERE profile.id<>v_actor AND profile.role<>'super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL OR v_target IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: linked Super Admin and regular user required';
  END IF;
  INSERT INTO public.companies(
    id,company_code,company_name,company_slug,status
  ) VALUES
    ('00000000-0000-0000-0000-000000134001','PRD134A',
     'PRD Access A','prd-access-a','ACTIVE'),
    ('00000000-0000-0000-0000-000000134002','PRD134B',
     'PRD Access B','prd-access-b','ACTIVE');
  INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
    ('00000000-0000-0000-0000-000000134011',
     '00000000-0000-0000-0000-000000134001','STORE-A','Store A','ACTIVE'),
    ('00000000-0000-0000-0000-000000134012',
     '00000000-0000-0000-0000-000000134002','STORE-B','Store B','ACTIVE');
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::TEXT,TRUE);
  PERFORM set_config('kgs.prd_access_target',v_target::TEXT,TRUE);
  -- Protected context fixture is prepared by the SQL test runner before the
  -- browser role is activated. Runtime/browser grants remain unchanged.
  INSERT INTO public.user_active_company_contexts(
    user_id,company_id,selection_source
  ) VALUES(v_target,'00000000-0000-0000-0000-000000134002','BACKOFFICE')
  ON CONFLICT(user_id) DO UPDATE SET
    company_id=EXCLUDED.company_id,selection_source=EXCLUDED.selection_source;
END
$setup$;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE
  v_target UUID:=current_setting('kgs.prd_access_target')::UUID;
  v_result JSONB;v_count BIGINT;v_rejected BOOLEAN:=FALSE;
BEGIN
  v_result:=public.save_user_company_access(
    '00000000-0000-0000-0000-000000134001',v_target,
    'COMPANY_ADMIN',NULL);
  IF v_result->>'action'<>'ASSIGN' THEN
    RAISE EXCEPTION 'TEST_FAILED: Company A assignment invalid';
  END IF;
  v_result:=public.save_user_company_access(
    '00000000-0000-0000-0000-000000134002',v_target,
    'CASHIER','00000000-0000-0000-0000-000000134012');
  IF v_result->>'action'<>'ASSIGN' THEN
    RAISE EXCEPTION 'TEST_FAILED: Company B assignment invalid';
  END IF;
  v_result:=public.save_user_company_access(
    '00000000-0000-0000-0000-000000134001',v_target,
    'ACCOUNTING',NULL);
  IF v_result->>'action'<>'UPDATE_ASSIGNMENT' THEN
    RAISE EXCEPTION 'TEST_FAILED: selected Company role update invalid';
  END IF;
  SELECT count(*) INTO v_count FROM public.company_memberships
  WHERE user_id=v_target AND status='ACTIVE' AND (
    (company_id='00000000-0000-0000-0000-000000134001'
      AND role_code='ACCOUNTING') OR
    (company_id='00000000-0000-0000-0000-000000134002'
      AND role_code='CASHIER'));
  IF v_count<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company roles were not isolated';
  END IF;

  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000134002',v_target,
    'inventory.stock_real','TANPA_AKSES',NULL);
  v_result:=public.deactivate_user_company_access(
    '00000000-0000-0000-0000-000000134002',v_target);
  IF v_result->>'action'<>'DEACTIVATE' THEN
    RAISE EXCEPTION 'TEST_FAILED: Company B deactivation invalid';
  END IF;
  SELECT count(*) INTO v_count FROM public.company_memberships
  WHERE company_id='00000000-0000-0000-0000-000000134002'
    AND user_id=v_target AND status='INACTIVE';
  IF v_count<>1 OR EXISTS(SELECT 1 FROM public.store_memberships
    WHERE company_id='00000000-0000-0000-0000-000000134002'
      AND user_id=v_target AND status='ACTIVE')
    THEN
    RAISE EXCEPTION 'TEST_FAILED: Company B access residue remains';
  END IF;
  v_result:=public.deactivate_user_company_access(
    '00000000-0000-0000-0000-000000134002',v_target);
  IF v_result->>'action'<>'EXACT_RETRY' THEN
    RAISE EXCEPTION 'TEST_FAILED: deactivate exact retry invalid';
  END IF;

  -- No direct membership write is needed: self-mutation must be rejected by
  -- the canonical RPC before any target membership or hierarchy evaluation.
  BEGIN
    PERFORM public.deactivate_user_company_access(
      '00000000-0000-0000-0000-000000134001',auth.uid());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='PERMISSION_TARGET_ACCESS_DENIED' THEN v_rejected:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: self deactivation was accepted';
  END IF;

END
$test$;

RESET ROLE;

DO $protected_verification$
DECLARE
  v_target UUID:=current_setting('kgs.prd_access_target')::UUID;
  v_count BIGINT;v_context_company UUID;
BEGIN
  SELECT company_id INTO v_context_company
  FROM public.user_active_company_contexts WHERE user_id=v_target;
  IF v_context_company IS NULL
     OR v_context_company='00000000-0000-0000-0000-000000134002'::UUID
     OR NOT EXISTS(SELECT 1 FROM public.company_memberships membership
       WHERE membership.user_id=v_target
         AND membership.company_id=v_context_company
         AND membership.status='ACTIVE') THEN
    RAISE EXCEPTION 'TEST_FAILED: active Company context was not repaired';
  END IF;
  IF EXISTS(SELECT 1 FROM public.user_company_permission_overrides
    WHERE company_id='00000000-0000-0000-0000-000000134002'
      AND user_id=v_target) THEN
    RAISE EXCEPTION 'TEST_FAILED: Company B permission override remains';
  END IF;
  SELECT count(*) INTO v_count FROM public.user_company_permission_audit
  WHERE target_user_id=v_target
    AND company_id='00000000-0000-0000-0000-000000134002'
    AND action='RESET_OVERRIDE'
    AND after_state->>'reason'='COMPANY_ACCESS_DEACTIVATED';
  IF v_count<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: permission reset audit coverage invalid';
  END IF;
  SELECT count(*) INTO v_count FROM public.user_company_assignment_audit
  WHERE target_user_id=v_target
    AND company_id IN(
      '00000000-0000-0000-0000-000000134001',
      '00000000-0000-0000-0000-000000134002')
    AND action IN('ASSIGN','UPDATE_ASSIGNMENT','DEACTIVATE');
  IF v_count<>4 THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment audit coverage invalid';
  END IF;
END
$protected_verification$;

ROLLBACK;
