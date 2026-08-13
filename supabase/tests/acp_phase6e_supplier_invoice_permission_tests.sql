-- ACP-6E behavior: Supplier Invoice VIEW, Draft, POST, tolerance policy,
-- export, and independent Supplier Payment reference boundaries.
-- SAFETY: all fixture and override rows roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000146091','acp6e-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6E Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000146092','acp6e-finance@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP6E Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000146091','acp6e-admin@example.invalid',
 'ACP6E Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000146092','acp6e-finance@example.invalid',
 'ACP6E Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000146001','ACP146',
  'ACP6E Company','acp6e-company','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000146001',
 '00000000-0000-0000-0000-000000146091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000146001',
 '00000000-0000-0000-0000-000000146092','FINANCE','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000146092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000146001','ACP6E_TEST');
  v_result:=public.get_finance_supplier_invoices();
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000146001'
     OR jsonb_array_length(v_result->'data')<>0
     OR jsonb_array_length(v_result->'lines')<>0
     OR jsonb_array_length(v_result->'policies')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Supplier Invoice response invalid';
  END IF;

  -- Supplier Payment may obtain only its own narrow Invoice references.
  v_result:=public.get_supplier_payment_invoice_references();
  IF jsonb_array_length(v_result)<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier Payment reference tenant leak';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000146091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000146001','ACP6E_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000146001',
    '00000000-0000-0000-0000-000000146092',
    'finance.supplier_invoices','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000146092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_finance_supplier_invoices();
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA composed response invalid';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_supplier_invoice_draft(NULL,NULL,NULL,'ACP6E-INV',
      CURRENT_DATE,NULL,'EXCLUSIVE',NULL,NULL,'[]'::JSONB);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA created Supplier Invoice Draft'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.validate_supplier_invoice(
      '00000000-0000-0000-0000-000000146081',1,
      '00000000-0000-0000-0000-000000146082');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA validated Supplier Invoice'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_supplier_invoice_tolerance_policy(
      NULL,NULL,NULL,0,NULL,0,NULL,CURRENT_DATE,TRUE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA changed tolerance policy'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.export_finance_supplier_invoices(
      clock_timestamp()-INTERVAL '1 day',clock_timestamp());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION
    'TEST_FAILED: LIHAT_SAJA exported Supplier Invoice'; END IF;

  IF has_table_privilege('authenticated',
      'public.supplier_invoice_documents','SELECT')
    OR has_table_privilege('authenticated',
      'public.supplier_invoice_lines','SELECT')
    OR has_table_privilege('authenticated',
      'public.supplier_invoice_allocations','SELECT')
    OR has_table_privilege('authenticated',
      'public.supplier_invoice_tolerance_policies','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Supplier Invoice read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Supplier Invoice capabilities, export, independent Payment references, and direct-read closure are enforced.';
END
$test$;

ROLLBACK;
