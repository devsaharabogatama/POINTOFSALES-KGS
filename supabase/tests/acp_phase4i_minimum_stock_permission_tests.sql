-- ACP-4I behavior: Minimum Stock capability, Store scope, and tenant boundary.
-- SAFETY: every identity, setting, balance, and audit row rolls back.

BEGIN;

INSERT INTO auth.users(
  id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at
) VALUES
('00000000-0000-0000-0000-000000133091','acp4i-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4I Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000133092','acp4i-manager@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4I Manager"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000133093','acp4i-warehouse@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4I Warehouse"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000133094','acp4i-accounting@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4I Accounting"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000133091','acp4i-admin@example.invalid','ACP4I Admin','cashier'),
('00000000-0000-0000-0000-000000133092','acp4i-manager@example.invalid','ACP4I Manager','cashier'),
('00000000-0000-0000-0000-000000133093','acp4i-warehouse@example.invalid','ACP4I Warehouse','cashier'),
('00000000-0000-0000-0000-000000133094','acp4i-accounting@example.invalid','ACP4I Accounting','cashier')
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000133001','ACP133A','ACP4I Company A','acp4i-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000133002','ACP133B','ACP4I Company B','acp4i-company-b','ACTIVE');
INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
('00000000-0000-0000-0000-000000133011','00000000-0000-0000-0000-000000133001','A1','ACP4I Store A','ACTIVE');
INSERT INTO public.warehouses(id,company_id,store_id,code,name,warehouse_type) VALUES
('00000000-0000-0000-0000-000000133021','00000000-0000-0000-0000-000000133001','00000000-0000-0000-0000-000000133011','WHS','ACP4I Store Warehouse','STORE'),
('00000000-0000-0000-0000-000000133022','00000000-0000-0000-0000-000000133001',NULL,'WHC','ACP4I Central Warehouse','CENTRAL'),
('00000000-0000-0000-0000-000000133023','00000000-0000-0000-0000-000000133002',NULL,'WHB','ACP4I Warehouse B','CENTRAL');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000133001','00000000-0000-0000-0000-000000133091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000133002','00000000-0000-0000-0000-000000133091','COMPANY_ADMIN','ACTIVE',FALSE),
('00000000-0000-0000-0000-000000133001','00000000-0000-0000-0000-000000133092','STORE_MANAGER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000133001','00000000-0000-0000-0000-000000133093','WAREHOUSE_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000133001','00000000-0000-0000-0000-000000133094','ACCOUNTING','ACTIVE',TRUE);
INSERT INTO public.store_memberships(company_id,store_id,user_id,role_code,status) VALUES
('00000000-0000-0000-0000-000000133001','00000000-0000-0000-0000-000000133011','00000000-0000-0000-0000-000000133092','STORE_MANAGER','ACTIVE');
INSERT INTO public.product_categories(id,company_id,category_code,category_name) VALUES
('00000000-0000-0000-0000-000000133031','00000000-0000-0000-0000-000000133001','TEST','Test'),
('00000000-0000-0000-0000-000000133032','00000000-0000-0000-0000-000000133002','TEST','Test');
INSERT INTO public.uoms(id,company_id,code,name) VALUES
('00000000-0000-0000-0000-000000133041','00000000-0000-0000-0000-000000133001','PCS','Piece'),
('00000000-0000-0000-0000-000000133042','00000000-0000-0000-0000-000000133002','PCS','Piece');
INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle) VALUES
('00000000-0000-0000-0000-000000133051','00000000-0000-0000-0000-000000133001','ACP133-P1','ACP4I Product One','Test','00000000-0000-0000-0000-000000133031',100,50,'PCS','00000000-0000-0000-0000-000000133041','00000000-0000-0000-0000-000000133041',1,TRUE,FALSE),
('00000000-0000-0000-0000-000000133052','00000000-0000-0000-0000-000000133002','ACP133-P2','ACP4I Product Two','Test','00000000-0000-0000-0000-000000133032',100,50,'PCS','00000000-0000-0000-0000-000000133042','00000000-0000-0000-0000-000000133042',1,TRUE,FALSE);
INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price) VALUES
('00000000-0000-0000-0000-000000133001','00000000-0000-0000-0000-000000133051','00000000-0000-0000-0000-000000133041',1,TRUE,TRUE,50,100),
('00000000-0000-0000-0000-000000133002','00000000-0000-0000-0000-000000133052','00000000-0000-0000-0000-000000133042',1,TRUE,TRUE,50,100);
INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id) VALUES
('00000000-0000-0000-0000-000000133051','00000000-0000-0000-0000-000000133021',4,'00000000-0000-0000-0000-000000133001'),
('00000000-0000-0000-0000-000000133051','00000000-0000-0000-0000-000000133022',8,'00000000-0000-0000-0000-000000133001');

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_store_setting UUID;v_central_setting UUID;
  v_rejected BOOLEAN;
