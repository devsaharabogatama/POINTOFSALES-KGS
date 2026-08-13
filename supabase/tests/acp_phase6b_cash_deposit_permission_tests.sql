-- ACP-6B behavior: Cash Deposit VIEW/approval are restrictable while the
-- Cashier channel and Deposit Variance reference path stay independently gated.
-- SAFETY: all fixtures and overrides roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000143091','acp6b-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6B Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000143092','acp6b-finance@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6B Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000143091','acp6b-admin@example.invalid',
 'ACP6B Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000143092','acp6b-finance@example.invalid',
 'ACP6B Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000143001','ACP143',
  'ACP6B Company','acp6b-company','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000143001',
 '00000000-0000-0000-0000-000000143091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000143001',
 '00000000-0000-0000-0000-000000143092','FINANCE','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000143092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000143001','ACP6B_TEST');
  v_result:=public.get_finance_cash_deposits(NULL);
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000143001'
     OR jsonb_array_length(v_result->'data')<>0
     OR jsonb_array_length(v_result->'lines')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Cash Deposit response invalid';
  END IF;

  v_result:=public.get_deposit_variance_cash_deposit_references();
  IF jsonb_array_length(v_result)<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Deposit Variance reference response invalid';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000143091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000143001','ACP6B_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000143001',
    '00000000-0000-0000-0000-000000143092',
    'finance.cash_deposits','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000143092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_finance_cash_deposits('APPROVED');
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA Cash Deposit response invalid';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.review_cash_deposit(
      '00000000-0000-0000-0000-000000143081',1,'APPROVE',NULL,
      '00000000-0000-0000-0000-000000143082');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA approved Cash Deposit'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.list_cash_deposit_eligible_sessions(
      '00000000-0000-0000-0000-000000143071');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'PERMISSION_CAPABILITY_REQUIRED:%' THEN
      v_rejected:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA used Cashier Deposit channel'; END IF;

  IF has_table_privilege(
      'authenticated','public.cash_deposit_documents','SELECT')
    OR has_table_privilege(
      'authenticated','public.cash_deposit_session_lines','SELECT')
    OR has_table_privilege(
      'authenticated','public.cash_deposit_policies','SELECT')
    OR has_table_privilege(
      'authenticated','public.cash_deposit_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Cash Deposit read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Cash Deposit capability, Cashier channel, and Deposit Variance references are isolated.';
END
$test$;

ROLLBACK;
