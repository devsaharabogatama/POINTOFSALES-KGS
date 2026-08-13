-- ACP-4E behavior: Stock Transfer presets, guarded RPCs, and isolation.
-- SAFETY: all identities, memberships, overrides, and audit effects roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
VALUES
('00000000-0000-0000-0000-000000129091','acp4e-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4E Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000129092','acp4e-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4E Finance"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000129093','acp4e-warehouse@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4E Warehouse"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000129091','acp4e-admin@example.invalid','ACP4E Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000129092','acp4e-finance@example.invalid','ACP4E Finance','cashier'::public.user_role),
('00000000-0000-0000-0000-000000129093','acp4e-warehouse@example.invalid','ACP4E Warehouse','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;
INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000129001','ACP129A','ACP4E Company A','acp4e-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000129002','ACP129B','ACP4E Company B','acp4e-company-b','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000129001','00000000-0000-0000-0000-000000129091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000129001','00000000-0000-0000-0000-000000129092','FINANCE','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000129001','00000000-0000-0000-0000-000000129093','WAREHOUSE_ADMIN','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_version BIGINT;v_warehouse_version BIGINT;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000129091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000129001','ACP4E_TEST');

  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000129001',
    '00000000-0000-0000-0000-000000129092',
    'inventory.stock_transfers','TANPA_AKSES',NULL);
  v_version:=(v_result->>'masterVersion')::BIGINT;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000129092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000129001','ACP4E_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.get_inventory_stock_transfers();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: hidden Transfer read accepted'; END IF;

  v_rejected:=FALSE;
  BEGIN PERFORM public.save_stock_transfer_document(
    NULL,NULL,NULL,NULL,current_date,NULL,'[]'::JSONB);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance Transfer create accepted'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000129091','role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000129001',
    '00000000-0000-0000-0000-000000129092',
    'inventory.stock_transfers','IKUTI_ROLE',v_version);

  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000129001',
    '00000000-0000-0000-0000-000000129093',
    'inventory.stock_transfers','OPERASIONAL',NULL);
  v_warehouse_version:=(v_result->>'masterVersion')::BIGINT;

  v_rejected:=FALSE;
  BEGIN PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000129002',
    '00000000-0000-0000-0000-000000129092',
    'inventory.stock_transfers','TANPA_AKSES',NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='PERMISSION_TARGET_ACCESS_DENIED' THEN v_rejected:=TRUE;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company override accepted'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000129092','role','authenticated')::TEXT,TRUE);
  PERFORM public.get_inventory_stock_transfers();
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000129001',
    '00000000-0000-0000-0000-000000129092','inventory.stock_transfers');
  IF NOT ((v_result->'effectiveCapabilities') ? 'VIEW')
     OR (v_result->'effectiveCapabilities') ? 'CREATE_DRAFT'
     OR (v_result->'effectiveCapabilities') ? 'POST' THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance Transfer baseline changed';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000129093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000129001','ACP4E_TEST');
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000129001',
    '00000000-0000-0000-0000-000000129093','inventory.stock_transfers');
  IF NOT ((v_result->'effectiveCapabilities') ?& ARRAY[
    'VIEW','CREATE_DRAFT','EDIT_DRAFT'])
     OR (v_result->'effectiveCapabilities') ? 'POST'
     OR (v_result->'effectiveCapabilities') ? 'CANCEL_FINAL' THEN
    RAISE EXCEPTION 'TEST_FAILED: operational Transfer preset invalid';
  END IF;
  v_rejected:=FALSE;
  BEGIN PERFORM public.post_stock_transfer(NULL,NULL,NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: operational Transfer post accepted'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000129091','role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000129001',
    '00000000-0000-0000-0000-000000129093',
    'inventory.stock_transfers','IKUTI_ROLE',v_warehouse_version);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000129093','role','authenticated')::TEXT,TRUE);
  v_result:=public.resolve_user_permission(
    '00000000-0000-0000-0000-000000129001',
    '00000000-0000-0000-0000-000000129093','inventory.stock_transfers');
  IF NOT ((v_result->'effectiveCapabilities') ?& ARRAY[
    'VIEW','CREATE_DRAFT','EDIT_DRAFT','POST','CANCEL_FINAL']) THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse Admin Transfer baseline changed';
  END IF;

  IF has_table_privilege('authenticated','public.stock_transfer_documents','SELECT')
     OR has_table_privilege('authenticated','public.stock_transfer_lines','SELECT')
     OR has_table_privilege('authenticated','public.stock_transfer_fifo_allocations','SELECT')
     OR has_table_privilege('authenticated','public.stock_transfer_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Transfer table read remains open';
  END IF;
END
$test$;

RESET ROLE;
DO $verify$
BEGIN
  IF EXISTS(SELECT 1 FROM public.user_company_permission_overrides
    WHERE company_id='00000000-0000-0000-0000-000000129001'
      AND permission_key='inventory.stock_transfers') THEN
    RAISE EXCEPTION 'TEST_FAILED: reset left Transfer override';
  END IF;
  RAISE NOTICE 'TEST PASSED: Stock Transfer permission is capability-separated, tenant-safe, and direct browser reads are closed.';
END
$verify$;
ROLLBACK;
