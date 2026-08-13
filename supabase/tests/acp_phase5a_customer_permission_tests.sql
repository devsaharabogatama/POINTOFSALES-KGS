-- ACP-5A behavior: Customer management, credit split, restriction, and tenant.
-- SAFETY: all identities, Customers, overrides, and audits roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000134091','acp5a-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5A Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000134092','acp5a-manager@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5A Manager"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000134093','acp5a-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5A Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000134091','acp5a-admin@example.invalid','ACP5A Admin','cashier'),
('00000000-0000-0000-0000-000000134092','acp5a-manager@example.invalid','ACP5A Manager','cashier'),
('00000000-0000-0000-0000-000000134093','acp5a-finance@example.invalid','ACP5A Finance','cashier')
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000134001','ACP134A','ACP5A Company A','acp5a-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000134002','ACP134B','ACP5A Company B','acp5a-company-b','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000134001','00000000-0000-0000-0000-000000134091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000134002','00000000-0000-0000-0000-000000134091','COMPANY_ADMIN','ACTIVE',FALSE),
('00000000-0000-0000-0000-000000134001','00000000-0000-0000-0000-000000134092','STORE_MANAGER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000134001','00000000-0000-0000-0000-000000134093','FINANCE','ACTIVE',TRUE);

INSERT INTO public.customer_categories(
  id,company_id,category_code,category_name,is_active
) VALUES(
  '00000000-0000-0000-0000-000000134011',
  '00000000-0000-0000-0000-000000134001','ACP5A','ACP5A Category',TRUE);

INSERT INTO public.user_company_permission_overrides(
  company_id,user_id,permission_key,restriction_preset,created_by,updated_by
) VALUES(
  '00000000-0000-0000-0000-000000134001',
  '00000000-0000-0000-0000-000000134092',
  'contacts.customers','TANPA_AKSES',
  '00000000-0000-0000-0000-000000134091',
  '00000000-0000-0000-0000-000000134091');

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_customer UUID;
  v_category UUID:='00000000-0000-0000-0000-000000134011';
  v_version BIGINT;v_code TEXT;
  v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000134091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000134001','ACP5A_TEST');
  v_result:=public.save_customer_with_pricelist(
    NULL,NULL,NULL,'ACP5A Customer',v_category,'0800',NULL,'Address',
    'BUSINESS',0,NULL,NULL,TRUE,NULL,NULL);
  v_customer:=(v_result->>'customerId')::UUID;
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.get_contacts_customers(TRUE);
  SELECT item->>'code' INTO v_code
  FROM jsonb_array_elements(v_result->'data') item
  WHERE (item->>'id')::UUID=v_customer;
  IF jsonb_array_length(v_result->'data')<>2
     OR jsonb_array_length(v_result->'categories')<>2 OR v_code IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Customer workspace invalid';
  END IF;
  IF NOT ((public.resolve_user_permission(
    '00000000-0000-0000-0000-000000134001',
    '00000000-0000-0000-0000-000000134091',
    'contacts.customers')->'effectiveCapabilities') ? 'IMPORT') THEN
    RAISE EXCEPTION 'TEST_FAILED: Admin explicit Customer import missing';
  END IF;

  -- Finance can change credit only, but cannot mutate Customer identity.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000134093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000134001','ACP5A_TEST');
  v_result:=public.save_customer_with_pricelist(
    v_customer,v_version,v_code,
    'ACP5A Customer',v_category,'0800',NULL,'Address','BUSINESS',5000,30,
    NULL,TRUE,NULL,NULL);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_customer_with_pricelist(
      v_customer,v_version,v_code,
      'Forbidden Rename',v_category,'0800',NULL,'Address','BUSINESS',5000,30,
      NULL,TRUE,NULL,NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance changed Customer identity';
  END IF;
  IF jsonb_array_length(public.get_finance_customer_balance_references())<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance Customer reference invalid';
  END IF;

  -- Restriction can only reduce the Store Manager baseline.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000134092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000134001','ACP5A_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.get_contacts_customers(TRUE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: restricted Manager viewed Customer';
  END IF;

  -- Company switch cannot expose Company A Customer.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000134091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000134002','ACP5A_TEST');
  v_result:=public.get_contacts_customers(TRUE);
  IF jsonb_array_length(v_result->'data')<>1
     OR (v_result->'data'->0->>'is_system_customer')::BOOLEAN IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Customer leaked';
  END IF;

  IF has_table_privilege('authenticated','public.customers','SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.customer_categories','SELECT,INSERT,UPDATE,DELETE')
     OR NOT has_function_privilege('authenticated',
       'public.get_contacts_customers(boolean)','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_contacts_customers(boolean)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.save_customer_category(uuid,bigint,text,text,boolean)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer browser boundary invalid';
  END IF;

  RAISE NOTICE 'TEST PASSED: Customer management is capability-aware, credit-separated, restricted, and tenant-safe.';
END
$test$;

ROLLBACK;
