-- ACP-4G behavior: Backoffice capability and restricted blind-count channel.
-- SAFETY: every identity, document, Stock effect, override, and audit rolls back.

BEGIN;

INSERT INTO auth.users(
  id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at
) VALUES
('00000000-0000-0000-0000-000000131091','acp4g-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4G Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000131092','acp4g-manager@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4G Manager"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000131093','acp4g-cashier@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4G Cashier"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000131094','acp4g-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP4G Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000131091','acp4g-admin@example.invalid','ACP4G Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000131092','acp4g-manager@example.invalid','ACP4G Manager','cashier'::public.user_role),
('00000000-0000-0000-0000-000000131093','acp4g-cashier@example.invalid','ACP4G Cashier','cashier'::public.user_role),
('00000000-0000-0000-0000-000000131094','acp4g-finance@example.invalid','ACP4G Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET
  email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

INSERT INTO public.companies(
  id,company_code,company_name,company_slug,status
) VALUES
('00000000-0000-0000-0000-000000131001','ACP131A','ACP4G Company A','acp4g-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000131002','ACP131B','ACP4G Company B','acp4g-company-b','ACTIVE');
INSERT INTO public.stores(id,company_id,store_code,store_name,status) VALUES
('00000000-0000-0000-0000-000000131011','00000000-0000-0000-0000-000000131001','A1','ACP4G Store A','ACTIVE');
INSERT INTO public.warehouses(
  id,company_id,store_id,code,name,warehouse_type
) VALUES
('00000000-0000-0000-0000-000000131021','00000000-0000-0000-0000-000000131001','00000000-0000-0000-0000-000000131011','WHA','ACP4G Warehouse A','STORE'),
('00000000-0000-0000-0000-000000131022','00000000-0000-0000-0000-000000131002',NULL,'WHB','ACP4G Warehouse B','CENTRAL');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company
) VALUES
('00000000-0000-0000-0000-000000131001','00000000-0000-0000-0000-000000131091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000131002','00000000-0000-0000-0000-000000131091','COMPANY_ADMIN','ACTIVE',FALSE),
('00000000-0000-0000-0000-000000131001','00000000-0000-0000-0000-000000131092','STORE_MANAGER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000131001','00000000-0000-0000-0000-000000131093','CASHIER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000131001','00000000-0000-0000-0000-000000131094','FINANCE','ACTIVE',TRUE);
INSERT INTO public.store_memberships(
  company_id,store_id,user_id,role_code,status
) VALUES
('00000000-0000-0000-0000-000000131001','00000000-0000-0000-0000-000000131011','00000000-0000-0000-0000-000000131092','STORE_MANAGER','ACTIVE'),
('00000000-0000-0000-0000-000000131001','00000000-0000-0000-0000-000000131011','00000000-0000-0000-0000-000000131093','CASHIER','ACTIVE');

