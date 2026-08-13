-- ACP-4H behavior: Opening Stock capability and Store-scoped preparation.
-- SAFETY: every identity, document, Stock effect, and audit rolls back.

BEGIN;

INSERT INTO auth.users(
  id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at
) VALUES
('00000000-0000-0000-0000-000000132091','acp4h-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4H Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000132092','acp4h-manager@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4H Manager"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000132093','acp4h-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4H Finance"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000132094','acp4h-accounting@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4H Accounting"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000132091','acp4h-admin@example.invalid','ACP4H Admin','cashier'),
('00000000-0000-0000-0000-000000132092','acp4h-manager@example.invalid','ACP4H Manager','cashier'),
('00000000-0000-0000-0000-000000132093','acp4h-finance@example.invalid','ACP4H Finance','cashier'),
('00000000-0000-0000-0000-000000132094','acp4h-accounting@example.invalid','ACP4H Accounting','cashier')
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000132001','ACP132A','ACP4H Company A','acp4h-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000132002','ACP132B','ACP4H Company B','acp4h-company-b','ACTIVE');
INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
('00000000-0000-0000-0000-000000132011','00000000-0000-0000-0000-000000132001','A1','ACP4H Store A','ACTIVE');
INSERT INTO public.warehouses(id,company_id,store_id,code,name,warehouse_type) VALUES
('00000000-0000-0000-0000-000000132021','00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132011','WHS','ACP4H Store Warehouse','STORE'),
('00000000-0000-0000-0000-000000132022','00000000-0000-0000-0000-000000132001',NULL,'WHC','ACP4H Central Warehouse','CENTRAL'),
('00000000-0000-0000-0000-000000132023','00000000-0000-0000-0000-000000132002',NULL,'WHB','ACP4H Warehouse B','CENTRAL');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company) VALUES
('00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000132002','00000000-0000-0000-0000-000000132091','COMPANY_ADMIN','ACTIVE',FALSE),
('00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132092','STORE_MANAGER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132093','FINANCE','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132094','ACCOUNTING','ACTIVE',TRUE);
INSERT INTO public.store_memberships(company_id,store_id,user_id,role_code,status) VALUES
('00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132011','00000000-0000-0000-0000-000000132092','STORE_MANAGER','ACTIVE');
INSERT INTO public.product_categories(id,company_id,category_code,category_name) VALUES
('00000000-0000-0000-0000-000000132031','00000000-0000-0000-0000-000000132001','TEST','Test');
INSERT INTO public.uoms(id,company_id,code,name) VALUES
('00000000-0000-0000-0000-000000132041','00000000-0000-0000-0000-000000132001','PCS','Piece');
INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle) VALUES
('00000000-0000-0000-0000-000000132051','00000000-0000-0000-0000-000000132001','ACP132-P1','ACP4H Product One','Test','00000000-0000-0000-0000-000000132031',100,50,'PCS','00000000-0000-0000-0000-000000132041','00000000-0000-0000-0000-000000132041',1,TRUE,FALSE),
('00000000-0000-0000-0000-000000132052','00000000-0000-0000-0000-000000132001','ACP132-P2','ACP4H Product Two','Test','00000000-0000-0000-0000-000000132031',100,60,'PCS','00000000-0000-0000-0000-000000132041','00000000-0000-0000-0000-000000132041',1,TRUE,FALSE);
INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price) VALUES
('00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132051','00000000-0000-0000-0000-000000132041',1,TRUE,TRUE,50,100),
('00000000-0000-0000-0000-000000132001','00000000-0000-0000-0000-000000132052','00000000-0000-0000-0000-000000132041',1,TRUE,TRUE,60,100);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_manager_doc UUID;v_finance_doc UUID;
  v_finance_version BIGINT;v_rejected BOOLEAN;
