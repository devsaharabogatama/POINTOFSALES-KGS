-- Rollback-safe Backoffice Goods Receipt behavior.
-- Fully synthetic fixture: no frontend action and no existing business master required.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000138091',
  'backoffice-receipt-test@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::JSONB,
  '{"name":"Backoffice Receipt Test"}'::JSONB,FALSE,
  'authenticated','authenticated',clock_timestamp());

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000138091',
  'backoffice-receipt-test@example.invalid','Backoffice Receipt Test','cashier')
ON CONFLICT(id) DO UPDATE SET
  email=EXCLUDED.email,name=EXCLUDED.name,role=EXCLUDED.role;

INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
VALUES('00000000-0000-0000-0000-000000138001','GRB138',
  'Goods Receipt Behavior Company','goods-receipt-behavior-company','ACTIVE');

INSERT INTO public.company_memberships(
  company_id,user_id,role_code,status,is_default_company)
VALUES('00000000-0000-0000-0000-000000138001',
  '00000000-0000-0000-0000-000000138091','COMPANY_ADMIN','ACTIVE',TRUE);

INSERT INTO public.stores(id,company_id,store_code,store_name,status)
VALUES('00000000-0000-0000-0000-000000138011',
  '00000000-0000-0000-0000-000000138001','GRB138-S','Receipt Test Store','ACTIVE');

INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,
  is_sale_source,is_purchase_destination,is_active)
VALUES('00000000-0000-0000-0000-000000138031',
  '00000000-0000-0000-0000-000000138001','GRB138-W',
  'Receipt Test Warehouse','STORE',
  '00000000-0000-0000-0000-000000138011',TRUE,TRUE,TRUE);

INSERT INTO public.product_categories(id,company_id,category_code,category_name)
VALUES('00000000-0000-0000-0000-000000138041',
  '00000000-0000-0000-0000-000000138001','GRB138-C','Receipt Test Category');

INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
  decimal_precision)
VALUES('00000000-0000-0000-0000-000000138051',
  '00000000-0000-0000-0000-000000138001','GRB138-U','Piece','UNIT',FALSE,0);

INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
  uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle)
VALUES('00000000-0000-0000-0000-000000138061',
  '00000000-0000-0000-0000-000000138001','GRB138-P','Receipt Test Product',
  'Receipt Test Category','00000000-0000-0000-0000-000000138041',100,50,
  'Piece','00000000-0000-0000-0000-000000138051',
  '00000000-0000-0000-0000-000000138051',1,TRUE,FALSE);

INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
  purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
VALUES('00000000-0000-0000-0000-000000138001',
  '00000000-0000-0000-0000-000000138061',
  '00000000-0000-0000-0000-000000138051',1,TRUE,TRUE,50,100,TRUE);

INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,
  created_by,updated_by)
VALUES('00000000-0000-0000-0000-000000138071',
  '00000000-0000-0000-0000-000000138001','GRB138-SUP',
  'Receipt Test Supplier','00000000-0000-0000-0000-000000138091',
  '00000000-0000-0000-0000-000000138091');

INSERT INTO public.supplier_order_documents(
  id,company_id,order_no,store_id,destination_warehouse_id,supplier_id,
  order_date,expected_date,ordered_by,status,line_count,
  total_ordered_base_qty,estimated_total)
VALUES('00000000-0000-0000-0000-000000138081',
  '00000000-0000-0000-0000-000000138001','GRB138-PO',
  '00000000-0000-0000-0000-000000138011',
  '00000000-0000-0000-0000-000000138031',
  '00000000-0000-0000-0000-000000138071',current_date,current_date,
  '00000000-0000-0000-0000-000000138091','DRAFT',1,1,50);

INSERT INTO public.supplier_order_lines(
  id,company_id,document_id,line_no,client_line_key,product_id,
  ordered_uom_id,ordered_qty,factor_to_base_snapshot,ordered_base_qty,
  estimated_unit_price,estimated_subtotal,product_sku_snapshot,
  product_name_snapshot,ordered_uom_name_snapshot)
VALUES('00000000-0000-0000-0000-000000138082',
  '00000000-0000-0000-0000-000000138001',
  '00000000-0000-0000-0000-000000138081',1,
  '00000000-0000-0000-0000-000000138083',
  '00000000-0000-0000-0000-000000138061',
  '00000000-0000-0000-0000-000000138051',1,1,1,50,50,
  'GRB138-P','Receipt Test Product','Piece');

UPDATE public.supplier_order_documents SET status='CONFIRMED',
  confirmed_by='00000000-0000-0000-0000-000000138091',
  confirmed_at=clock_timestamp(),
  confirmation_idempotency_key='00000000-0000-0000-0000-000000138084',
  master_version=2,updated_at=clock_timestamp()
WHERE id='00000000-0000-0000-0000-000000138081';

INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
VALUES('00000000-0000-0000-0000-000000138091',
  '00000000-0000-0000-0000-000000138001','BACKOFFICE');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims',jsonb_build_object(
  'sub','00000000-0000-0000-0000-000000138091',
  'role','authenticated')::TEXT,TRUE);

DO $test$
DECLARE v_workspace JSONB;v_result JSONB;v_document UUID;v_version BIGINT;
BEGIN
  v_workspace:=public.get_backoffice_goods_receipt_workspace();
  IF jsonb_array_length(v_workspace->'orders')<>1
     OR v_workspace->'orders'->0->>'id'<>
       '00000000-0000-0000-0000-000000138081' THEN
    RAISE EXCEPTION 'TEST_FAILED: temporary receivable Order missing from workspace';
  END IF;

  v_result:=public.save_backoffice_goods_receipt(NULL,NULL,
    '00000000-0000-0000-0000-000000138081','SJ-ROLLBACK',
    'Rollback behavior',jsonb_build_array(jsonb_build_object(
      'clientLineKey','00000000-0000-0000-0000-000000138085',
      'supplierOrderLineId','00000000-0000-0000-0000-000000138082',
      'receivedUomId','00000000-0000-0000-0000-000000138051',
      'receivedQty',1,'acceptedGoodQty',1,'damagedQty',0,'rejectedQty',0)));
  v_document:=(v_result->>'documentId')::UUID;
  v_version:=(v_result->>'masterVersion')::BIGINT;

  v_workspace:=public.get_backoffice_goods_receipt_workspace();
  IF jsonb_array_length(v_workspace->'drafts')<>1
     OR v_workspace->'drafts'->0->>'id'<>v_document::TEXT THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Draft missing from guarded workspace';
  END IF;
  v_result:=public.cancel_backoffice_goods_receipt(v_document,v_version);
  IF v_result->>'status'<>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Draft cancel invalid';
  END IF;
END
$test$;

ROLLBACK;
SELECT 'backoffice_goods_receipt_behavior' test_name,'PASS' status,
  'All synthetic identities, masters, PO, Receipt Draft, audit and context rolled back.' details;
