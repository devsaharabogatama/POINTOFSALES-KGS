-- ACP-5D behavior: Purchase Return VIEW and management capability restriction.
-- SAFETY: every identity, membership, override, and context rolls back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000137091','acp5d-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP5D Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000137092','acp5d-manager@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP5D Manager"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000137091','acp5d-admin@example.invalid',
 'ACP5D Admin','cashier'),
('00000000-0000-0000-0000-000000137092','acp5d-manager@example.invalid',
 'ACP5D Manager','cashier')
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES
('00000000-0000-0000-0000-000000137001','ACP137A','ACP5D Company A',
 'acp5d-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000137002','ACP137B','ACP5D Company B',
 'acp5d-company-b','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000137001',
 '00000000-0000-0000-0000-000000137091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000137002',
 '00000000-0000-0000-0000-000000137091','COMPANY_ADMIN','ACTIVE',FALSE),
('00000000-0000-0000-0000-000000137001',
 '00000000-0000-0000-0000-000000137092','STORE_MANAGER','ACTIVE',TRUE);
INSERT INTO public.user_company_permission_overrides(
  company_id,user_id,permission_key,restriction_preset,created_by,updated_by)
VALUES('00000000-0000-0000-0000-000000137001',
 '00000000-0000-0000-0000-000000137092','purchase.purchase_returns',
 'OPERASIONAL','00000000-0000-0000-0000-000000137091',
 '00000000-0000-0000-0000-000000137091');

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_rejected BOOLEAN:=FALSE;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000137092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000137001','ACP5D_TEST');
  v_result:=public.get_purchase_returns();
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: empty manager Return workspace invalid';
  END IF;
  BEGIN
    PERFORM public.review_purchase_return(
      '00000000-0000-0000-0000-000000137099',1,'APPROVE',NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: OPERASIONAL manager retained REVIEW';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000137091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000137002','ACP5D_TEST');
  v_result:=public.get_purchase_returns();
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Return data leaked';
  END IF;
  IF has_table_privilege('authenticated','public.purchase_return_documents',
       'SELECT,INSERT,UPDATE,DELETE')
     OR NOT has_function_privilege('authenticated',
       'public.get_purchase_returns()','EXECUTE')
     OR has_function_privilege('anon','public.get_purchase_returns()','EXECUTE')
     OR has_schema_privilege('authenticated','private','USAGE') THEN
    RAISE EXCEPTION 'TEST_FAILED: Purchase Return browser boundary invalid';
  END IF;
  RAISE NOTICE 'TEST PASSED: Purchase Return is capability-aware, tenant-safe, and private-core isolated.';
END $test$;

ROLLBACK;
