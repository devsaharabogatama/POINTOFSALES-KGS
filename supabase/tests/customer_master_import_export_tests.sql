-- Customer master CSV import/export behavior. Every fixture rolls back.

BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at) VALUES(
  '00000000-0000-0000-0000-000000137091','customer-import@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::JSONB,
  '{"name":"Customer Import Admin"}'::JSONB,FALSE,'authenticated',
  'authenticated',now()) ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role) VALUES(
  '00000000-0000-0000-0000-000000137091','customer-import@example.invalid',
  'Customer Import Admin','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,
  role=EXCLUDED.role;
INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000137001','CUST137',
  'Customer Import Test','customer-import-test','ACTIVE');
INSERT INTO public.company_memberships(company_id,user_id,role_code,status,
  is_default_company) VALUES(
  '00000000-0000-0000-0000-000000137001',
  '00000000-0000-0000-0000-000000137091','COMPANY_ADMIN','ACTIVE',TRUE);
INSERT INTO public.customer_categories(id,company_id,category_code,category_name,
  is_system_category,is_active) VALUES(
  '00000000-0000-0000-0000-000000137011',
  '00000000-0000-0000-0000-000000137001','RETAIL','Retail Test',FALSE,TRUE);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE v_result JSONB;v_workspace JSONB;v_job UUID;v_version BIGINT;
  v_customer UUID;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000137091',
    'role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000137001','CUST_IMPORT_TEST');

  v_result:=public.create_master_import_job(
    '00000000-0000-0000-0000-000000137081','CUSTOMER',
    'REFERENCE_BY_NAME','CREATE_AND_UPDATE','customer.csv',repeat('a',64),',');
  v_job:=(v_result->>'jobId')::UUID;v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.stage_master_import_rows(v_job,v_version,
    jsonb_build_object('customerCode','code','customerName','name',
      'categoryName','customer_category_name','parentCustomerName','parent_customer_name',
      'defaultPricelistName','default_pricelist_name','phone','phone','email','email',
      'address','address','customerType','customer_type','creditLimit','credit_limit',
      'creditTermDays','credit_term_days','notes','notes','isActive','is_active'),
    jsonb_build_array(jsonb_build_object('rowNumber',1,'sourceData',jsonb_build_object(
      'code','CUST-137','name','Customer CSV Test',
      'customer_category_name','Retail Test','parent_customer_name','',
      'default_pricelist_name','','phone','08123456789','email','TEST@EXAMPLE.INVALID',
      'address','Alamat Test','customer_type','BUSINESS','credit_limit','250000',
      'credit_term_days','30','notes','Import behavior','is_active','true'))));
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.validate_master_import_job(v_job,v_version);
  IF (v_result->>'createCount')::INTEGER<>1 OR
     (v_result->>'errorCount')::INTEGER<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer preview invalid';
  END IF;
  v_version:=(v_result->>'masterVersion')::BIGINT;
  v_result:=public.commit_master_import_job(v_job,v_version,0);
  IF v_result->>'status'<>'COMPLETED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer commit invalid';
  END IF;
  -- Verify through the guarded composed read. Direct Customer/Audit SELECT is
  -- intentionally unavailable to authenticated after ACP-5A enforcement.
  v_workspace:=public.get_contacts_customers(TRUE);
  SELECT (item->>'id')::UUID INTO v_customer
  FROM jsonb_array_elements(v_workspace->'data') item
  WHERE item->>'code'='CUST-137'
    AND item->>'name'='Customer CSV Test'
    AND item->>'email'='test@example.invalid'
    AND (item->>'credit_limit')::NUMERIC=250000
    AND (item->>'credit_term_days')::INTEGER=30
    AND NOT (item->>'is_system_customer')::BOOLEAN;
  IF v_customer IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: Customer not stored'; END IF;
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_workspace->'audit') item
    WHERE (item->>'customer_id')::UUID=v_customer
      AND item->>'action'='CREATE') THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer audit missing';
  END IF;
  v_result:=public.export_contacts_customers();
  IF jsonb_array_length(v_result)<>1 OR v_result->0->>'customer_code'<>'CUST-137'
     OR EXISTS(SELECT 1 FROM jsonb_array_elements(v_result) row
       WHERE row->>'customer_code'='WALK-IN') THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer export invalid';
  END IF;
  v_result:=public.commit_master_import_job(v_job,v_version,0);
  IF v_result->>'action'<>'EXISTING' THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer commit retry not idempotent';
  END IF;
END
$test$;
RESET ROLE;
ROLLBACK;