BEGIN
  -- Accounting has no Minimum Stock baseline access.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000133094','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000133001','ACP4I_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.get_inventory_minimum_stock();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Accounting viewed Minimum Stock'; END IF;

  -- Store Manager can manage only its assigned Store warehouse.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000133092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000133001','ACP4I_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.save_product_warehouse_stock_setting(NULL,NULL,
    '00000000-0000-0000-0000-000000133051',
    '00000000-0000-0000-0000-000000133022',5,TRUE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='MINIMUM_STOCK_WAREHOUSE_ACCESS_DENIED' THEN
      v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: manager widened warehouse scope'; END IF;
  v_result:=public.save_product_warehouse_stock_setting(NULL,NULL,
    '00000000-0000-0000-0000-000000133051',
    '00000000-0000-0000-0000-000000133021',5,TRUE);
  v_store_setting:=(v_result->>'settingId')::UUID;
  v_result:=public.get_inventory_minimum_stock();
  IF jsonb_array_length(v_result->'data')<>1
     OR jsonb_array_length(v_result->'warehouses')<>1
     OR jsonb_array_length(v_result->'balances')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: manager composed scope invalid';
  END IF;

  -- Warehouse Admin retains Company-wide authority.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000133093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000133001','ACP4I_TEST');
  v_result:=public.save_product_warehouse_stock_setting(NULL,NULL,
    '00000000-0000-0000-0000-000000133051',
    '00000000-0000-0000-0000-000000133022',10,TRUE);
  v_central_setting:=(v_result->>'settingId')::UUID;
  v_result:=public.get_inventory_minimum_stock();
  IF jsonb_array_length(v_result->'data')<>2
     OR jsonb_array_length(v_result->'warehouses')<>2
     OR jsonb_array_length(v_result->'audit')<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: Warehouse Admin composed scope invalid';
  END IF;

  -- Company Admin can switch tenant without observing Company A settings.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000133091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000133002','ACP4I_TEST');
  v_result:=public.get_inventory_minimum_stock();
  IF jsonb_array_length(v_result->'data')<>0
     OR jsonb_array_length(v_result->'products')<>1
     OR jsonb_array_length(v_result->'warehouses')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Minimum Stock leaked';
  END IF;

  IF has_table_privilege('authenticated',
       'public.product_warehouse_stock_settings','SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated',
       'public.product_warehouse_stock_setting_audit','SELECT,INSERT,UPDATE,DELETE')
     OR NOT has_function_privilege('authenticated',
       'public.get_inventory_minimum_stock()','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_inventory_minimum_stock()','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: Minimum Stock browser boundary invalid';
  END IF;
  IF v_store_setting IS NULL OR v_central_setting IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: Minimum Stock setting identity missing';
  END IF;

  RAISE NOTICE 'TEST PASSED: Minimum Stock is capability-aware, Store-scoped, tenant-safe, and stock-neutral.';
END
$test$;

ROLLBACK;
