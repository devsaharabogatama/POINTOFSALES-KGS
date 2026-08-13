-- ACP-4B behavior: enforced Master Inventory restrictions and role parity.
-- SAFETY: all fixtures, overrides, masters, and audits are rolled back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
VALUES
('00000000-0000-0000-0000-000000126091','acp4b-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4B Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000126092','acp4b-warehouse@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4B Warehouse"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000126091','acp4b-admin@example.invalid','ACP4B Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000126092','acp4b-warehouse@example.invalid','ACP4B Warehouse','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000126001','ACP126A','ACP4B Company A','acp4b-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000126002','ACP126B','ACP4B Company B','acp4b-company-b','ACTIVE');

INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000126001','00000000-0000-0000-0000-000000126091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000126001','00000000-0000-0000-0000-000000126092','WAREHOUSE_ADMIN','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_version BIGINT;v_rejected BOOLEAN;v_count BIGINT;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000126001','ACP4B_TEST');

  v_result:=public.save_inventory_product_category(
    NULL,NULL,'ACP4B Category',TRUE);
  IF v_result->>'action'<>'CREATE' THEN
    RAISE EXCEPTION 'TEST_FAILED: baseline Category write failed';
  END IF;

  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000126001',
    '00000000-0000-0000-0000-000000126092',
    'inventory.master_data','LIHAT_SAJA',NULL);
  v_version:=(v_result->>'masterVersion')::BIGINT;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000126001','ACP4B_TEST');
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000126001',
    '00000000-0000-0000-0000-000000126092','inventory.master_data');
  IF NOT (v_result->>'enforced')::BOOLEAN
     OR NOT ((v_result->'effectiveCapabilities') ? 'VIEW')
     OR (v_result->'effectiveCapabilities') ? 'MANAGE' THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA resolution invalid';
  END IF;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_inventory_uom(
      NULL,NULL,'ACP4B Rejected UOM','UNIT',FALSE,0::SMALLINT,TRUE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: read-only UOM write accepted'; END IF;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_product_category_tax_assignment(
      '00000000-0000-0000-0000-000000126099',1,NULL,NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: read-only Tax write accepted'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126091','role','authenticated')::TEXT,TRUE);
  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000126001',
    '00000000-0000-0000-0000-000000126092',
    'inventory.master_data','OPERASIONAL',v_version);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126092','role','authenticated')::TEXT,TRUE);
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_inventory_product_category(NULL,NULL,'ACP4B Rejected Category',TRUE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: OPERASIONAL granted MANAGE'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126091','role','authenticated')::TEXT,TRUE);
  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000126001',
    '00000000-0000-0000-0000-000000126092',
    'inventory.master_data','TANPA_AKSES',v_version);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126092','role','authenticated')::TEXT,TRUE);
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000126001',
    '00000000-0000-0000-0000-000000126092','inventory.master_data');
  IF (v_result->'effectiveCapabilities') ? 'VIEW' THEN
    RAISE EXCEPTION 'TEST_FAILED: TANPA_AKSES retained VIEW';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126091','role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000126001',
    '00000000-0000-0000-0000-000000126092',
    'inventory.master_data','IKUTI_ROLE',v_version);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000126092','role','authenticated')::TEXT,TRUE);
  v_result:=public.save_inventory_warehouse(
    NULL,NULL,'ACP4B Warehouse','CENTRAL',NULL,NULL,FALSE,TRUE,TRUE);
  IF v_result->>'action'<>'CREATE' THEN
    RAISE EXCEPTION 'TEST_FAILED: role baseline not restored';
  END IF;

  IF has_table_privilege(
       'authenticated','public.product_categories','INSERT,UPDATE,DELETE')
     OR has_column_privilege(
       'authenticated','public.product_categories','category_name','INSERT')
     OR has_column_privilege(
       'authenticated','public.product_categories','category_name','UPDATE') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Category write remains';
  END IF;
  SELECT count(*) INTO v_count FROM public.inventory_master_write_audit
  WHERE company_id='00000000-0000-0000-0000-000000126001'
    AND master_type IN('PRODUCT_CATEGORY','WAREHOUSE');
  IF v_count<>2 THEN RAISE EXCEPTION 'TEST_FAILED: master audit count %',v_count; END IF;
END
$test$;

RESET ROLE;
DO $verify$
DECLARE v_count BIGINT;
BEGIN
  SELECT count(*) INTO v_count FROM public.user_company_permission_overrides
  WHERE company_id='00000000-0000-0000-0000-000000126001';
  IF v_count<>0 THEN RAISE EXCEPTION 'TEST_FAILED: reset left override'; END IF;
  SELECT count(*) INTO v_count FROM public.user_company_permission_audit
  WHERE company_id='00000000-0000-0000-0000-000000126001'
    AND permission_key='inventory.master_data';
  IF v_count<>4 THEN RAISE EXCEPTION 'TEST_FAILED: permission audit count %',v_count; END IF;
  RAISE NOTICE 'TEST PASSED: Master Inventory enforcement is tenant-safe, role-compatible, restriction-only, guarded, and audited.';
END
$verify$;

ROLLBACK;