INSERT INTO public.product_categories(
  id,company_id,category_code,category_name
) VALUES('00000000-0000-0000-0000-000000131031','00000000-0000-0000-0000-000000131001','TEST','Test');
INSERT INTO public.uoms(id,company_id,code,name) VALUES
('00000000-0000-0000-0000-000000131041','00000000-0000-0000-0000-000000131001','PCS','Piece');
INSERT INTO public.products(
  id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
  weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES(
  '00000000-0000-0000-0000-000000131051',
  '00000000-0000-0000-0000-000000131001','ACP131-P','ACP4G Product',
  'Test','00000000-0000-0000-0000-000000131031',100,50,'PCS',
  '00000000-0000-0000-0000-000000131041',
  '00000000-0000-0000-0000-000000131041',1,TRUE,FALSE);
INSERT INTO public.product_uoms(
  company_id,product_id,uom_id,factor_to_base,purchase_allowed,
  sales_allowed,purchase_price,sale_price
) VALUES(
  '00000000-0000-0000-0000-000000131001',
  '00000000-0000-0000-0000-000000131051',
  '00000000-0000-0000-0000-000000131041',1,TRUE,TRUE,50,100);
INSERT INTO public.product_stocks(
  product_id,warehouse_id,stock_qty,company_id
) VALUES(
  '00000000-0000-0000-0000-000000131051',
  '00000000-0000-0000-0000-000000131021',1,
  '00000000-0000-0000-0000-000000131001');
INSERT INTO public.product_batches(
  product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,company_id
) VALUES(
  '00000000-0000-0000-0000-000000131051',
  '00000000-0000-0000-0000-000000131021',1,1,50,
  '00000000-0000-0000-0000-000000131001');
INSERT INTO public.stock_movements(
  product_id,warehouse_id,qty_change,movement_type,reference_table,
  reference_id,company_id,base_uom_id,base_uom_name_snapshot,
  balance_after_base_qty,actor_id,posted_at,movement_status
) VALUES(
  '00000000-0000-0000-0000-000000131051',
  '00000000-0000-0000-0000-000000131021',1,
  'PURCHASE'::public.stock_movement_type,'ACP4G_TEST',
  '00000000-0000-0000-0000-000000131061',
  '00000000-0000-0000-0000-000000131001',
  '00000000-0000-0000-0000-000000131041','Piece',1,
  '00000000-0000-0000-0000-000000131091',clock_timestamp(),'POSTED');

SET LOCAL ROLE authenticated;
DO $test$
DECLARE
  v_result JSONB;v_override_version BIGINT;v_manager_override BIGINT;
  v_opname UUID;v_version BIGINT;v_rejected BOOLEAN;
BEGIN
  -- Admin can restrict the otherwise eligible Cashier blind-count channel.
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000131001','ACP4G_TEST');
  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000131001',
    '00000000-0000-0000-0000-000000131093',
    'inventory.stock_opnames','TANPA_AKSES',NULL);
  v_override_version:=(v_result->>'masterVersion')::BIGINT;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131093',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000131001','ACP4G_TEST');
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_stock_opname_session(
      NULL,NULL,'00000000-0000-0000-0000-000000131021',
      'SELECTED',NULL,
      jsonb_build_array('00000000-0000-0000-0000-000000131051'),NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: restricted Cashier created Opname';
  END IF;
  v_rejected:=FALSE;
  BEGIN PERFORM public.get_inventory_stock_opnames();
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Cashier opened Backoffice report';
  END IF;

  -- Reset restores the exact existing Store/Warehouse blind-count authority.
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000131001',
    '00000000-0000-0000-0000-000000131093',
    'inventory.stock_opnames','IKUTI_ROLE',v_override_version);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131093',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.save_stock_opname_session(
    NULL,NULL,'00000000-0000-0000-0000-000000131021',
    'SELECTED',NULL,
    jsonb_build_array('00000000-0000-0000-0000-000000131051'),
    'ACP4G blind channel');
  v_opname:=(v_result->>'opnameId')::UUID;
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.get_stock_opname_blind_session(v_opname);
  IF (v_result->'lines'->0) ? 'systemQuantity'
     OR (v_result->'lines'->0) ? 'expectedQuantityAtCount'
     OR (v_result->'lines'->0) ? 'physicalQuantity'
     OR (v_result->'lines'->0) ? 'varianceAtCount' THEN
    RAISE EXCEPTION 'TEST_FAILED: blind payload leaked quantity';
  END IF;
  v_result:=public.start_stock_opname(v_opname,v_version);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.record_stock_opname_count(
    v_opname,v_version,'00000000-0000-0000-0000-000000131051',2,NULL);
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.complete_stock_opname(v_opname,v_version);
  v_version:=(v_result->>'masterVersion')::BIGINT;

  -- OPERASIONAL keeps Store Manager operational but removes final posting.
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131091',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.save_user_permission_override(
    '00000000-0000-0000-0000-000000131001',
    '00000000-0000-0000-0000-000000131092',
    'inventory.stock_opnames','OPERASIONAL',NULL);
  v_manager_override:=(v_result->>'masterVersion')::BIGINT;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000131001','ACP4G_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.post_stock_opname(
    v_opname,v_version,'00000000-0000-0000-0000-000000131071');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: OPERASIONAL manager posted Opname';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000131001',
    '00000000-0000-0000-0000-000000131092',
    'inventory.stock_opnames','IKUTI_ROLE',v_manager_override);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.post_stock_opname(
    v_opname,v_version,'00000000-0000-0000-0000-000000131071');
  IF v_result->>'status'<>'POSTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: authorized manager did not post Opname';
  END IF;

  v_result:=public.get_inventory_stock_opnames();
  IF jsonb_array_length(v_result->'data')<>1
     OR jsonb_array_length(v_result->'details')<>1
     OR jsonb_array_length(v_result->'attempts')<>1
     OR jsonb_array_length(v_result->'adjustments')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Opname report incomplete';
  END IF;

  -- Finance has report VIEW only.
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131094',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000131001','ACP4G_TEST');
  v_result:=public.get_inventory_stock_opnames();
  IF jsonb_array_length(v_result->'data')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance report view missing';
  END IF;

  -- The same Admin sees no Company-A Opname while Company B is active.
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000131091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000131002','ACP4G_TEST');
  v_result:=public.get_inventory_stock_opnames();
  IF jsonb_array_length(v_result->'data')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Opname leaked';
  END IF;

  IF has_table_privilege('authenticated','public.stock_opnames','SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.stock_opname_details','SELECT,INSERT,UPDATE,DELETE')
     OR has_function_privilege('authenticated',
       'public.private_stock_opname_counter_allowed(uuid,uuid)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.get_stock_opname_adjustment_references()','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Opname boundary remains open';
  END IF;

  RAISE NOTICE 'TEST PASSED: Stock Opname report and blind-count channels are separated, restriction-aware, tenant-safe, and still post through canonical Adjustment.';
END
$test$;

ROLLBACK;
