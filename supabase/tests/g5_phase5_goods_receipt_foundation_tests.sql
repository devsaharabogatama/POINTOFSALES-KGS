-- G5 phase 5 behavior: atomic Goods Receipt posting.
-- SAFETY: all fixtures and effects are rolled back.
BEGIN;

DO $test$
DECLARE
 v_actor UUID;v_company UUID:='00000000-0000-0000-0000-000000091001';
 v_store UUID:='00000000-0000-0000-0000-000000091011';
 v_terminal UUID:='00000000-0000-0000-0000-000000091021';
 v_good_wh UUID:='00000000-0000-0000-0000-000000091031';
 v_damaged_wh UUID:='00000000-0000-0000-0000-000000091032';
 v_category UUID:='00000000-0000-0000-0000-000000091041';
 v_uom UUID:='00000000-0000-0000-0000-000000091051';
 v_product UUID:='00000000-0000-0000-0000-000000091061';
 v_supplier UUID:='00000000-0000-0000-0000-000000091071';
 v_session UUID:='00000000-0000-0000-0000-000000091081';
 v_order UUID:='00000000-0000-0000-0000-000000091091';
 v_order_line UUID:='00000000-0000-0000-0000-000000091092';
 v_receipt UUID;v_result JSONB;v_count BIGINT;v_value NUMERIC;v_status TEXT;
