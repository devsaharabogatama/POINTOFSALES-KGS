-- ACP-4F behavior: Adjustment presets, trusted Opname core, and isolation.
-- SAFETY: all identities, memberships, overrides, and audit effects roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
VALUES
('00000000-0000-0000-0000-000000130091','acp4f-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4F Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000130092','acp4f-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4F Finance"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000130093','acp4f-manager@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4F Manager"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000130091','acp4f-admin@example.invalid','ACP4F Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000130092','acp4f-finance@example.invalid','ACP4F Finance','cashier'::public.user_role),
('00000000-0000-0000-0000-000000130093','acp4f-manager@example.invalid','ACP4F Manager','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;
INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000130001','ACP130A','ACP4F Company A','acp4f-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000130002','ACP130B','ACP4F Company B','acp4f-company-b','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000130001','00000000-0000-0000-0000-000000130091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000130001','00000000-0000-0000-0000-000000130092','FINANCE','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000130001','00000000-0000-0000-0000-000000130093','STORE_MANAGER','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_version BIGINT;v_manager_version BIGINT;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000130091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000130001','ACP4F_TEST');

  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000130001',
    '00000000-0000-0000-0000-000000130092',
    'inventory.stock_adjustments','TANPA_AKSES',NULL);
  v_version:=(v_result->>'masterVersion')::BIGINT;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000130092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000130001','ACP4F_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.get_inventory_stock_adjustments();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: hidden Adjustment read accepted'; END IF;

  v_rejected:=FALSE;
  BEGIN PERFORM public.save_stock_adjustment_document(
    NULL,NULL,NULL,current_date,NULL,'[]'::JSONB);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance Adjustment create accepted'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000130091','role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000130001',
    '00000000-0000-0000-0000-000000130092',
    'inventory.stock_adjustments','IKUTI_ROLE',v_version);
  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000130001',
    '00000000-0000-0000-0000-000000130093',
    'inventory.stock_adjustments','OPERASIONAL',NULL);
  v_manager_version:=(v_result->>'masterVersion')::BIGINT;

  v_rejected:=FALSE;
  BEGIN PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000130002',
    '00000000-0000-0000-0000-000000130092',
    'inventory.stock_adjustments','TANPA_AKSES',NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='PERMISSION_TARGET_ACCESS_DENIED' THEN v_rejected:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company override accepted'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000130092','role','authenticated')::TEXT,TRUE);
  PERFORM public.get_inventory_stock_adjustments();
  IF to_regprocedure('public.get_inventory_stock_opnames()') IS NOT NULL THEN
    PERFORM public.get_inventory_stock_opnames();
  ELSE
    PERFORM public.get_stock_opname_adjustment_references();
  END IF;
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000130001',
    '00000000-0000-0000-0000-000000130092','inventory.stock_adjustments');
  IF NOT ((v_result->'effectiveCapabilities') ? 'VIEW')
     OR (v_result->'effectiveCapabilities') ? 'CREATE_DRAFT'
     OR (v_result->'effectiveCapabilities') ? 'POST' THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance Adjustment baseline changed';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000130093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000130001','ACP4F_TEST');
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000130001',
    '00000000-0000-0000-0000-000000130093','inventory.stock_adjustments');
  IF NOT ((v_result->'effectiveCapabilities') ?& ARRAY[
    'VIEW','CREATE_DRAFT','EDIT_DRAFT'])
     OR (v_result->'effectiveCapabilities') ? 'POST'
     OR (v_result->'effectiveCapabilities') ? 'CANCEL_FINAL' THEN
    RAISE EXCEPTION 'TEST_FAILED: operational Adjustment preset invalid';
  END IF;
  v_rejected:=FALSE;
  BEGIN PERFORM public.post_stock_adjustment(NULL,NULL,NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: operational Adjustment post accepted'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000130091','role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000130001',
    '00000000-0000-0000-0000-000000130093',
    'inventory.stock_adjustments','IKUTI_ROLE',v_manager_version);

  IF has_table_privilege('authenticated','public.stock_adjustment_reasons','SELECT')
     OR has_table_privilege('authenticated','public.stock_adjustment_documents','SELECT')
     OR has_table_privilege('authenticated','public.stock_adjustment_lines','SELECT')
     OR has_table_privilege('authenticated','public.stock_adjustment_fifo_allocations','SELECT')
     OR has_table_privilege('authenticated','public.stock_adjustment_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Adjustment table read remains open';
  END IF;
END
$test$;

RESET ROLE;
DO $verify$
BEGIN
  IF has_function_privilege('authenticated',
    'private.post_stock_opname(uuid,bigint,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: private Opname core browser-executable';
  END IF;
  IF EXISTS(SELECT 1 FROM public.user_company_permission_overrides
    WHERE company_id='00000000-0000-0000-0000-000000130001'
      AND permission_key='inventory.stock_adjustments') THEN
    RAISE EXCEPTION 'TEST_FAILED: reset left Adjustment override';
  END IF;
  RAISE NOTICE 'TEST PASSED: Stock Adjustment permission is separated, tenant-safe, direct reads are closed, and Stock Opname retains a trusted core.';
END
$verify$;
ROLLBACK;
