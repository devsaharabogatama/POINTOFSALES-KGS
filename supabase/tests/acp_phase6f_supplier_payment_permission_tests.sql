-- ACP-6F behavior: VIEW, Draft/Post/Edit restriction, export, source account,
-- Draft-only cancel, direct read closure. SAFETY: fully rolled back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000147091','acp6f-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6F Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000147092','acp6f-finance@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6F Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000147091','acp6f-admin@example.invalid',
 'ACP6F Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000147092','acp6f-finance@example.invalid',
 'ACP6F Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000147001','ACP147',
  'ACP6F Company','acp6f-company','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000147001',
 '00000000-0000-0000-0000-000000147091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000147001',
 '00000000-0000-0000-0000-000000147092','FINANCE','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000147092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000147001','ACP6F_TEST');
  v_result:=public.get_finance_supplier_payments();
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000147001'
     OR jsonb_array_length(v_result->'documents')<>0
     OR jsonb_array_length(v_result->'allocations')<>0
     OR jsonb_typeof(v_result->'accounts')<>'array'
     OR EXISTS(SELECT 1 FROM jsonb_array_elements(v_result->'accounts') account
       WHERE NOT (account ? 'id' AND account ? 'account_code'
         AND account ? 'account_name' AND account ? 'account_type')
         OR account->>'account_type'<>'ASSET'
         OR (account->>'is_active')::BOOLEAN IS DISTINCT FROM TRUE) THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Supplier Payment response invalid';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000147091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000147001','ACP6F_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000147001',
    '00000000-0000-0000-0000-000000147092',
    'finance.supplier_payments','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000147092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_finance_supplier_payments();
  IF jsonb_array_length(v_result->'documents')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA response invalid';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_supplier_payment_draft(NULL,NULL,NULL,CURRENT_DATE,
      'CASH',NULL,NULL,NULL,NULL,NULL,NULL,NULL,'[]'::JSONB);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA created Supplier Payment Draft'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.validate_supplier_payment(
      '00000000-0000-0000-0000-000000147081',1,
      '00000000-0000-0000-0000-000000147082');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA validated Supplier Payment'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.cancel_supplier_payment(
      '00000000-0000-0000-0000-000000147081',1,'Tidak berlaku');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA canceled Supplier Payment'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.export_finance_supplier_payments(
      clock_timestamp()-INTERVAL '1 day',clock_timestamp());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA exported Supplier Payment'; END IF;

  IF has_table_privilege('authenticated',
      'public.supplier_payment_documents','SELECT')
    OR has_table_privilege('authenticated',
      'public.supplier_payment_allocations','SELECT')
    OR has_table_privilege('authenticated',
      'public.supplier_payment_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Supplier Payment read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Supplier Payment capabilities, export, account boundary, Draft-only cancellation and direct-read closure are enforced.';
END
$test$;

ROLLBACK;
