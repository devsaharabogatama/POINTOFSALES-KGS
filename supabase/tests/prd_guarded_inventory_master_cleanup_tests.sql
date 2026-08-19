-- PRD behavior: unused UOM/Category delete, used-master protection, and safe edit.
-- SAFETY: all fixtures, deletes, and audit rows are rolled back.

BEGIN;

INSERT INTO auth.users(
  id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at
) VALUES
('00000000-0000-0000-0000-000000136091','prd136-admin@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"PRD136 Admin"}'::JSONB,FALSE,'authenticated','authenticated',now()),
('00000000-0000-0000-0000-000000136092','prd136-finance@example.invalid',
 '00000000-0000-0000-0000-000000000000',
 '{"provider":"email","providers":["email"]}'::JSONB,
 '{"name":"PRD136 Finance"}'::JSONB,FALSE,'authenticated','authenticated',now())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role) VALUES
('00000000-0000-0000-0000-000000136091','prd136-admin@example.invalid','PRD136 Admin','cashier'::public.user_role),
('00000000-0000-0000-0000-000000136092','prd136-finance@example.invalid','PRD136 Finance','cashier'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
('00000000-0000-0000-0000-000000136001','PRD136A','PRD136 Company A','prd136-company-a','ACTIVE'),
('00000000-0000-0000-0000-000000136002','PRD136B','PRD136 Company B','prd136-company-b','ACTIVE');

INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company
) VALUES
('00000000-0000-0000-0000-000000136001','00000000-0000-0000-0000-000000136091','COMPANY_ADMIN','ACTIVE',TRUE),
('00000000-0000-0000-0000-000000136001','00000000-0000-0000-0000-000000136092','FINANCE','ACTIVE',TRUE);

INSERT INTO public.product_categories(
  id,company_id,category_code,category_name,is_active
) VALUES
('00000000-0000-0000-0000-000000136011','00000000-0000-0000-0000-000000136001','PRD136-USED','PRD136 Used Category',TRUE),
('00000000-0000-0000-0000-000000136012','00000000-0000-0000-0000-000000136002','PRD136-OTHER','PRD136 Other Category',TRUE);

INSERT INTO public.uoms(
  id,company_id,code,name,uom_type,allow_decimal,decimal_precision,is_active
) VALUES
('00000000-0000-0000-0000-000000136021','00000000-0000-0000-0000-000000136001','PRD136-U','PRD136 Used UOM','UNIT',FALSE,0,TRUE),
('00000000-0000-0000-0000-000000136022','00000000-0000-0000-0000-000000136002','PRD136-O','PRD136 Other UOM','UNIT',FALSE,0,TRUE);

INSERT INTO public.products(
  id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
  weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle
) VALUES(
  '00000000-0000-0000-0000-000000136031',
  '00000000-0000-0000-0000-000000136001',
  'PRD136-P','PRD136 Product','PRD136 Used Category',
  '00000000-0000-0000-0000-000000136011',20,10,'PRD136 Used UOM',
  '00000000-0000-0000-0000-000000136021',
  '00000000-0000-0000-0000-000000136021',1,TRUE,FALSE
);
INSERT INTO public.product_uoms(
  company_id,product_id,uom_id,factor_to_base,purchase_allowed,sales_allowed,
  purchase_price,sale_price,is_active
) VALUES(
  '00000000-0000-0000-0000-000000136001',
  '00000000-0000-0000-0000-000000136031',
  '00000000-0000-0000-0000-000000136021',1,TRUE,TRUE,10,20,TRUE
);

SET LOCAL ROLE authenticated;
DO $test$
DECLARE
  v_result JSONB;
  v_uom UUID;
  v_category UUID;
  v_version BIGINT;
  v_rejected BOOLEAN;
BEGIN
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000136091','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000136001','PRD136_TEST');

  v_result:=public.save_inventory_uom(
    NULL,NULL,'PRD136 Salah Import UOM','OTHER',FALSE,0::SMALLINT,TRUE
  );
  v_uom:=(v_result#>>'{data,id}')::UUID;
  v_version:=(v_result#>>'{data,master_version}')::BIGINT;
  v_result:=public.save_inventory_uom(
    v_uom,v_version,'PRD136 Salah Import UOM Diperbaiki','OTHER',FALSE,0::SMALLINT,TRUE
  );
  v_version:=(v_result#>>'{data,master_version}')::BIGINT;
  v_result:=public.delete_inventory_uom(v_uom,v_version);
  IF v_result->>'action'<>'DELETE' THEN
    RAISE EXCEPTION 'TEST_FAILED: unused UOM delete failed';
  END IF;
  v_result:=public.delete_inventory_uom(v_uom,v_version);
  IF v_result->>'action'<>'EXACT_RETRY' THEN
    RAISE EXCEPTION 'TEST_FAILED: UOM delete retry invalid';
  END IF;

  v_result:=public.save_inventory_product_category(
    NULL,NULL,'PRD136 Salah Import Category',TRUE
  );
  v_category:=(v_result#>>'{data,id}')::UUID;
  v_version:=(v_result#>>'{data,master_version}')::BIGINT;
  v_result:=public.delete_inventory_product_category(v_category,v_version);
  IF v_result->>'action'<>'DELETE' THEN
    RAISE EXCEPTION 'TEST_FAILED: unused Category delete failed';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.delete_inventory_uom(
      '00000000-0000-0000-0000-000000136021',1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='UOM_IN_USE' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: used UOM deleted'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.save_inventory_uom(
      '00000000-0000-0000-0000-000000136021',1,
      'PRD136 Used UOM','WEIGHT',TRUE,3::SMALLINT,TRUE
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='UOM_SEMANTICS_LOCKED_BY_USAGE' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: used UOM semantics changed'; END IF;

  v_result:=public.save_inventory_uom(
    '00000000-0000-0000-0000-000000136021',1,
    'PRD136 Used UOM Renamed','UNIT',FALSE,0::SMALLINT,FALSE
  );
  IF v_result->>'action'<>'UPDATE' THEN
    RAISE EXCEPTION 'TEST_FAILED: safe used UOM edit rejected';
  END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.delete_inventory_product_category(
      '00000000-0000-0000-0000-000000136011',1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='PRODUCT_CATEGORY_IN_USE' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: used Category deleted'; END IF;

  v_rejected:=FALSE;
  BEGIN
    PERFORM public.delete_inventory_uom(
      '00000000-0000-0000-0000-000000136022',1
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='MASTER_NOT_FOUND' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company UOM visible'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub','00000000-0000-0000-0000-000000136092','role','authenticated')::TEXT,TRUE);
  PERFORM public.set_active_company_context(
    '00000000-0000-0000-0000-000000136001','PRD136_TEST'
  );
  v_rejected:=FALSE;
  BEGIN
    PERFORM public.delete_inventory_uom(
      '00000000-0000-0000-0000-000000136021',2
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance deleted UOM'; END IF;
END
$test$;

RESET ROLE;
DO $verify$
DECLARE v_count BIGINT;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.inventory_master_write_audit
  WHERE company_id='00000000-0000-0000-0000-000000136001'
    AND action='DELETE'
    AND master_type IN('UOM','PRODUCT_CATEGORY');
  IF v_count<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: delete audit count %, expected 2',v_count;
  END IF;
  RAISE NOTICE 'TEST PASSED: unused UOM/Category delete is tenant-safe, guarded, versioned, retry-safe, audited, and used masters remain protected.';
END
$verify$;

ROLLBACK;
