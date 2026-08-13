-- ACP-5B behavior: Supplier management, consumer split, restriction, tenant.
-- SAFETY: all identities, masters, overrides, and audits roll back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES
('00000000-0000-0000-0000-000000135091','acp5b-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5B Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000135092','acp5b-manager@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5B Manager"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000135093','acp5b-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::JSONB,'{"name":"ACP5B Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000135091','acp5b-admin@example.invalid','ACP5B Admin','cashier'),
('00000000-0000-0000-0000-000000135092','acp5b-manager@example.invalid','ACP5B Manager','cashier'),
('00000000-0000-0000-0000-000000135093','acp5b-finance@example.invalid','ACP5B Finance','cashier')
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000135001','ACP135A','ACP5B Company A','acp5b-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000135002','ACP135B','ACP5B Company B','acp5b-company-b','ACTIVE');
INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company
) VALUES
('00000000-0000-0000-0000-000000135001','00000000-0000-0000-0000-000000135091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000135002','00000000-0000-0000-0000-000000135091','COMPANY_ADMIN','ACTIVE',FALSE),
('00000000-0000-0000-0000-000000135001','00000000-0000-0000-0000-000000135092','STORE_MANAGER','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000135001','00000000-0000-0000-0000-000000135093','FINANCE','ACTIVE',TRUE);

INSERT INTO public.product_categories(id,company_id,category_code,category_name)
VALUES('00000000-0000-0000-0000-000000135011',
  '00000000-0000-0000-0000-000000135001','ACP5B','ACP5B Category');
INSERT INTO public.uoms(id,company_id,code,name) VALUES(
  '00000000-0000-0000-0000-000000135021',
  '00000000-0000-0000-0000-000000135001','PCS','Piece');
INSERT INTO public.products(
  id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
  weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES(
  '00000000-0000-0000-0000-000000135031',
  '00000000-0000-0000-0000-000000135001','ACP5B-P','ACP5B Product',
  'ACP5B Category','00000000-0000-0000-0000-000000135011',100,50,'PCS',
  '00000000-0000-0000-0000-000000135021',
  '00000000-0000-0000-0000-000000135021',1,TRUE,FALSE);
INSERT INTO public.product_uoms(
  company_id,product_id,uom_id,factor_to_base,purchase_allowed,sales_allowed,
  purchase_price,sale_price
) VALUES('00000000-0000-0000-0000-000000135001',
  '00000000-0000-0000-0000-000000135031',
  '00000000-0000-0000-0000-000000135021',1,TRUE,TRUE,50,100);

INSERT INTO public.user_company_permission_overrides(
  company_id,user_id,permission_key,restriction_preset,created_by,updated_by
) VALUES('00000000-0000-0000-0000-000000135001',
  '00000000-0000-0000-0000-000000135092','contacts.suppliers','TANPA_AKSES',
  '00000000-0000-0000-0000-000000135091',
  '00000000-0000-0000-0000-000000135091');

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_supplier UUID;v_relation UUID;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000135091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000135001','ACP5B_TEST');
  v_result:=public.save_contacts_supplier(NULL,NULL,'ACP5B Supplier','Contact',
    '0800','Address','NPWP','NET 30','Bank','123','Holder',TRUE);
  v_supplier:=(v_result->>'supplierId')::UUID;
  v_result:=public.save_contacts_product_supplier(NULL,NULL,
    '00000000-0000-0000-0000-000000135031',v_supplier,
    '00000000-0000-0000-0000-000000135021','VENDOR-P',50,TRUE,TRUE);
  v_relation:=(v_result->>'productSupplierId')::UUID;
  v_result:=public.get_contacts_suppliers(TRUE);
  IF jsonb_array_length(v_result->'data')<>1
     OR jsonb_array_length(v_result->'relations')<>1
     OR (v_result->'relations'->0->>'id')::UUID<>v_relation
     OR jsonb_array_length(public.export_contacts_suppliers())<>1
     OR jsonb_array_length(public.export_contacts_product_suppliers())<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Supplier workspace/export invalid';
  END IF;

  -- Finance sees its own narrow reference but cannot manage Supplier.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000135093','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000135001','ACP5B_TEST');
  IF jsonb_array_length(public.get_supplier_invoice_supplier_references())<>1
     OR jsonb_array_length(public.get_supplier_payment_supplier_references())<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Finance Supplier reference invalid';
  END IF;
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_contacts_supplier(v_supplier,1,'Forbidden Rename',NULL,
      NULL,NULL,NULL,NULL,NULL,NULL,NULL,TRUE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance managed Supplier'; END IF;

  -- Contacts restriction does not remove independent Purchase references.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000135092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000135001','ACP5B_TEST');
  v_rejected:=FALSE;
  BEGIN PERFORM public.get_contacts_suppliers(TRUE);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: restricted Manager viewed Supplier master';
  END IF;
  v_result:=public.get_supplier_order_supplier_references();
  IF jsonb_array_length(v_result->'suppliers')<>1
     OR jsonb_array_length(v_result->'productSuppliers')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: independent Purchase reference blocked';
  END IF;

  -- Company switch never exposes Company A Supplier.
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',
    '00000000-0000-0000-0000-000000135091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000135002','ACP5B_TEST');
  v_result:=public.get_contacts_suppliers(TRUE);
  IF jsonb_array_length(v_result->'data')<>0
     OR jsonb_array_length(v_result->'relations')<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: cross-Company Supplier leaked';
  END IF;

  IF has_table_privilege('authenticated','public.suppliers',
       'SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('authenticated','public.product_suppliers',
       'SELECT,INSERT,UPDATE,DELETE')
     OR NOT has_function_privilege('authenticated',
       'public.get_contacts_suppliers(boolean)','EXECUTE')
     OR has_function_privilege('anon',
       'public.get_contacts_suppliers(boolean)','EXECUTE')
     OR has_function_privilege('authenticated',
       'public.save_supplier(uuid,bigint,text,text,text,text,text,text,text,text,text,boolean)',
       'EXECUTE')
     OR has_function_privilege('authenticated',
       'public.save_product_supplier(uuid,bigint,uuid,uuid,uuid,text,numeric,boolean,boolean)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier browser boundary invalid';
  END IF;

  RAISE NOTICE 'TEST PASSED: Supplier management is capability-aware, consumer-separated, restricted, and tenant-safe.';
END
$test$;

ROLLBACK;