BEGIN
  -- Accounting has report VIEW but no preparation authority.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000132094','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000132001','ACP4H_TEST');
  v_result:=public.get_inventory_opening_stock();
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: unexpected Accounting document';
  END IF;
  v_rejected:=FALSE;
  BEGIN PERFORM public.save_opening_stock_document(NULL,NULL,
    '00000000-0000-0000-0000-000000132022',CURRENT_DATE,NULL,
    jsonb_build_array(jsonb_build_object('productId',
      '00000000-0000-0000-0000-000000132052','quantityBase',3,
      'unitCostBase',60)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Accounting prepared Draft'; END IF;

  -- Store Manager can prepare only the assigned Store warehouse.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000132092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000132001','ACP4H_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.save_opening_stock_document(NULL,NULL,
    '00000000-0000-0000-0000-000000132022',CURRENT_DATE,NULL,
    jsonb_build_array(jsonb_build_object('productId',
      '00000000-0000-0000-0000-000000132051','quantityBase',2,
      'unitCostBase',50)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='OPENING_STOCK_PREPARER_REQUIRED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: manager widened warehouse scope'; END IF;
  v_result:=public.save_opening_stock_document(NULL,NULL,
    '00000000-0000-0000-0000-000000132021',CURRENT_DATE,'Manager draft',
    jsonb_build_array(jsonb_build_object('productId',
      '00000000-0000-0000-0000-000000132051','quantityBase',2,
      'unitCostBase',50)));
  v_manager_doc:=(v_result->>'documentId')::UUID;
  v_result:=public.get_inventory_opening_stock();
  IF jsonb_array_length(v_result->'data')<>1
     OR jsonb_array_length(v_result->'warehouses')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: manager composed scope invalid';
  END IF;
  v_rejected:=FALSE;
  BEGIN PERFORM public.post_opening_stock(v_manager_doc,1,
    '00000000-0000-0000-0000-000000132071');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: manager posted Opening Stock'; END IF;

  -- Finance prepares Company-wide but cannot Post.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000132093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000132001','ACP4H_TEST');
  v_result:=public.save_opening_stock_document(NULL,NULL,
    '00000000-0000-0000-0000-000000132022',CURRENT_DATE,'Finance draft',
    jsonb_build_array(jsonb_build_object('productId',
      '00000000-0000-0000-0000-000000132052','quantityBase',3,
      'unitCostBase',60)));
  v_finance_doc:=(v_result->>'documentId')::UUID;
  v_finance_version:=(v_result->>'masterVersion')::BIGINT;
  v_rejected:=FALSE;
  BEGIN PERFORM public.post_opening_stock(v_finance_doc,v_finance_version,
    '00000000-0000-0000-0000-000000132072');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance posted Opening Stock'; END IF;

  -- Company Admin posts, and composed report includes only linked proof.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000132091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000132001','ACP4H_TEST');
  v_result:=public.post_opening_stock(v_finance_doc,v_finance_version,
    '00000000-0000-0000-0000-000000132072');
  IF v_result->>'status'<>'POSTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Admin did not Post Opening Stock';
  END IF;
  v_result:=public.get_inventory_opening_stock();
  IF jsonb_array_length(v_result->'data')<>2
     OR jsonb_array_length(v_result->'lines')<>2
     OR jsonb_array_length(v_result->'movements')<>1
     OR jsonb_array_length(v_result->'batches')<>1
     OR jsonb_array_length(v_result->'financialEvents')<>1
     OR jsonb_array_length(v_result->'audit')<3 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Opening Stock proof incomplete';
  END IF;

  -- Active Company B cannot observe Company A documents or references.
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000132002','ACP4H_TEST');
  v_result:=public.get_inventory_opening_stock();
  IF jsonb_array_length(v_result->'data')<>0
     OR jsonb_array_length(v_result->'products')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Opening Stock leaked';
  END IF;

  IF has_table_privilege('authenticated','public.opening_stock_documents',
       'SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.opening_stock_lines',
       'SELECT,INSERT,UPDATE,DELETE')
     OR has_function_privilege('authenticated',
       'public.private_opening_stock_prepare_allowed(uuid,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Opening Stock boundary remains open';
  END IF;

  RAISE NOTICE 'TEST PASSED: Opening Stock preparation is capability-aware, Store-scoped, tenant-safe, and only Company Owner/Admin can Post.';
END
$test$;

ROLLBACK;
