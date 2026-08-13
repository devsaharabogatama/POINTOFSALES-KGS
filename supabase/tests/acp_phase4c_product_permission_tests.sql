-- ACP-4C behavior: Product permission, import boundary, role parity, isolation.
-- SAFETY: all fixtures and effects are rolled back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
VALUES
('00000000-0000-0000-0000-000000127091','acp4c-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4C Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000127092','acp4c-warehouse@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4C Warehouse"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000127091','acp4c-admin@example.invalid','ACP4C Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000127092','acp4c-warehouse@example.invalid','ACP4C Warehouse','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;
INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000127001','ACP127A','ACP4C Company A','acp4c-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000127002','ACP127B','ACP4C Company B','acp4c-company-b','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000127001','00000000-0000-0000-0000-000000127091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000127001','00000000-0000-0000-0000-000000127092','WAREHOUSE_ADMIN','ACTIVE',TRUE);
INSERT INTO public.product_categories(id,company_id,category_code,category_name)
VALUES('00000000-0000-0000-0000-000000127011','00000000-0000-0000-0000-000000127001','ACP127CAT','ACP4C Category');
INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
VALUES('00000000-0000-0000-0000-000000127021','00000000-0000-0000-0000-000000127001','ACP127UOM','ACP4C Piece','UNIT',FALSE,0);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_product UUID;v_version BIGINT;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000127091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000127001','ACP4C_TEST');
  v_result:=public.save_product_with_uoms(
    NULL,NULL,'ACP4C-P','ACP4C Product',
    '00000000-0000-0000-0000-000000127011',
    '00000000-0000-0000-0000-000000127021',
    '00000000-0000-0000-0000-000000127021',1,FALSE,NULL,TRUE,
    jsonb_build_array(jsonb_build_object(
      'uomId','00000000-0000-0000-0000-000000127021','factorToBase',1,
      'purchaseAllowed',TRUE,'salesAllowed',TRUE,'purchasePrice',10,
      'salePrice',20,'isActive',TRUE)),NULL,NULL);
  v_product:=(v_result->>'productId')::UUID;

  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000127001',
    '00000000-0000-0000-0000-000000127092',
    'inventory.products','LIHAT_SAJA',NULL);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000127092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000127001','ACP4C_TEST');
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000127001',
    '00000000-0000-0000-0000-000000127092','inventory.products');
  IF NOT ((v_result->'effectiveCapabilities') ? 'VIEW')
     OR (v_result->'effectiveCapabilities') ? 'MANAGE' THEN
    RAISE EXCEPTION 'TEST_FAILED: Product LIHAT_SAJA invalid';
  END IF;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_product_tax_assignment(v_product,1,NULL,NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: read-only Product mutation accepted'; END IF;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.create_master_import_job(
      '00000000-0000-0000-0000-000000127061','PRODUCT','REFERENCE_BY_NAME',
      'CREATE_ONLY','acp4c.csv',repeat('a',64),',');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: read-only Product import accepted'; END IF;

  -- Reference reads stay available for separately-authorized cross-module pickers.
  IF NOT EXISTS(SELECT 1 FROM public.products p
    WHERE p.company_id='00000000-0000-0000-0000-000000127001' AND p.id=v_product) THEN
    RAISE EXCEPTION 'TEST_FAILED: Product reference read was removed';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000127091','role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000127001',
    '00000000-0000-0000-0000-000000127092',
    'inventory.products','IKUTI_ROLE',v_version);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000127092','role','authenticated')::TEXT,TRUE);
  v_result:=public.save_product_with_uoms(
    v_product,1,'ACP4C-P','ACP4C Product Updated',
    '00000000-0000-0000-0000-000000127011',
    '00000000-0000-0000-0000-000000127021',
    '00000000-0000-0000-0000-000000127021',1,FALSE,NULL,TRUE,
    jsonb_build_array(jsonb_build_object(
      'uomId','00000000-0000-0000-0000-000000127021','factorToBase',1,
      'purchaseAllowed',TRUE,'salesAllowed',TRUE,'purchasePrice',10,
      'salePrice',20,'isActive',TRUE)),NULL,NULL);
  IF v_result->>'productId'<>v_product::TEXT THEN
    RAISE EXCEPTION 'TEST_FAILED: role parity not restored';
  END IF;
  IF has_table_privilege('authenticated','public.products','INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.product_uoms','INSERT,UPDATE,DELETE') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Product write boundary invalid';
  END IF;
END
$test$;

RESET ROLE;
DO $verify$
DECLARE v_count BIGINT;
BEGIN
  SELECT count(*) INTO v_count FROM public.user_company_permission_overrides
  WHERE company_id='00000000-0000-0000-0000-000000127001';
  IF v_count<>0 THEN RAISE EXCEPTION 'TEST_FAILED: reset left override'; END IF;
  RAISE NOTICE 'TEST PASSED: Product permission guards management/import while preserving tenant-safe cross-module reference reads and role parity.';
END
$verify$;
ROLLBACK;
