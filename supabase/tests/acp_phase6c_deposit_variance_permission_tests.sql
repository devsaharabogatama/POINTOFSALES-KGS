-- ACP-6C behavior: Deposit Variance VIEW, MANAGE, and maker-checker actions
-- are restrictable without exposing direct tables.
-- SAFETY: all fixtures and overrides roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000144091','acp6c-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6C Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000144092','acp6c-finance@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6C Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000144091','acp6c-admin@example.invalid',
 'ACP6C Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000144092','acp6c-finance@example.invalid',
 'ACP6C Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000144001','ACP144',
  'ACP6C Company','acp6c-company','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000144001',
 '00000000-0000-0000-0000-000000144091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000144001',
 '00000000-0000-0000-0000-000000144092','FINANCE','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000144092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000144001','ACP6C_TEST');
  v_result:=public.get_finance_deposit_variances();
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000144001'
     OR jsonb_array_length(v_result->'data')<>0
     OR jsonb_array_length(v_result->'requests')<>0
     OR jsonb_array_length(v_result->'allocations')<>0
     OR jsonb_array_length(v_result->'members')<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Deposit Variance response invalid';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000144091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000144001','ACP6C_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000144001',
    '00000000-0000-0000-0000-000000144092',
    'finance.deposit_variances','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000144092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_finance_deposit_variances();
  IF jsonb_array_length(v_result->'data')<>0
     OR jsonb_array_length(v_result->'members')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA response exposes manager scope';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.assign_deposit_variance_responsible_party(
      '00000000-0000-0000-0000-000000144081',1,
      '00000000-0000-0000-0000-000000144092','Test restriction');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA assigned responsible party'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.review_deposit_variance_resolution(
      '00000000-0000-0000-0000-000000144082',1,'APPROVE',NULL,
      '00000000-0000-0000-0000-000000144083');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA approved Deposit Variance'; END IF;

  IF has_table_privilege(
      'authenticated','public.deposit_variance_exceptions','SELECT')
    OR has_table_privilege(
      'authenticated','public.deposit_variance_allocations','SELECT')
    OR has_table_privilege('authenticated',
      'public.deposit_variance_resolution_requests','SELECT')
    OR has_table_privilege('authenticated',
      'public.deposit_variance_resolution_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Deposit Variance read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Deposit Variance VIEW, MANAGE, maker-checker, and direct-read boundaries are enforced.';
END
$test$;

ROLLBACK;
