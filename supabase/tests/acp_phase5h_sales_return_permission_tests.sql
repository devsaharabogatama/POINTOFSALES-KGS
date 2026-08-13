-- ACP-5H behavior: Backoffice VIEW and final actions are restrictable.
-- SAFETY: all identities, overrides, and fixture rows roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000141091','acp5h-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP5H Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000141092','acp5h-manager@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP5H Manager"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000141091','acp5h-admin@example.invalid',
 'ACP5H Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000141092','acp5h-manager@example.invalid',
 'ACP5H Manager','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000141001','ACP141',
  'ACP5H Company','acp5h-company','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000141001',
 '00000000-0000-0000-0000-000000141091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000141001',
 '00000000-0000-0000-0000-000000141092','STORE_MANAGER','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000141092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000141001','ACP5H_TEST');
  v_result:=public.get_sales_returns(NULL);
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000141001'
     OR jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Return response invalid';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000141091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000141001','ACP5H_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000141001',
    '00000000-0000-0000-0000-000000141092',
    'sales.sales_returns','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000141092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_sales_returns('DRAFT');
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA Return response invalid';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.post_sales_return(
      '00000000-0000-0000-0000-000000141081',1,
      '00000000-0000-0000-0000-000000141082');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA posted Return'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.cancel_sales_return_draft(
      '00000000-0000-0000-0000-000000141081',1,'Denied');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA canceled Return'; END IF;

  v_rejected:=FALSE;
  BEGIN PERFORM public.get_pos_returnable_sales(NULL,50);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='OPEN_CASHIER_SESSION_REQUIRED' THEN v_rejected:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: Cashier source opened without active session'; END IF;

  IF has_table_privilege('authenticated','public.sales_return_documents','SELECT')
    OR has_table_privilege('authenticated','public.sales_return_lines','SELECT')
    OR has_table_privilege('authenticated','public.sales_return_refunds','SELECT')
    OR has_table_privilege('authenticated','public.sales_return_audit','SELECT')
    OR has_table_privilege('authenticated',
      'public.sales_return_fifo_restorations','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Sales Return read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Sales Return VIEW/final actions and Cashier session authority are isolated.';
END
$test$;

ROLLBACK;
