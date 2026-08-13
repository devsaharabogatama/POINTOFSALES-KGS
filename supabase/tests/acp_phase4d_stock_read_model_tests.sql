-- ACP-4D behavior: Stock read presets, guarded RPC, isolation, compatibility.
-- SAFETY: all fixtures, overrides, and audit effects are rolled back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
VALUES
('00000000-0000-0000-0000-000000128091','acp4d-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4D Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000128092','acp4d-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4D Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000128091','acp4d-admin@example.invalid','ACP4D Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000128092','acp4d-finance@example.invalid','ACP4D Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;
INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000128001','ACP128A','ACP4D Company A','acp4d-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000128002','ACP128B','ACP4D Company B','acp4d-company-b','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000128001','00000000-0000-0000-0000-000000128091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000128001','00000000-0000-0000-0000-000000128092','FINANCE','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE
  v_result JSONB;v_stock_version BIGINT;v_movement_version BIGINT;
  v_rejected BOOLEAN;v_before_stock BIGINT;v_before_movement BIGINT;
BEGIN
  SELECT count(*) INTO v_before_stock FROM public.product_stocks;
  SELECT count(*) INTO v_before_movement FROM public.stock_movements;
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000128091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000128001','ACP4D_TEST');

  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000128001',
    '00000000-0000-0000-0000-000000128092',
    'inventory.stock_real','LIHAT_SAJA',NULL);
  v_stock_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000128001',
    '00000000-0000-0000-0000-000000128092',
    'inventory.stock_movements','TANPA_AKSES',NULL);
  v_movement_version:=(v_result->>'masterVersion')::BIGINT;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000128092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000128001','ACP4D_TEST');
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000128001',
    '00000000-0000-0000-0000-000000128092','inventory.stock_real');
  IF NOT ((v_result->'effectiveCapabilities') ? 'VIEW')
     OR (v_result->'effectiveCapabilities') ? 'EXPORT' THEN
    RAISE EXCEPTION 'TEST_FAILED: Stock Real LIHAT_SAJA invalid';
  END IF;
  PERFORM public.get_inventory_stock_overview();

  v_rejected:=FALSE;
  BEGIN PERFORM public.get_inventory_stock_movements();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: hidden Stock Movement RPC accepted';
  END IF;

  -- Raw operational references remain tenant/RLS scoped for other workflows.
  PERFORM count(*) FROM public.product_stocks
    WHERE company_id='00000000-0000-0000-0000-000000128001';

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000128091','role','authenticated')::TEXT,TRUE);
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_user_permission_override(
      '00000000-0000-0000-0000-000000128002',
      '00000000-0000-0000-0000-000000128092',
      'inventory.stock_real','TANPA_AKSES',NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='PERMISSION_TARGET_ACCESS_DENIED' THEN v_rejected:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company override accepted'; END IF;

  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000128001',
    '00000000-0000-0000-0000-000000128092',
    'inventory.stock_real','IKUTI_ROLE',v_stock_version);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000128001',
    '00000000-0000-0000-0000-000000128092',
    'inventory.stock_movements','IKUTI_ROLE',v_movement_version);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000128092','role','authenticated')::TEXT,TRUE);
  PERFORM public.get_inventory_stock_overview();
  PERFORM public.get_inventory_stock_movements();
  IF (SELECT count(*) FROM public.product_stocks)<>v_before_stock
     OR (SELECT count(*) FROM public.stock_movements)<>v_before_movement THEN
    RAISE EXCEPTION 'TEST_FAILED: read permission changed Stock history';
  END IF;
  IF has_table_privilege('authenticated','public.product_stocks','INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.product_batches','INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.stock_movements','INSERT,UPDATE,DELETE') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Stock write boundary invalid';
  END IF;
END
$test$;

RESET ROLE;
DO $verify$
BEGIN
  IF EXISTS(SELECT 1 FROM public.user_company_permission_overrides
    WHERE company_id='00000000-0000-0000-0000-000000128001'
      AND permission_key IN('inventory.stock_real','inventory.stock_movements')) THEN
    RAISE EXCEPTION 'TEST_FAILED: reset left Stock read override';
  END IF;
  RAISE NOTICE 'TEST PASSED: Stock Real and Stock Movement permissions are separated, tenant-safe, read-only, and role-compatible.';
END
$verify$;
ROLLBACK;
