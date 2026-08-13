-- ACP-5C behavior: Supplier Order capability, Cashier split, tenant, zero effect.
-- SAFETY: all identities, requests, orders, overrides, and audits roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000136091','acp5c-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5C Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000136092','acp5c-manager@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5C Manager"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000136093','acp5c-cashier@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5C Cashier"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000136091','acp5c-admin@example.invalid','ACP5C Admin','cashier'),
('00000000-0000-0000-0000-000000136092','acp5c-manager@example.invalid','ACP5C Manager','cashier'),
('00000000-0000-0000-0000-000000136093','acp5c-cashier@example.invalid','ACP5C Cashier','cashier')
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES
('00000000-0000-0000-0000-000000136001','ACP136A','ACP5C Company A','acp5c-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000136002','ACP136B','ACP5C Company B','acp5c-company-b','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company
) VALUES
('00000000-0000-0000-0000-000000136001','00000000-0000-0000-0000-000000136091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000136002','00000000-0000-0000-0000-000000136091','COMPANY_ADMIN','ACTIVE',FALSE),
('00000000-0000-0000-0000-000000136001','00000000-0000-0000-0000-000000136092','STORE_MANAGER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000136001','00000000-0000-0000-0000-000000136093','CASHIER','ACTIVE',TRUE);

INSERT INTO public.stores(id,company_id,store_code,store_name,status)
VALUES('00000000-0000-0000-0000-000000136011',
  '00000000-0000-0000-0000-000000136001','ACP5CS','ACP5C Store','ACTIVE');
INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status)
VALUES('00000000-0000-0000-0000-000000136021',
  '00000000-0000-0000-0000-000000136001',
  '00000000-0000-0000-0000-000000136011','ACP5CP','ACP5C POS','ACTIVE');
INSERT INTO public.store_memberships(company_id,store_id,user_id,role_code,status)
VALUES
('00000000-0000-0000-0000-000000136001','00000000-0000-0000-0000-000000136011','00000000-0000-0000-0000-000000136092','STORE_MANAGER','ACTIVE'),
('00000000-0000-0000-0000-000000136001','00000000-0000-0000-0000-000000136011','00000000-0000-0000-0000-000000136093','CASHIER','ACTIVE');
INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,
  is_sale_source,is_purchase_destination,is_active)
VALUES('00000000-0000-0000-0000-000000136031',
  '00000000-0000-0000-0000-000000136001','ACP5CW','ACP5C Warehouse','STORE',
  '00000000-0000-0000-0000-000000136011',TRUE,TRUE,TRUE);
INSERT INTO public.product_categories(id,company_id,category_code,category_name)
VALUES('00000000-0000-0000-0000-000000136041',
  '00000000-0000-0000-0000-000000136001','ACP5C','ACP5C Category');
INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
VALUES('00000000-0000-0000-0000-000000136051',
  '00000000-0000-0000-0000-000000136001','PCS','Piece','UNIT',FALSE,0);
INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
  uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle)
VALUES('00000000-0000-0000-0000-000000136061',
  '00000000-0000-0000-0000-000000136001','ACP5C-P','ACP5C Product',
  'ACP5C Category','00000000-0000-0000-0000-000000136041',100,50,'PCS',
  '00000000-0000-0000-0000-000000136051',
  '00000000-0000-0000-0000-000000136051',1,TRUE,FALSE);
INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
  purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
VALUES('00000000-0000-0000-0000-000000136001',
  '00000000-0000-0000-0000-000000136061',
  '00000000-0000-0000-0000-000000136051',1,TRUE,TRUE,50,100,TRUE);
INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,
  created_by,updated_by)
VALUES('00000000-0000-0000-0000-000000136071',
  '00000000-0000-0000-0000-000000136001','ACP5CSUP','ACP5C Supplier',
  '00000000-0000-0000-0000-000000136091',
  '00000000-0000-0000-0000-000000136091');
INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,
  store_id,pos_id,status,sales_warehouse_id)
VALUES('00000000-0000-0000-0000-000000136081','ACP5C-SESSION',
  '00000000-0000-0000-0000-000000136093',
  '00000000-0000-0000-0000-000000136001',
  '00000000-0000-0000-0000-000000136011',
  '00000000-0000-0000-0000-000000136021','OPEN'::public.session_status,
  '00000000-0000-0000-0000-000000136031');