BEGIN
 SELECT profile.id INTO v_actor FROM public.profiles profile
 JOIN auth.users auth_user ON auth_user.id=profile.id
 WHERE profile.role='super_admin'::public.user_role
  AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
   WHERE session.cashier_id=profile.id AND session.status='OPEN'::public.session_status)
 ORDER BY profile.id LIMIT 1;
 IF v_actor IS NULL THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: available linked Super Admin required';
 END IF;

 INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
 VALUES(v_company,'G91A','G91 Company','g91-company','ACTIVE');
 INSERT INTO public.stores(id,company_id,store_code,store_name,status)
 VALUES(v_store,v_company,'G91S','G91 Store','ACTIVE');
 INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status)
 VALUES(v_terminal,v_company,v_store,'G91P','G91 POS','ACTIVE');
 INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,
  is_sale_source,is_purchase_destination,is_active)
 VALUES
  (v_good_wh,v_company,'G91GOOD','G91 Good Warehouse','STORE',v_store,FALSE,TRUE,TRUE),
  (v_damaged_wh,v_company,'G91DMG','G91 Damaged Warehouse','DAMAGED',v_store,FALSE,FALSE,TRUE);
 INSERT INTO public.product_categories(id,company_id,category_code,category_name)
 VALUES(v_category,v_company,'G91CAT','G91 Product');
 INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision)
 VALUES(v_uom,v_company,'G91PCS','Piece','UNIT',FALSE,0);
 INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
  uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle)
 VALUES(v_product,v_company,'G91-PROD','G91 Product','G91 Product',v_category,
  100,45,'G91PCS',v_uom,v_uom,1,TRUE,FALSE);
 INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
  purchase_allowed,sales_allowed,purchase_price,sale_price,is_active)
 VALUES(v_company,v_product,v_uom,1,TRUE,TRUE,45,100,TRUE);
 INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,created_by,updated_by)
 VALUES(v_supplier,v_company,'G91SUP','G91 Supplier',v_actor,v_actor);
 INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,store_id,
  pos_id,status,sales_warehouse_id)
 VALUES(v_session,'G91-SESSION',v_actor,v_company,v_store,v_terminal,
  'OPEN'::public.session_status,v_good_wh);

 INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
  destination_warehouse_id,supplier_id,order_date,ordered_by,status,confirmed_by,
  confirmed_at,confirmation_idempotency_key,line_count,total_ordered_base_qty,
  estimated_total)
 VALUES(v_order,v_company,'PO-G91',v_store,v_good_wh,v_supplier,current_date,
  v_actor,'DRAFT',NULL,NULL,NULL,1,10,450);
 INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,
  client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
  ordered_base_qty,estimated_unit_price,estimated_subtotal,product_sku_snapshot,
  product_name_snapshot,ordered_uom_name_snapshot)
 VALUES(v_order_line,v_company,v_order,1,
  '00000000-0000-0000-0000-000000091094',v_product,v_uom,10,1,10,45,450,
  'G91-PROD','G91 Product','Piece');
 UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
  confirmed_at=clock_timestamp(),confirmation_idempotency_key=
   '00000000-0000-0000-0000-000000091093',master_version=2
 WHERE company_id=v_company AND id=v_order;

 PERFORM set_config('request.jwt.claims',jsonb_build_object(
  'sub',v_actor,'role','authenticated')::TEXT,TRUE);
 PERFORM public.set_active_company_context(v_company,'G5_PHASE5_TEST');

 v_result:=public.save_goods_receipt(NULL,NULL,v_session,v_order,'DEL-G91',
  'Good, damaged, rejected, and over receipt',jsonb_build_array(jsonb_build_object(
   'clientLineKey','00000000-0000-0000-0000-000000091101',
   'supplierOrderLineId',v_order_line,'receivedUomId',v_uom,'receivedQty',12,
   'acceptedGoodQty',7,'damagedQty',2,'rejectedQty',3)));
 v_receipt:=(v_result->>'documentId')::UUID;
 IF v_result->>'status'<>'DRAFT' OR (v_result->>'masterVersion')::BIGINT<>1 THEN
  RAISE EXCEPTION 'TEST_FAILED: receipt draft invalid: %',v_result;
 END IF;
 SELECT count(*) INTO v_count FROM public.goods_receipt_lines
 WHERE document_id=v_receipt AND is_over_received AND over_received_base_qty=2
  AND provisional_ap_amount=405;
 IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: condition/over/AP snapshot invalid'; END IF;

 v_result:=public.post_goods_receipt(v_receipt,1,
  '00000000-0000-0000-0000-000000091111');
 IF v_result->>'status'<>'POSTED' OR (v_result->>'idempotentReplay')::BOOLEAN THEN
  RAISE EXCEPTION 'TEST_FAILED: receipt post invalid: %',v_result;
 END IF;
 SELECT stock_qty INTO v_value FROM public.product_stocks
 WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_good_wh;
 IF v_value<>7 THEN RAISE EXCEPTION 'TEST_FAILED: good stock %, expected 7',v_value; END IF;
 SELECT stock_qty INTO v_value FROM public.product_stocks
 WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_damaged_wh;
 IF v_value<>2 THEN RAISE EXCEPTION 'TEST_FAILED: damaged stock %, expected 2',v_value; END IF;
 SELECT count(*) INTO v_count FROM public.product_batches
 WHERE company_id=v_company AND goods_receipt_line_id IS NOT NULL;
 IF v_count<>2 THEN RAISE EXCEPTION 'TEST_FAILED: FIFO layers %, expected 2',v_count; END IF;
 SELECT count(*) INTO v_count FROM public.stock_movements
 WHERE company_id=v_company AND reference_table='goods_receipt_documents'
  AND reference_id=v_receipt AND movement_type='PURCHASE';
 IF v_count<>2 THEN RAISE EXCEPTION 'TEST_FAILED: movements %, expected 2',v_count; END IF;
 SELECT COALESCE(sum(amount),0) INTO v_value FROM public.goods_receipt_ap_provisionals
 WHERE company_id=v_company AND receipt_id=v_receipt;
 IF v_value<>405 THEN RAISE EXCEPTION 'TEST_FAILED: provisional AP %, expected 405',v_value; END IF;
 SELECT status INTO v_status FROM public.supplier_order_documents WHERE id=v_order;
 IF v_status<>'RECEIVED' THEN RAISE EXCEPTION 'TEST_FAILED: order status %',v_status; END IF;

 v_result:=public.post_goods_receipt(v_receipt,2,
  '00000000-0000-0000-0000-000000091111');
 IF NOT (v_result->>'idempotentReplay')::BOOLEAN THEN
  RAISE EXCEPTION 'TEST_FAILED: post replay was not idempotent';
 END IF;
 SELECT count(*) INTO v_count FROM public.financial_events
 WHERE company_id=v_company AND source_table='goods_receipt_documents'
  AND source_id=v_receipt AND status='HOLD';
 IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: Finance HOLD count %',v_count; END IF;
 IF has_table_privilege('authenticated','public.goods_receipt_documents',
      'INSERT,UPDATE,DELETE')
  OR has_table_privilege('authenticated','public.goods_receipt_lines',
      'INSERT,UPDATE,DELETE')
  OR NOT has_function_privilege('authenticated',
      'public.post_goods_receipt(uuid,bigint,uuid)','EXECUTE') THEN
  RAISE EXCEPTION 'TEST_FAILED: Goods Receipt privilege boundary invalid';
 END IF;
 RAISE NOTICE 'TEST PASSED: Goods Receipt is atomic, condition-aware, over-receipt-safe, FIFO/Stock/AP connected, idempotent, and audited.';
END
$test$;

ROLLBACK;
