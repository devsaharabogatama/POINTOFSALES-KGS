-- Additive Product-UOM import behavior. Every fixture rolls back.

BEGIN;
INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES(
  '00000000-0000-0000-0000-000000138091','product-uom-import@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::JSONB,
  '{"name":"Product UOM Import Admin"}'::JSONB,FALSE,'authenticated',
  'authenticated',now()) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role) VALUES(
  '00000000-0000-0000-0000-000000138091','product-uom-import@example.invalid',
  'Product UOM Import Admin','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;
INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000138001','PUOM138',
  'Product UOM Import Test','product-uom-import-test','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,
  is_default_company) VALUES(
  '00000000-0000-0000-0000-000000138001',
  '00000000-0000-0000-0000-000000138091','COMPANY_ADMIN','ACTIVE',TRUE);
INSERT INTO public.product_categories(id,company_id,category_code,category_name,is_active)
VALUES('00000000-0000-0000-0000-000000138011',
  '00000000-0000-0000-0000-000000138001','DAGING','Daging',TRUE);
INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
  decimal_precision,is_active) VALUES
('00000000-0000-0000-0000-000000138021',
 '00000000-0000-0000-0000-000000138001','KETUL','KETUL','UNIT',FALSE,0,TRUE),
('00000000-0000-0000-0000-000000138022',
 '00000000-0000-0000-0000-000000138001','DUS','DUS','PACKAGING',FALSE,0,TRUE);
INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
  uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle)
VALUES('00000000-0000-0000-0000-000000138031',
  '00000000-0000-0000-0000-000000138001','DB','Daging Burger Sapi','Daging',
  '00000000-0000-0000-0000-000000138011',1400,1000,'KETUL',
  '00000000-0000-0000-0000-000000138021',
  '00000000-0000-0000-0000-000000138021',0.6,TRUE,FALSE);
INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
  purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