INSERT INTO public.user_company_permission_overrides(
  company_id,user_id,permission_key,restriction_preset,created_by,updated_by
) VALUES('00000000-0000-0000-0000-000000136001',
  '00000000-0000-0000-0000-000000136092','purchase.supplier_orders',
  'OPERASIONAL','00000000-0000-0000-0000-000000136091',
  '00000000-0000-0000-0000-000000136091');

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_request UUID;v_request_line UUID;v_order UUID;
  v_rejected BOOLEAN;
BEGIN
  -- Cashier request remains open-session scoped and independent from Purchase VIEW.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000136093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000136001','ACP5C_TEST');
  v_result:=public.get_pos_stock_request_workspace(
    '00000000-0000-0000-0000-000000136081');
  IF jsonb_array_length(v_result->'options')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Cashier product reference invalid';
  END IF;
  v_result:=public.save_stock_request(NULL,NULL,
    '00000000-0000-0000-0000-000000136081',current_date+1,NULL,
    jsonb_build_array(jsonb_build_object(
      'clientLineKey','00000000-0000-0000-0000-000000136101',
      'productId','00000000-0000-0000-0000-000000136061',
      'uomId','00000000-0000-0000-0000-000000136051','quantity',5)));
  v_request:=(v_result->>'documentId')::UUID;
  PERFORM public.submit_stock_request(v_request,1);
  v_result:=public.get_pos_stock_request_workspace(
    '00000000-0000-0000-0000-000000136081');
  IF jsonb_array_length(v_result->'documents')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: own Stock Request not visible';
  END IF;

  -- Operational preset can create Draft but cannot Post.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000136092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000136001','ACP5C_TEST');
  v_result:=public.get_purchase_supplier_orders();
  v_request_line:=(v_result->'requestLines'->0->>'id')::UUID;
  v_result:=public.save_supplier_order(NULL,NULL,
    '00000000-0000-0000-0000-000000136011',
    '00000000-0000-0000-0000-000000136031',
    '00000000-0000-0000-0000-000000136071',current_date,current_date+1,
    NULL,jsonb_build_array(jsonb_build_object(
      'clientLineKey','00000000-0000-0000-0000-000000136111',
      'productId','00000000-0000-0000-0000-000000136061',
      'uomId','00000000-0000-0000-0000-000000136051','quantity',5,
      'estimatedUnitPrice',50)),jsonb_build_array(jsonb_build_object(
      'orderLineKey','00000000-0000-0000-0000-000000136111',
      'requestLineId',v_request_line,'allocatedBaseQty',5)));
  v_order:=(v_result->>'documentId')::UUID;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.confirm_supplier_order(v_order,1,
      '00000000-0000-0000-0000-000000136121');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Operational preset posted Supplier Order';
  END IF;

  -- Admin posts; Cashier sees only Store-eligible Order/lines.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000136091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000136001','ACP5C_TEST');
  PERFORM public.confirm_supplier_order(v_order,1,
    '00000000-0000-0000-0000-000000136121');
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000136093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000136001','ACP5C_TEST');
  v_result:=public.get_pos_goods_receipt_supplier_orders(
    '00000000-0000-0000-0000-000000136081');
  IF jsonb_array_length(v_result->'orders')<>1
     OR jsonb_array_length(v_result->'lines')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Goods Receipt Order scope invalid';
  END IF;

  -- Company switch never leaks Company A Purchase data.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000136091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000136002','ACP5C_TEST');
  v_result:=public.get_purchase_supplier_orders();
  IF jsonb_array_length(v_result->'requests')<>0
     OR jsonb_array_length(v_result->'orders')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Purchase data leaked';
  END IF;

  IF has_table_privilege('authenticated','public.stock_request_documents',
       'SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.supplier_order_documents',
       'SELECT,INSERT,UPDATE,DELETE')
     OR NOT has_function_privilege('authenticated',
       'public.get_purchase_supplier_orders()','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_purchase_supplier_orders()','EXECUTE')
     -- Do not resolve a private-qualified routine while running as
     -- authenticated: PostgreSQL correctly rejects that catalog lookup when
     -- the role has no USAGE on schema private. The owner-run postflight checks
     -- the individual core ACL; this behavior test proves the browser cannot
     -- enter the private schema at all.
     OR has_schema_privilege('authenticated','private','USAGE') THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier Order browser boundary invalid';
  END IF;

  RAISE NOTICE 'TEST PASSED: Supplier Order is capability-aware, Cashier-separated, tenant-safe, and zero-effect.';
END
$test$;

ROLLBACK;
