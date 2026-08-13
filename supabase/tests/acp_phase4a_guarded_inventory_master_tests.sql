-- ACP-4A behavior: guarded UOM/Warehouse writes and read-only Store/Terminal.
-- SAFETY: every fixture and audit row is rolled back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
VALUES
('00000000-0000-0000-0000-000000125091','acp4a-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4A Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000125092','acp4a-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4A Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000125091','acp4a-admin@example.invalid','ACP4A Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000125092','acp4a-finance@example.invalid','ACP4A Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000125001','ACP125A','ACP4A Company A','acp4a-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000125002','ACP125B','ACP4A Company B','acp4a-company-b','ACTIVE');
INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
('00000000-0000-0000-0000-000000125011','00000000-0000-0000-0000-000000125001','ACP4A-A','ACP4A Store A','ACTIVE'),
('00000000-0000-0000-0000-000000125012','00000000-0000-0000-0000-000000125002','ACP4A-B','ACP4A Store B','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000125001','00000000-0000-0000-0000-000000125091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000125001','00000000-0000-0000-0000-000000125092','FINANCE','ACTIVE',TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_uom UUID;v_warehouse UUID;v_version BIGINT;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','00000000-0000-0000-0000-000000125091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context('00000000-0000-0000-0000-000000125001','ACP4A_TEST');

  v_result:=public.save_inventory_uom(
    NULL,NULL,'ACP4A Ketul','UNIT',FALSE,0::SMALLINT,TRUE
  );
  v_uom:=(v_result#>>'{data,id}')::UUID;
  v_version:=(v_result#>>'{data,master_version}')::BIGINT;
  IF v_result->>'action'<>'CREATE' OR v_version<>1 THEN RAISE EXCEPTION 'TEST_FAILED: UOM create invalid'; END IF;
  v_result:=public.save_inventory_uom(
    NULL,NULL,'ACP4A Ketul','UNIT',FALSE,0::SMALLINT,TRUE
  );
  IF v_result->>'action'<>'EXACT_RETRY' OR (v_result#>>'{data,id}')::UUID<>v_uom THEN RAISE EXCEPTION 'TEST_FAILED: UOM create retry invalid'; END IF;
  v_result:=public.save_inventory_uom(
    v_uom,v_version,'ACP4A Ketul Baru','UNIT',FALSE,0::SMALLINT,TRUE
  );
  IF v_result->>'action'<>'UPDATE' OR (v_result#>>'{data,master_version}')::BIGINT<>2 THEN RAISE EXCEPTION 'TEST_FAILED: UOM update invalid'; END IF;
  v_result:=public.save_inventory_uom(
    v_uom,v_version,'ACP4A Ketul Baru','UNIT',FALSE,0::SMALLINT,TRUE
  );
  IF v_result->>'action'<>'EXACT_RETRY' THEN RAISE EXCEPTION 'TEST_FAILED: UOM update retry invalid'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_inventory_uom(
      v_uom,1,'ACP4A Stale','UNIT',FALSE,0::SMALLINT,TRUE
    );
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='MASTER_VERSION_CONFLICT' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: stale UOM update accepted'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_inventory_warehouse(NULL,NULL,'ACP4A Cross','STORE','00000000-0000-0000-0000-000000125012',NULL,TRUE,TRUE,TRUE);
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='ACTIVE_STORE_NOT_FOUND' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company Store accepted'; END IF;

  v_result:=public.save_inventory_warehouse(NULL,NULL,'ACP4A Warehouse','STORE','00000000-0000-0000-0000-000000125011','Test location',TRUE,TRUE,TRUE);
  v_warehouse:=(v_result#>>'{data,id}')::UUID;
  IF v_result->>'action'<>'CREATE' OR v_warehouse IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: Warehouse create invalid'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub','00000000-0000-0000-0000-000000125092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context('00000000-0000-0000-0000-000000125001','ACP4A_TEST');
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_inventory_uom(
      NULL,NULL,'ACP4A Forbidden','UNIT',FALSE,0::SMALLINT,TRUE
    );
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='INVENTORY_MASTER_ACCESS_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance UOM write accepted'; END IF;

  IF has_table_privilege('authenticated','public.uoms','INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.warehouses','INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.stores','INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.pos_terminals','INSERT,UPDATE,DELETE') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct simple-master write remains';
  END IF;
END
$test$;

RESET ROLE;
DO $verify$
DECLARE v_count BIGINT;
BEGIN
  SELECT count(*) INTO v_count FROM public.inventory_master_write_audit
  WHERE company_id='00000000-0000-0000-0000-000000125001';
  IF v_count<>3 THEN RAISE EXCEPTION 'TEST_FAILED: audit count %, expected 3',v_count; END IF;
  IF EXISTS(SELECT 1 FROM public.warehouses WHERE company_id='00000000-0000-0000-0000-000000125001' AND allow_negative_stock) THEN
    RAISE EXCEPTION 'TEST_FAILED: generic Warehouse RPC changed negative-stock policy';
  END IF;
  RAISE NOTICE 'TEST PASSED: Inventory simple masters are tenant-safe, guarded, versioned, idempotent, audited, and direct-write closed.';
END
$verify$;

ROLLBACK;