VALUES('00000000-0000-0000-0000-000000138001',
  '00000000-0000-0000-0000-000000138031',
  '00000000-0000-0000-0000-000000138021',1,FALSE,TRUE,0,1400,TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_job UUID;v_version BIGINT;
  v_reference_count INTEGER;v_input_count INTEGER;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000138091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000138001','PRODUCT_UOM_TEST');
  v_result:=public.get_inventory_product_uom_import_template();
  SELECT count(*) FILTER(WHERE entry.value->>'row_mode'='REFERENCE'),
    count(*) FILTER(WHERE entry.value->>'row_mode'='INPUT')
  INTO v_reference_count,v_input_count
  FROM jsonb_array_elements(v_result) entry(value);
  IF v_reference_count<>1 OR v_input_count<>1
     OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_result) entry(value)
       WHERE entry.value->>'product_sku'='DB') THEN
    RAISE EXCEPTION 'TEST_FAILED: Product-UOM populated template invalid'; END IF;
  v_result:=public.create_master_import_job(
    '00000000-0000-0000-0000-000000138081','PRODUCT_UOM',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','product-uom.csv',repeat('b',64),',');
  v_job:=(v_result->>'jobId')::UUID;v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.stage_master_import_rows(v_job,v_version,jsonb_build_object(
    'productSku','product_sku','productName','product_name','uomName','uom_name',
    'factorToBase','factor_to_base','purchaseAllowed','purchase_allowed',
    'salesAllowed','sales_allowed','purchasePrice','purchase_price',
    'salePrice','sale_price','barcode','barcode',
    'weightIfLargestKg','weight_if_largest_kg'),jsonb_build_array(
    jsonb_build_object('rowNumber',1,'sourceData',jsonb_build_object(
      'product_sku','DB','product_name','Daging Burger Sapi','uom_name','',
      'factor_to_base','','purchase_allowed','','sales_allowed','',
      'purchase_price','','sale_price','','barcode','','weight_if_largest_kg','')),
    jsonb_build_object('rowNumber',2,'sourceData',jsonb_build_object(
      'product_sku','DB','product_name','Daging Burger Sapi','uom_name','DUS',
      'factor_to_base','30','purchase_allowed','true','sales_allowed','true',
      'purchase_price','35190','sale_price','41000','barcode','',
      'weight_if_largest_kg','18.05'))));
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.validate_master_import_job(v_job,v_version);
  IF (v_result->>'createCount')::INTEGER<>1
     OR (v_result->>'skipCount')::INTEGER<>1
     OR (v_result->>'errorCount')::INTEGER<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Product-UOM preview invalid'; END IF;
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.commit_master_import_job(v_job,v_version,0);
  IF v_result->>'status'<>'COMPLETED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Product-UOM commit invalid'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.product_uoms WHERE
    company_id='00000000-0000-0000-0000-000000138001'
    AND product_id='00000000-0000-0000-0000-000000138031'
    AND uom_id='00000000-0000-0000-0000-000000138021'
    AND factor_to_base=1 AND is_active) OR NOT EXISTS(
    SELECT 1 FROM public.product_uoms WHERE
    company_id='00000000-0000-0000-0000-000000138001'
    AND product_id='00000000-0000-0000-0000-000000138031'
    AND uom_id='00000000-0000-0000-0000-000000138022'
    AND factor_to_base=30 AND purchase_allowed AND sales_allowed AND is_active) THEN
    RAISE EXCEPTION 'TEST_FAILED: additive UOM did not preserve base/add DUS'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.products WHERE
    id='00000000-0000-0000-0000-000000138031'
    AND weight_reference_uom_id='00000000-0000-0000-0000-000000138022'
    AND weight_per_uom_kg=18.05) THEN
    RAISE EXCEPTION 'TEST_FAILED: largest UOM weight not updated'; END IF;

  -- A sparse update must preserve omitted flags/prices instead of disabling UOM.
  v_result:=public.create_master_import_job(
    '00000000-0000-0000-0000-000000138082','PRODUCT_UOM',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','product-uom-update.csv',
    repeat('c',64),',');
  v_job:=(v_result->>'jobId')::UUID;v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.stage_master_import_rows(v_job,v_version,jsonb_build_object(
    'productSku','product_sku','productName','product_name','uomName','uom_name',
    'factorToBase','factor_to_base','purchaseAllowed','purchase_allowed',
    'salesAllowed','sales_allowed','purchasePrice','purchase_price',
    'salePrice','sale_price','barcode','barcode',
    'weightIfLargestKg','weight_if_largest_kg'),jsonb_build_array(
    jsonb_build_object('rowNumber',1,'sourceData',jsonb_build_object(
      'product_sku','DB','product_name','Daging Burger Sapi','uom_name','DUS',
      'factor_to_base','30','purchase_allowed','','sales_allowed','',
      'purchase_price','','sale_price','42000','barcode','',
      'weight_if_largest_kg',''))));
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.validate_master_import_job(v_job,v_version);
  IF (v_result->>'updateCount')::INTEGER<>1
     OR (v_result->>'errorCount')::INTEGER<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: sparse Product-UOM update preview invalid'; END IF;
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.commit_master_import_job(v_job,v_version,1);
  IF v_result->>'status'<>'COMPLETED' OR NOT EXISTS(
    SELECT 1 FROM public.product_uoms WHERE
      company_id='00000000-0000-0000-0000-000000138001'
      AND product_id='00000000-0000-0000-0000-000000138031'
      AND uom_id='00000000-0000-0000-0000-000000138022'
      AND factor_to_base=30 AND purchase_allowed AND sales_allowed
      AND purchase_price=35190 AND sale_price=42000 AND is_active) THEN
    RAISE EXCEPTION 'TEST_FAILED: sparse Product-UOM update lost existing values';
  END IF;

  -- One invalid row must not discard a valid update from the same file.
  v_result:=public.create_master_import_job(
    '00000000-0000-0000-0000-000000138083','PRODUCT_UOM',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','product-uom-partial.csv',
    repeat('d',64),',');
  v_job:=(v_result->>'jobId')::UUID;v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.stage_master_import_rows(v_job,v_version,jsonb_build_object(
    'productSku','product_sku','productName','product_name','uomName','uom_name',
    'factorToBase','factor_to_base','purchaseAllowed','purchase_allowed',
    'salesAllowed','sales_allowed','purchasePrice','purchase_price',
    'salePrice','sale_price','barcode','barcode',
    'weightIfLargestKg','weight_if_largest_kg'),jsonb_build_array(
    jsonb_build_object('rowNumber',1,'sourceData',jsonb_build_object(
      'product_sku','DB','product_name','Daging Burger Sapi','uom_name','DUS',
      'factor_to_base','30','purchase_allowed','','sales_allowed','',
      'purchase_price','','sale_price','43000','barcode','',
      'weight_if_largest_kg','')),
    jsonb_build_object('rowNumber',2,'sourceData',jsonb_build_object(
      'product_sku','DOES-NOT-EXIST','product_name','Invalid Product',
      'uom_name','DUS','factor_to_base','30','purchase_allowed','false',
      'sales_allowed','false','purchase_price','','sale_price','',
      'barcode','','weight_if_largest_kg',''))));
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.validate_master_import_job(v_job,v_version);
  IF v_result->>'status'<>'VALIDATED'
     OR (v_result->>'updateCount')::INTEGER<>1
     OR (v_result->>'errorCount')::INTEGER<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: partial Product-UOM preview invalid'; END IF;
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.commit_master_import_job(v_job,v_version,1);
  IF v_result->>'status'<>'COMPLETED_WITH_ERRORS' OR NOT EXISTS(
    SELECT 1 FROM public.product_uoms WHERE
      company_id='00000000-0000-0000-0000-000000138001'
      AND product_id='00000000-0000-0000-0000-000000138031'
      AND uom_id='00000000-0000-0000-0000-000000138022'
      AND sale_price=43000 AND is_active) THEN
    RAISE EXCEPTION 'TEST_FAILED: valid Product-UOM update was discarded by invalid row';
  END IF;
END
$test$;
RESET ROLE;
ROLLBACK;
