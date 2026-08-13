-- ACP-5G behavior: Bundle restriction, virtual stock, and narrow availability.
-- SAFETY: every fixture, override, audit, and Bundle mutation rolls back.

BEGIN;

INSERT INTO auth.users(
  id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at
) VALUES
('00000000-0000-0000-0000-000000140091','acp5g-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP5G Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000140092','acp5g-manager@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"ACP5G Manager"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000140091','acp5g-admin@example.invalid',
 'ACP5G Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000140092','acp5g-manager@example.invalid',
 'ACP5G Manager','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;

INSERT INTO public.companies(
  id,company_code,company_name,company_slug,status
) VALUES('00000000-0000-0000-0000-000000140001','ACP140',
  'ACP5G Company','acp5g-company','ACTIVE');

INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company
) VALUES
('00000000-0000-0000-0000-000000140001',
 '00000000-0000-0000-0000-000000140091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000140001',
 '00000000-0000-0000-0000-000000140092','STORE_MANAGER','ACTIVE',TRUE);

INSERT INTO public.product_categories(
  id,company_id,category_code,category_name
) VALUES('00000000-0000-0000-0000-000000140011',
  '00000000-0000-0000-0000-000000140001','ACP140CAT','ACP5G Category');

INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
  decimal_precision) VALUES
('00000000-0000-0000-0000-000000140021',
 '00000000-0000-0000-0000-000000140001','ACP140PCS','Piece','UNIT',FALSE,0),
('00000000-0000-0000-0000-000000140022',
 '00000000-0000-0000-0000-000000140001','ACP140PAK','Paket','UNIT',FALSE,0);

INSERT INTO public.products(
  id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
  weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES('00000000-0000-0000-0000-000000140031',
  '00000000-0000-0000-0000-000000140001','ACP140-P','ACP5G Component',
  'ACP5G Category','00000000-0000-0000-0000-000000140011',100,50,
  'ACP140PCS','00000000-0000-0000-0000-000000140021',
  '00000000-0000-0000-0000-000000140021',1,TRUE,FALSE);

INSERT INTO public.product_uoms(
  company_id,product_id,uom_id,factor_to_base,purchase_allowed,
  sales_allowed,purchase_price,sale_price
) VALUES('00000000-0000-0000-0000-000000140001',
  '00000000-0000-0000-0000-000000140031',
  '00000000-0000-0000-0000-000000140021',1,TRUE,TRUE,50,100);

INSERT INTO public.warehouses(
  id,company_id,code,name,warehouse_type,is_sale_source
) VALUES('00000000-0000-0000-0000-000000140041',
  '00000000-0000-0000-0000-000000140001','ACP140W','ACP5G Warehouse',
  'CENTRAL',TRUE);

INSERT INTO public.product_stocks(
  company_id,product_id,warehouse_id,stock_qty
) VALUES('00000000-0000-0000-0000-000000140001',
  '00000000-0000-0000-0000-000000140031',
  '00000000-0000-0000-0000-000000140041',10);

SET LOCAL ROLE authenticated;

DO $test$
DECLARE v_result JSONB;v_bundle UUID;v_version BIGINT;v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000140092',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000140001','ACP5G_TEST');

  v_result:=public.save_bundle_with_components(
    NULL,NULL,'ACP140-B','ACP5G Bundle',
    '00000000-0000-0000-0000-000000140011',
    '00000000-0000-0000-0000-000000140022',250,NULL,NULL,TRUE,
    jsonb_build_array(jsonb_build_object(
      'productId','00000000-0000-0000-0000-000000140031',
      'uomId','00000000-0000-0000-0000-000000140021','quantity',2)));
  v_bundle:=(v_result->>'bundleId')::UUID;
  v_version:=(v_result->>'masterVersion')::BIGINT;

  v_result:=public.get_sales_bundles(TRUE);
  IF (v_result->>'companyId')::UUID<>
      '00000000-0000-0000-0000-000000140001'
     OR jsonb_array_length(v_result->'data')<>1
     OR jsonb_array_length(v_result->'components')<>1
     OR jsonb_array_length(v_result->'products')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: composed Bundle response invalid';
  END IF;

  v_result:=public.get_bundle_availability(v_bundle,
    '00000000-0000-0000-0000-000000140041');
  IF (v_result->>'availableQuantity')::BIGINT<>5 THEN
    RAISE EXCEPTION 'TEST_FAILED: Bundle availability invalid';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000140091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000140001','ACP5G_TEST');
  PERFORM public.save_user_permission_override(
    '00000000-0000-0000-0000-000000140001',
    '00000000-0000-0000-0000-000000140092',
    'sales.bundles','LIHAT_SAJA',NULL);

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000140092',
    'role','authenticated')::TEXT,TRUE);
  v_result:=public.get_sales_bundles(FALSE);
  IF jsonb_array_length(v_result->'data')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA lost Bundle VIEW';
  END IF;
  v_result:=public.get_bundle_availability(v_bundle,
    '00000000-0000-0000-0000-000000140041');
  IF (v_result->>'availableQuantity')::BIGINT<>5 THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA lost availability VIEW';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_bundle_with_components(
      v_bundle,v_version,'ACP140-B','Denied Update',
      '00000000-0000-0000-0000-000000140011',
      '00000000-0000-0000-0000-000000140022',300,NULL,NULL,TRUE,
      jsonb_build_array(jsonb_build_object(
        'productId','00000000-0000-0000-0000-000000140031',
        'uomId','00000000-0000-0000-0000-000000140021','quantity',1)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: LIHAT_SAJA managed Bundle';
  END IF;

  IF has_table_privilege(
      'authenticated','public.product_bundle_items','SELECT')
    OR has_table_privilege(
      'authenticated','public.product_bundle_master_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: direct Bundle read remains';
  END IF;
  RAISE NOTICE 'TEST PASSED: Bundle VIEW/MANAGE, atomic composition, availability, and virtual stock are isolated.';
END
$test$;

ROLLBACK;
