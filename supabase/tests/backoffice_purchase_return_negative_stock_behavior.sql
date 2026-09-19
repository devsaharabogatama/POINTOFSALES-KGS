-- Focused rollback-only regression for migration 20260919143000.
-- Kept intentionally small and free of SELECT ... INTO for Supabase SQL Editor.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000191431','bpr-negative@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"BPR Negative Stock Test"}'::jsonb,false,
  'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000191431',
  'bpr-negative@example.invalid','BPR Negative Stock Test',
  'super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET role=excluded.role,name=excluded.name;

DO $bpr_negative$
DECLARE
  v_actor uuid:='00000000-0000-0000-0000-000000191431';
  v_company uuid;v_store uuid;v_terminal uuid;v_warehouse uuid;
  v_category uuid:=gen_random_uuid();v_base_uom uuid:=gen_random_uuid();
  v_pack_uom uuid:=gen_random_uuid();v_unit_uom uuid:=gen_random_uuid();
  v_product uuid:=gen_random_uuid();v_supplier uuid:=gen_random_uuid();
  v_session uuid:=gen_random_uuid();v_order uuid:=gen_random_uuid();
  v_order_line uuid:=gen_random_uuid();v_receipt uuid;v_source uuid;v_source_batch uuid;
  v_other_order uuid:=gen_random_uuid();v_other_line uuid:=gen_random_uuid();
  v_other_receipt uuid;v_other_batch uuid;
  v_replenish_order uuid:=gen_random_uuid();v_replenish_line uuid:=gen_random_uuid();
  v_replenish_receipt uuid;v_return uuid;v_result jsonb;
  v_event public.financial_events%rowtype;v_stock numeric;v_message text;
  v_rejected boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260919143000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20260919143000 required';
  END IF;

  v_result:=(SELECT jsonb_build_object('company',company.id,'store',store.id,
      'terminal',terminal.id,'warehouse',warehouse.id)
    FROM public.companies company
    JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
    JOIN public.pos_terminals terminal ON terminal.company_id=company.id
      AND terminal.store_id=store.id AND terminal.status='ACTIVE'
    JOIN public.warehouses warehouse ON warehouse.company_id=company.id
      AND warehouse.is_active AND warehouse.is_purchase_destination
      AND (warehouse.store_id=store.id OR warehouse.store_id IS NULL)
    WHERE company.status='ACTIVE'
      AND EXISTS(SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
          AND current_date BETWEEN period.start_date AND period.end_date)
      AND EXISTS(SELECT 1 FROM public.transaction_categories category
        WHERE category.company_id=company.id AND category.system_key='PURCHASE_RETURN'
          AND category.is_active)
      AND (SELECT count(DISTINCT account.system_function_key)
        FROM public.chart_of_accounts account WHERE account.company_id=company.id
          AND account.is_active AND account.is_postable
          AND account.system_function_key IN('INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL',
            'PURCHASE_PRICE_VARIANCE'))=3
    ORDER BY company.id,store.id,terminal.id,warehouse.id LIMIT 1);
  v_company:=NULLIF(v_result->>'company','')::uuid;
  v_store:=NULLIF(v_result->>'store','')::uuid;
  v_terminal:=NULLIF(v_result->>'terminal','')::uuid;
  v_warehouse:=NULLIF(v_result->>'warehouse','')::uuid;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: eligible Company runtime missing';
  END IF;

  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  UPDATE public.warehouses SET allow_negative_stock=true,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_warehouse;

  INSERT INTO public.product_categories(id,company_id,category_code,category_name,
    created_by,updated_by)
  VALUES(v_category,v_company,'BPRN-'||left(replace(v_category::text,'-',''),10),
    'BPR negative rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
    decimal_precision,created_by,updated_by)
  VALUES(v_base_uom,v_company,'BNU'||left(replace(v_base_uom::text,'-',''),10),
      'BPR Negative Piece','UNIT',false,0,v_actor,v_actor),
    (v_pack_uom,v_company,'BNP'||left(replace(v_pack_uom::text,'-',''),10),
      'BPR Negative Pack','PACKAGING',false,0,v_actor,v_actor),
    (v_unit_uom,v_company,'BNQ'||left(replace(v_unit_uom::text,'-',''),10),
      'BPR Purchase Piece','UNIT',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
    uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,
    created_by,updated_by)
  VALUES(v_product,v_company,'BPRN-'||left(replace(v_product::text,'-',''),10),
    'BPR negative rollback product','BPR negative rollback category',v_category,
    10,5,'BPR Negative Piece',v_base_uom,v_base_uom,1,true,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES(v_company,v_product,v_base_uom,1,false,true,5,10,true,v_actor,v_actor),
    (v_company,v_product,v_pack_uom,10,true,false,50,100,true,v_actor,v_actor),
    (v_company,v_product,v_unit_uom,1,true,false,5,10,true,v_actor,v_actor);
  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,is_active,
    created_by,updated_by)
  VALUES(v_supplier,v_company,'BPRN-'||left(replace(v_supplier::text,'-',''),10),
    'BPR negative rollback supplier',true,v_actor,v_actor);
  INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,store_id,
    pos_id,status,sales_warehouse_id)
  VALUES(v_session,'BPRN-'||left(replace(v_session::text,'-',''),10),v_actor,
    v_company,v_store,v_terminal,'OPEN'::public.session_status,v_warehouse);

  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,line_count,
    total_ordered_base_qty,estimated_total)
  VALUES(v_order,v_company,'PO-BPRN-'||left(replace(v_order::text,'-',''),10),v_store,
    v_warehouse,v_supplier,current_date,v_actor,'DRAFT',1,10,50);
  INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,
    client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
    ordered_base_qty,estimated_unit_price,estimated_subtotal,product_sku_snapshot,
    product_name_snapshot,ordered_uom_name_snapshot)
  VALUES(v_order_line,v_company,v_order,1,gen_random_uuid(),v_product,v_pack_uom,
    1,10,10,50,50,'BPRN-SKU','BPR negative rollback product','BPR Negative Pack');
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=2,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_order;
  v_result:=public.save_goods_receipt(NULL,NULL,v_session,v_order,'BPRN-SOURCE',
    'BPR negative source',jsonb_build_array(jsonb_build_object(
      'clientLineKey',gen_random_uuid(),'supplierOrderLineId',v_order_line,
      'receivedUomId',v_pack_uom,'receivedQty',1,'acceptedGoodQty',1,
      'damagedQty',0,'rejectedQty',0)));
  v_receipt:=(v_result->>'documentId')::uuid;
  v_result:=public.post_goods_receipt(v_receipt,1,gen_random_uuid());
  v_event:=(SELECT event FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=(v_result->>'financialEventId')::uuid);
  IF v_event.id IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: source event missing'; END IF;
  PERFORM public.post_financial_event_by_id(v_event.id,v_event.event_version);
  v_source:=(SELECT allocation.id
    FROM public.goods_receipt_condition_allocations allocation
    JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
      AND line.id=allocation.receipt_line_id
    WHERE line.company_id=v_company AND line.document_id=v_receipt
      AND allocation.condition_type='GOOD');
  v_source_batch:=(SELECT product_batch_id
    FROM public.goods_receipt_condition_allocations
    WHERE company_id=v_company AND id=v_source);
  IF v_source IS NULL OR v_source_batch IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: source lineage missing';
  END IF;

  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,line_count,
    total_ordered_base_qty,estimated_total)
  VALUES(v_other_order,v_company,'PO-BPRO-'||left(replace(v_other_order::text,'-',''),10),
    v_store,v_warehouse,v_supplier,current_date,v_actor,'DRAFT',1,3,15);
  INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,
    client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
    ordered_base_qty,estimated_unit_price,estimated_subtotal,product_sku_snapshot,
    product_name_snapshot,ordered_uom_name_snapshot)
  VALUES(v_other_line,v_company,v_other_order,1,gen_random_uuid(),v_product,v_unit_uom,
    3,1,3,5,15,'BPRN-SKU','BPR negative rollback product','BPR Purchase Piece');
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=2,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_other_order;
  v_result:=public.save_goods_receipt(NULL,NULL,v_session,v_other_order,'BPRN-OTHER',
    'Unrelated FIFO fixture',jsonb_build_array(jsonb_build_object(
      'clientLineKey',gen_random_uuid(),'supplierOrderLineId',v_other_line,
      'receivedUomId',v_unit_uom,'receivedQty',3,'acceptedGoodQty',3,
      'damagedQty',0,'rejectedQty',0)));
  v_other_receipt:=(v_result->>'documentId')::uuid;
  v_result:=public.post_goods_receipt(v_other_receipt,1,gen_random_uuid());
  v_event:=(SELECT event FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=(v_result->>'financialEventId')::uuid);
  IF v_event.id IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: other event missing'; END IF;
  PERFORM public.post_financial_event_by_id(v_event.id,v_event.event_version);
  v_other_batch:=(SELECT allocation.product_batch_id
    FROM public.goods_receipt_condition_allocations allocation
    JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
      AND line.id=allocation.receipt_line_id
    WHERE line.company_id=v_company AND line.document_id=v_other_receipt
      AND allocation.condition_type='GOOD');
  IF v_other_batch IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: unrelated FIFO missing'; END IF;

  UPDATE public.product_batches SET qty_remaining=0
  WHERE company_id=v_company AND id=v_source_batch;
  UPDATE public.product_stocks SET stock_qty=3,updated_at=clock_timestamp()
  WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;

  v_result:=public.save_backoffice_purchase_return_draft(NULL,NULL,gen_random_uuid(),
    v_receipt,v_warehouse,current_date,'Exhausted FIFO negative-stock regression',
    NULL,NULL,jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'sourceConditionAllocationId',v_source,'returnUomId',v_pack_uom,'returnQty',1)));
  v_return:=(v_result->>'documentId')::uuid;
  v_result:=public.review_purchase_return(v_return,
    (v_result->>'masterVersion')::bigint,'APPROVE',NULL);
  v_result:=public.post_backoffice_purchase_return(v_return,
    (v_result->>'masterVersion')::bigint,'00000000-0000-0000-0000-000000191432');
  IF v_result->>'status'<>'POSTED'
    OR (v_result->>'apProvisionalReduction')::numeric<>50 THEN
    RAISE EXCEPTION 'TEST_FAILED: exhausted FIFO Return post invalid: %',v_result;
  END IF;
  v_stock:=(SELECT stock_qty FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse);
  IF v_stock<>-7 THEN RAISE EXCEPTION 'TEST_FAILED: expected Stock -7, got %',v_stock; END IF;
  IF (SELECT qty_remaining FROM public.product_batches
      WHERE company_id=v_company AND id=v_other_batch)<>3 THEN
    RAISE EXCEPTION 'TEST_FAILED: unrelated FIFO was consumed';
  END IF;
  IF (SELECT COALESCE(sum(shortage_base_qty),0)
      FROM public.purchase_return_stock_shortages
      WHERE company_id=v_company AND document_id=v_return)<>10 THEN
    RAISE EXCEPTION 'TEST_FAILED: source-linked shortage 10 missing';
  END IF;
  v_result:=public.post_backoffice_purchase_return(v_return,1,
    '00000000-0000-0000-0000-000000191432');
  IF COALESCE((v_result->>'idempotentReplay')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: exact Post retry not idempotent';
  END IF;

  v_rejected:=false;
  BEGIN
    PERFORM public.save_backoffice_purchase_return_draft(NULL,NULL,gen_random_uuid(),
      v_receipt,v_warehouse,current_date,'Over-return rejection',NULL,NULL,
      jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
        'sourceConditionAllocationId',v_source,'returnUomId',v_base_uom,'returnQty',1)));
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message LIKE '%PURCHASE_RETURN_QUANTITY_EXCEEDS_AVAILABLE%' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: over-return accepted'; END IF;

  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,line_count,
    total_ordered_base_qty,estimated_total)
  VALUES(v_replenish_order,v_company,
    'PO-BPRR-'||left(replace(v_replenish_order::text,'-',''),10),v_store,
    v_warehouse,v_supplier,current_date,v_actor,'DRAFT',1,10,60);
  INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,
    client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
    ordered_base_qty,estimated_unit_price,estimated_subtotal,product_sku_snapshot,
    product_name_snapshot,ordered_uom_name_snapshot)
  VALUES(v_replenish_line,v_company,v_replenish_order,1,gen_random_uuid(),v_product,
    v_pack_uom,1,10,10,60,60,'BPRN-SKU','BPR negative rollback product','BPR Negative Pack');
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=2,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_replenish_order;
  v_result:=public.save_goods_receipt(NULL,NULL,v_session,v_replenish_order,
    'BPRN-REPLENISH','Shortage replenishment',jsonb_build_array(jsonb_build_object(
      'clientLineKey',gen_random_uuid(),'supplierOrderLineId',v_replenish_line,
      'receivedUomId',v_pack_uom,'receivedQty',1,'acceptedGoodQty',1,
      'damagedQty',0,'rejectedQty',0)));
  v_replenish_receipt:=(v_result->>'documentId')::uuid;
  v_result:=public.post_goods_receipt(v_replenish_receipt,1,gen_random_uuid());
  v_event:=(SELECT event FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=(v_result->>'financialEventId')::uuid);
  IF v_event.id IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: replenishment event missing'; END IF;
  PERFORM public.post_financial_event_by_id(v_event.id,v_event.event_version);

  v_stock:=(SELECT stock_qty FROM public.product_stocks
    WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse);
  IF v_stock<>3 THEN RAISE EXCEPTION 'TEST_FAILED: expected final Stock 3, got %',v_stock; END IF;
  IF (SELECT qty_remaining FROM public.product_batches
      WHERE company_id=v_company AND id=v_other_batch)<>3 THEN
    RAISE EXCEPTION 'TEST_FAILED: replenishment changed unrelated FIFO';
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_return_stock_shortages
      WHERE company_id=v_company AND document_id=v_return AND reconciled_at IS NULL) THEN
    RAISE EXCEPTION 'TEST_FAILED: shortage remains open';
  END IF;
  IF NOT EXISTS(SELECT 1
    FROM public.purchase_return_shortage_cost_adjustments adjustment
    JOIN public.finance_journals journal
      ON journal.company_id=adjustment.company_id
     AND journal.financial_event_id=adjustment.financial_event_id
    WHERE adjustment.company_id=v_company
      AND adjustment.goods_receipt_id=v_replenish_receipt
      AND adjustment.purchase_price_variance_total=10
      AND adjustment.status='POSTED' AND journal.status='POSTED'
      AND journal.total_debit=journal.total_credit) THEN
    RAISE EXCEPTION 'TEST_FAILED: balanced PPV correction 10 missing';
  END IF;
END
$bpr_negative$;

ROLLBACK;
SELECT 'backoffice_purchase_return_negative_stock_behavior' check_name,
  'PASS' status,0::bigint violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'exhausted exact FIFO remains commercially returnable',
    'negative On Hand restored without unrelated FIFO consumption',
    'source-linked shortage','exact retry','over-return rejection',
    'later Receipt shortage reconciliation','balanced PPV correction',
    'all fixture writes rolled back')) details;
