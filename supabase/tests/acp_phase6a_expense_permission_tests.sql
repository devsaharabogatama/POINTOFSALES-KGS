-- ACP-6A behavior: Expense VIEW and approval are restrictable.
-- SAFETY: all fixture and override rows roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000142091','acp6a-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6A Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000142092','acp6a-finance@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6A Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000142091','acp6a-admin@example.invalid',
 'ACP6A Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000142092','acp6a-finance@example.invalid',
 'ACP6A Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000142001','ACP142',
  'ACP6A Company','acp6a-company','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000142001',
 '00000000-0000-0000-0000-000000142091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000142001',
 '00000000-0000-0000-0000-000000142092','FINANCE','ACTIVE',TRUE);
INSERT INTO public.company_features(company_id,feature_code,is_enabled)
VALUES('00000000-0000-0000-0000-000000142001','expense_enabled',TRUE)
ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=TRUE;

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000142092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000142001','ACP6A_TEST');
  v_result:=public.get_finance_expenses(NULL);
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000142001'
     OR jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Expense response invalid';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000142091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000142001','ACP6A_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000142001',
    '00000000-0000-0000-0000-000000142092',
    'finance.expenses','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000142092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_finance_expenses('APPROVED');
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA Expense response invalid';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.review_expense_request(
      '00000000-0000-0000-0000-000000142081',1,TRUE,NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA approved Expense'; END IF;

  IF has_table_privilege('authenticated','public.expense_documents','SELECT')
    OR has_table_privilege('authenticated','public.expense_categories','SELECT')
    OR has_table_privilege('authenticated',
      'public.expense_settlement_requests','SELECT')
    OR has_table_privilege('authenticated',
      'public.expense_additional_disbursement_requests','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Expense read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Expense capability and Cashier channel boundaries are isolated.';
END
$test$;

ROLLBACK;

