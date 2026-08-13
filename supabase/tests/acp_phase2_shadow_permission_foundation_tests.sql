-- ACP-2 behavior: restriction-only permission remains shadow and tenant-safe.
-- SAFETY: all fixtures, overrides, and audit rows are rolled back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
VALUES
('00000000-0000-0000-0000-000000124091','acp-owner@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP Owner"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000124092','acp-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000124093','acp-warehouse@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP Warehouse"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000124094','acp-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP Finance"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000124095','acp-super@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP Super"}'::JSONB,FALSE,'authenticated','authenticated',now());

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000124091','acp-owner@example.invalid','ACP Owner','cashier'::public.user_role),
('00000000-0000-0000-0000-000000124092','acp-admin@example.invalid','ACP Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000124093','acp-warehouse@example.invalid','ACP Warehouse','cashier'::public.user_role),
('00000000-0000-0000-0000-000000124094','acp-finance@example.invalid','ACP Finance','cashier'::public.user_role),
('00000000-0000-0000-0000-000000124095','acp-super@example.invalid','ACP Super','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET
  email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000124001','ACP124A','ACP Company A','acp-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000124002','ACP124B','ACP Company B','acp-company-b','ACTIVE');

INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124091','COMPANY_OWNER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124092','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','WAREHOUSE_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000124002','00000000-0000-0000-0000-000000124094','FINANCE','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE
  v_result JSONB;v_version BIGINT;v_rejected BOOLEAN;v_super UUID;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','00000000-0000-0000-0000-000000124092','role','authenticated')::TEXT,TRUE);

  v_result:=public.resolve_user_permission('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','inventory.stock_transfers');
  IF v_result->>'restrictionPreset'<>'IKUTI_ROLE' OR (v_result->>'enforced')::BOOLEAN
     OR NOT ((v_result->'effectiveCapabilities') ? 'POST') THEN
    RAISE EXCEPTION 'TEST_FAILED: baseline shadow resolution invalid';
  END IF;

  v_result:=public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','inventory.stock_transfers','OPERASIONAL',NULL);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  IF v_result->>'action'<>'CREATE_OVERRIDE' OR (v_result->>'enforced')::BOOLEAN THEN
    RAISE EXCEPTION 'TEST_FAILED: shadow override create invalid';
  END IF;
  v_result:=public.resolve_user_permission('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','inventory.stock_transfers');
  IF NOT ((v_result->'effectiveCapabilities') ? 'CREATE_DRAFT')
     OR (v_result->'effectiveCapabilities') ? 'POST' THEN
    RAISE EXCEPTION 'TEST_FAILED: operational restriction invalid';
  END IF;

  v_result:=public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','inventory.stock_transfers','OPERASIONAL',v_version);
  IF v_result->>'action'<>'EXACT_RETRY' THEN RAISE EXCEPTION 'TEST_FAILED: exact retry invalid'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','inventory.stock_transfers','LIHAT_SAJA',99);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='MASTER_VERSION_CONFLICT' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: stale version accepted'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124092','inventory.products','TANPA_AKSES',NULL);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='PERMISSION_TARGET_ACCESS_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: self override accepted'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_user_permission_override('00000000-0000-0000-0000-000000124002','00000000-0000-0000-0000-000000124094','finance.journals_reports','TANPA_AKSES',NULL);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='PERMISSION_TARGET_ACCESS_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company target accepted'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','platform.companies','TANPA_AKSES',NULL);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='PERMISSION_KEY_NOT_CUSTOMIZABLE' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: protected permission customized'; END IF;

  v_super:='00000000-0000-0000-0000-000000124095';
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_super,'role','authenticated')::TEXT,TRUE);
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124091','inventory.products','TANPA_AKSES',NULL);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='LAST_COMPANY_OWNER_ACCESS_PROTECTED' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: last Company Owner protection missing'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','00000000-0000-0000-0000-000000124092','role','authenticated')::TEXT,TRUE);

  v_result:=public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','inventory.stock_transfers','LIHAT_SAJA',v_version);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.save_user_permission_override('00000000-0000-0000-0000-000000124001','00000000-0000-0000-0000-000000124093','inventory.stock_transfers','IKUTI_ROLE',v_version);
  IF v_result->>'action'<>'RESET_OVERRIDE' THEN RAISE EXCEPTION 'TEST_FAILED: reset invalid'; END IF;

  IF has_table_privilege('authenticated','public.user_company_permission_overrides','INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.user_company_permission_audit','INSERT,UPDATE,DELETE') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct permission write boundary invalid';
  END IF;
END
$test$;

-- Internal persistence assertions intentionally run as the migration/test
-- operator. Browser roles must not receive SELECT access to these tables.
RESET ROLE;

DO $verify_internal$
DECLARE
  v_count BIGINT;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.user_company_permission_overrides
  WHERE company_id='00000000-0000-0000-0000-000000124001';
  IF v_count<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: reset left override';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.user_company_permission_audit
  WHERE company_id='00000000-0000-0000-0000-000000124001';
  IF v_count<>3 THEN
    RAISE EXCEPTION 'TEST_FAILED: audit count %, expected 3',v_count;
  END IF;

  RAISE NOTICE 'TEST PASSED: custom permission is restriction-only, tenant-safe, versioned, audited, and remains SHADOW.';
END
$verify_internal$;

ROLLBACK;
