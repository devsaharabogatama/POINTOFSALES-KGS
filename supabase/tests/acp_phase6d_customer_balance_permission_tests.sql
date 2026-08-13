-- ACP-6D behavior: Customer Balance VIEW, MANAGE, APPROVE/REVIEW and EXPORT
-- are restrictable without exposing direct tables.
-- SAFETY: every fixture and override rolls back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000145091','acp6d-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6D Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000145092','acp6d-finance@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6D Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000145091','acp6d-admin@example.invalid',
 'ACP6D Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000145092','acp6d-finance@example.invalid',
 'ACP6D Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000145001','ACP145',
  'ACP6D Company','acp6d-company','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000145001',
 '00000000-0000-0000-0000-000000145091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000145001',
 '00000000-0000-0000-0000-000000145092','FINANCE','ACTIVE',TRUE);

-- A synthetic Company is provisioned with optional features disabled. Enable
-- the rollback-only entitlement explicitly so this test evaluates ACP
-- capabilities rather than the separate feature gate.
INSERT INTO public.company_features(
  company_id,feature_code,is_enabled,config,updated_by
) VALUES(
  '00000000-0000-0000-0000-000000145001',
  'customer_balance_enabled',TRUE,'{}'::JSONB,
  '00000000-0000-0000-0000-000000145091'
) ON CONFLICT(company_id,feature_code) DO UPDATE SET
  is_enabled=EXCLUDED.is_enabled,config=EXCLUDED.config,
  updated_by=EXCLUDED.updated_by,updated_at=clock_timestamp();

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000145092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000145001','ACP6D_TEST');
  v_result:=public.get_finance_customer_balances();
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000145001'
     OR jsonb_array_length(v_result->'customers')<>0
     OR jsonb_array_length(v_result->'requests')<>0
     OR jsonb_array_length(v_result->'stores')<>0
     OR jsonb_array_length(v_result->'actors')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Customer Balance response invalid';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000145091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000145001','ACP6D_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000145001',
    '00000000-0000-0000-0000-000000145092',
    'finance.customer_balances','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000145092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_finance_customer_balances();
  IF jsonb_array_length(v_result->'customers')<>0
     OR jsonb_array_length(v_result->'requests')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA response invalid';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.request_customer_balance_correction(
      '00000000-0000-0000-0000-000000145081',
      '00000000-0000-0000-0000-000000145082','CREDIT',100,
      'CASH_DRAWER','ACP6D restricted test',NULL,
      '00000000-0000-0000-0000-000000145083');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA requested correction'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.review_customer_balance_correction(
      '00000000-0000-0000-0000-000000145084',1,'APPROVE',NULL,
      '00000000-0000-0000-0000-000000145085');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA approved correction'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.export_finance_customer_balances(
      '2026-08-01 00:00:00+00','2026-08-31 23:59:59+00');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA exported Customer Balance'; END IF;

  IF has_table_privilege('authenticated',
      'public.customer_balance_company_policies','SELECT')
    OR has_table_privilege('authenticated',
      'public.customer_balance_correction_requests','SELECT')
    OR has_table_privilege('authenticated',
      'public.customer_balance_ledger_entries','SELECT')
    OR has_table_privilege('authenticated',
      'public.customer_balance_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Customer Balance read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Customer Balance VIEW, MANAGE, maker-checker, EXPORT, and direct-read boundaries are enforced.';
END
$test$;

ROLLBACK;
