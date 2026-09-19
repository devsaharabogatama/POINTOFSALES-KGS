-- Authenticated rollback-only Backoffice Supplier Return behavior.
-- Creates its own PO/Receipt/Bill/Payment/Return fixture and leaves no rows.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000191401','backoffice-purchase-return@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Backoffice Purchase Return Test"}'::jsonb,false,
  'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000191401',
  'backoffice-purchase-return@example.invalid','Backoffice Purchase Return Test',
  'super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET role=excluded.role,name=excluded.name;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000191401';v_company uuid;
  v_store uuid;v_terminal uuid;v_warehouse uuid;v_category uuid:=gen_random_uuid();
  v_base_uom uuid:=gen_random_uuid();v_pack_uom uuid:=gen_random_uuid();
  v_product uuid:=gen_random_uuid();v_supplier uuid:=gen_random_uuid();
  v_session uuid:=gen_random_uuid();v_order uuid:=gen_random_uuid();
  v_order_line uuid:=gen_random_uuid();v_receipt uuid;v_source uuid;v_provisional uuid;
  v_invoice uuid;v_payment uuid;v_stale_payment uuid;v_stale_payment_version bigint;
  v_bank uuid;v_pos_return uuid;v_return_one uuid;v_return_two uuid;
  v_result jsonb;v_event public.financial_events%rowtype;v_count bigint;v_value numeric;
  v_version bigint;v_rejected boolean:=false;v_message text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260919140000','20260919141000','20260919142000'))<>3 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Backoffice Purchase Return migrations required';
  END IF;
  SELECT company.id,store.id,terminal.id,warehouse.id
    INTO v_company,v_store,v_terminal,v_warehouse
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.pos_terminals terminal ON terminal.company_id=store.company_id
    AND terminal.store_id=store.id AND terminal.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=store.company_id
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
          'SUPPLIER_AP_FINAL','SUPPLIER_REFUND_RECEIVABLE','BANK'))=5
  ORDER BY company.id,store.id,terminal.id,warehouse.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with Store, POS, Warehouse, open period, and Purchase Return COA required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);

  INSERT INTO public.product_categories(id,company_id,category_code,category_name,
    created_by,updated_by)
  VALUES(v_category,v_company,'BPR-'||left(replace(v_category::text,'-',''),12),
    'Backoffice Return rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
    decimal_precision,created_by,updated_by)
  VALUES(v_base_uom,v_company,'BPRU'||left(replace(v_base_uom::text,'-',''),10),
      'Return Piece','UNIT',false,0,v_actor,v_actor),
    (v_pack_uom,v_company,'BPRP'||left(replace(v_pack_uom::text,'-',''),10),
      'Return Pack','PACKAGING',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
    uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,
    created_by,updated_by)
  VALUES(v_product,v_company,'BPR-'||left(replace(v_product::text,'-',''),12),
    'Backoffice Return rollback product','Backoffice Return rollback category',
    v_category,10,5,'Return Piece',v_base_uom,v_base_uom,1,true,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES(v_company,v_product,v_base_uom,1,false,true,5,10,true,v_actor,v_actor),
    (v_company,v_product,v_pack_uom,10,true,false,50,100,true,v_actor,v_actor);
  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,is_active,
    created_by,updated_by)
  VALUES(v_supplier,v_company,'BPR-'||left(replace(v_supplier::text,'-',''),12),
    'Backoffice Return rollback supplier',true,v_actor,v_actor);
  INSERT INTO public.cashier_sessions(id,session_code,cashier_id,company_id,store_id,
    pos_id,status,sales_warehouse_id)
  VALUES(v_session,'BPR-'||left(replace(v_session::text,'-',''),12),v_actor,
    v_company,v_store,v_terminal,'OPEN'::public.session_status,v_warehouse);
  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,confirmed_by,
    confirmed_at,confirmation_idempotency_key,line_count,total_ordered_base_qty,
    estimated_total)
  VALUES(v_order,v_company,'PO-BPR-'||left(replace(v_order::text,'-',''),12),v_store,
    v_warehouse,v_supplier,current_date,v_actor,'DRAFT',NULL,NULL,NULL,1,10,50);
  INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,
    client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
    ordered_base_qty,estimated_unit_price,estimated_subtotal,product_sku_snapshot,
    product_name_snapshot,ordered_uom_name_snapshot)
  VALUES(v_order_line,v_company,v_order,1,gen_random_uuid(),v_product,v_pack_uom,1,
    10,10,50,50,'BPR-SKU','Backoffice Return rollback product','Return Pack');
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=2,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_order;

  v_result:=public.save_goods_receipt(NULL,NULL,v_session,v_order,'BPR-DELIVERY',
    'Backoffice Return rollback source',jsonb_build_array(jsonb_build_object(
      'clientLineKey',gen_random_uuid(),'supplierOrderLineId',v_order_line,
      'receivedUomId',v_pack_uom,'receivedQty',1,'acceptedGoodQty',1,
      'damagedQty',0,'rejectedQty',0)));
  v_receipt:=(v_result->>'documentId')::uuid;
  v_result:=public.post_goods_receipt(v_receipt,1,gen_random_uuid());
  SELECT * INTO STRICT v_event FROM public.financial_events event
  WHERE event.company_id=v_company AND event.id=(v_result->>'financialEventId')::uuid;
  v_result:=public.post_financial_event_by_id(v_event.id,v_event.event_version);
  IF v_result->>'status'<>'POSTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Goods Receipt Finance was not posted'; END IF;
  SELECT allocation.id INTO STRICT v_source
  FROM public.goods_receipt_condition_allocations allocation
  JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
    AND line.id=allocation.receipt_line_id
  WHERE line.company_id=v_company AND line.document_id=v_receipt
    AND allocation.condition_type='GOOD';
  SELECT provisional.id INTO STRICT v_provisional
  FROM public.goods_receipt_ap_provisionals provisional
  WHERE provisional.company_id=v_company AND provisional.receipt_id=v_receipt;

  -- Bill only 4 of 10 received units; the first 6 returned units must consume
  -- the uninvoiced portion before touching AP Final.
  v_result:=public.save_supplier_invoice_draft(NULL,NULL,v_supplier,
    'BPR-BILL-'||left(replace(gen_random_uuid()::text,'-',''),12),current_date,
    current_date+30,'EXCLUSIVE','Rollback-only partial Bill',NULL,
    jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'productId',v_product,'invoiceUomId',v_base_uom,'invoiceQty',4,'unitPrice',5,
      'allocations',jsonb_build_array(jsonb_build_object(
        'clientAllocationKey',gen_random_uuid(),'sourceApProvisionalId',v_provisional,
        'quantityBase',4)))));
  v_invoice:=(v_result->>'documentId')::uuid;
  v_result:=public.validate_supplier_invoice(v_invoice,
    (v_result->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO STRICT v_bank FROM public.chart_of_accounts account
  WHERE account.company_id=v_company AND account.system_function_key='BANK'
    AND account.is_active AND account.is_postable ORDER BY account.id LIMIT 1;
  v_result:=public.save_supplier_payment_draft(NULL,NULL,v_supplier,current_date,
    'BANK_TRANSFER',v_bank,'Rollback Bank','000000','Rollback Supplier',NULL,
    'Rollback partial payment','https://example.invalid/proof',
    jsonb_build_array(jsonb_build_object('clientAllocationKey',gen_random_uuid(),
      'invoiceId',v_invoice,'allocatedAmount',10)));
  v_payment:=(v_result->>'documentId')::uuid;
  v_result:=public.validate_supplier_payment(v_payment,
    (v_result->>'masterVersion')::bigint,gen_random_uuid());

  -- Exercise the unchanged POS/Cashier Draft path before the Backoffice flow.
  v_result:=public.save_purchase_return_draft(NULL,NULL,v_session,v_receipt,
    v_warehouse,current_date,'POS compatibility check',NULL,NULL,
    jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'sourceConditionAllocationId',v_source,'returnUomId',v_base_uom,'returnQty',1)));
  v_pos_return:=(v_result->>'documentId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.purchase_return_documents document
    WHERE document.company_id=v_company AND document.id=v_pos_return
      AND document.source_channel='POS' AND document.created_session_id=v_session
      AND document.created_pos_id=v_terminal) THEN
    RAISE EXCEPTION 'TEST_FAILED: POS Purchase Return ownership changed'; END IF;
  PERFORM public.cancel_purchase_return_draft(v_pos_return,
    (v_result->>'masterVersion')::bigint,'Rollback POS compatibility Draft');

  v_rejected:=false;
  BEGIN
    PERFORM public.save_backoffice_purchase_return_draft(NULL,NULL,gen_random_uuid(),
      gen_random_uuid(),v_warehouse,current_date,'Foreign source boundary',NULL,NULL,
      jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
        'sourceConditionAllocationId',v_source,'returnUomId',v_base_uom,'returnQty',1)));
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message LIKE '%POSTED_GOODS_RECEIPT_NOT_FOUND%' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: foreign/nonexistent Receipt source accepted'; END IF;

  v_result:=public.save_backoffice_purchase_return_draft(NULL,NULL,gen_random_uuid(),
    v_receipt,v_warehouse,current_date,'Return uninvoiced first',NULL,NULL,
    jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'sourceConditionAllocationId',v_source,'returnUomId',v_base_uom,'returnQty',6)));
  v_return_one:=(v_result->>'documentId')::uuid;v_version:=(v_result->>'masterVersion')::bigint;
  v_rejected:=false;
  BEGIN
    PERFORM public.review_purchase_return(v_return_one,v_version+1,'APPROVE',NULL);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message LIKE '%MASTER_VERSION_CONFLICT%' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: stale Return review version accepted'; END IF;
  v_result:=public.review_purchase_return(v_return_one,v_version,'APPROVE',NULL);
  v_result:=public.post_backoffice_purchase_return(v_return_one,
    (v_result->>'masterVersion')::bigint,'00000000-0000-0000-0000-000000191411');
  IF v_result->>'status'<>'POSTED' OR (v_result->>'apProvisionalReduction')::numeric<>30
    OR (v_result->>'apFinalReduction')::numeric<>0
    OR (v_result->>'supplierRefundReceivable')::numeric<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: UNINVOICED_FIRST result invalid: %',v_result; END IF;
  SELECT count(*) INTO v_count FROM public.purchase_return_finance_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.document_id=v_return_one
    AND allocation.allocation_kind='UNINVOICED' AND allocation.quantity_base=6;
  IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: exact uninvoiced allocation missing'; END IF;
  v_result:=public.post_backoffice_purchase_return(v_return_one,1,
    '00000000-0000-0000-0000-000000191411');
  IF COALESCE((v_result->>'idempotentReplay')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: Return post retry not idempotent'; END IF;

  -- Save a still-valid Payment Draft before the second Return. Validation
  -- after the Supplier Credit must recheck and reject this stale Draft.
  v_result:=public.save_supplier_payment_draft(NULL,NULL,v_supplier,current_date,
    'BANK_TRANSFER',v_bank,'Rollback Bank','000000','Rollback Supplier',NULL,
    'Stale after Supplier Credit','https://example.invalid/proof',
    jsonb_build_array(jsonb_build_object('clientAllocationKey',gen_random_uuid(),
      'invoiceId',v_invoice,'allocatedAmount',10)));
  v_stale_payment:=(v_result->>'documentId')::uuid;
  v_stale_payment_version:=(v_result->>'masterVersion')::bigint;

  -- Remaining 4 units are invoiced. With 10 already paid, split must be
  -- AP Final 10 and Supplier Refund Receivable 10.
  v_result:=public.save_backoffice_purchase_return_draft(NULL,NULL,gen_random_uuid(),
    v_receipt,v_warehouse,current_date,'Return invoiced balance',NULL,NULL,
    jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'sourceConditionAllocationId',v_source,'returnUomId',v_base_uom,'returnQty',4)));
  v_return_two:=(v_result->>'documentId')::uuid;
  v_result:=public.review_purchase_return(v_return_two,
    (v_result->>'masterVersion')::bigint,'APPROVE',NULL);
  v_result:=public.post_backoffice_purchase_return(v_return_two,
    (v_result->>'masterVersion')::bigint,'00000000-0000-0000-0000-000000191412');
  IF (v_result->>'apFinalReduction')::numeric<>10
    OR (v_result->>'supplierRefundReceivable')::numeric<>10 THEN
    RAISE EXCEPTION 'TEST_FAILED: paid Bill split invalid: %',v_result; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.supplier_return_credit_notes note
    WHERE note.company_id=v_company AND note.purchase_return_id=v_return_two
      AND note.ap_final_reduction=10 AND note.supplier_refund_receivable=10
      AND note.status='POSTED') THEN
    RAISE EXCEPTION 'TEST_FAILED: Supplier Credit Note missing'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
    JOIN public.purchase_return_documents document
      ON document.company_id=journal.company_id
     AND document.financial_event_id=journal.financial_event_id
    WHERE document.company_id=v_company AND document.id=v_return_two
      AND journal.status='POSTED' AND journal.total_debit=journal.total_credit) THEN
    RAISE EXCEPTION 'TEST_FAILED: balanced Return Journal missing'; END IF;
  SELECT stock_qty INTO v_value FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_product
    AND stock.warehouse_id=v_warehouse;
  IF v_value<>0 THEN RAISE EXCEPTION 'TEST_FAILED: Stock expected zero, got %',v_value; END IF;

  v_rejected:=false;
  BEGIN
    PERFORM public.save_backoffice_purchase_return_draft(NULL,NULL,gen_random_uuid(),
      v_receipt,v_warehouse,current_date,'Must exceed remaining source',NULL,NULL,
      jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
        'sourceConditionAllocationId',v_source,'returnUomId',v_base_uom,'returnQty',1)));
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message LIKE '%PURCHASE_RETURN_QUANTITY_EXCEEDS_AVAILABLE%' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Return beyond source/FIFO availability accepted'; END IF;

  v_rejected:=false;
  BEGIN
    PERFORM public.validate_supplier_payment(v_stale_payment,
      v_stale_payment_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message LIKE '%SUPPLIER_PAYMENT_EXCEEDS_NET_INVOICE_BALANCE%' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: stale Payment Draft validated after Supplier Credit'; END IF;

  -- Payment runtime must use Bill minus Supplier Credit minus prior payment.
  v_rejected:=false;
  BEGIN
    PERFORM public.save_supplier_payment_draft(NULL,NULL,v_supplier,current_date,
      'BANK_TRANSFER',v_bank,'Rollback Bank','000000','Rollback Supplier',NULL,
      'Must be blocked','https://example.invalid/proof',
      jsonb_build_array(jsonb_build_object('clientAllocationKey',gen_random_uuid(),
        'invoiceId',v_invoice,'allocatedAmount',1)));
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message LIKE '%SUPPLIER_PAYMENT_EXCEEDS_NET_INVOICE_BALANCE%' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: overpayment after Supplier Credit accepted'; END IF;

  SELECT master_version INTO v_version FROM public.supplier_order_documents
  WHERE company_id=v_company AND id=v_order;
  v_result:=public.cancel_purchase_supplier_order(v_order,v_version,gen_random_uuid(),
    'All received goods returned in rollback test');
  IF v_result->>'status'<>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: zero-net-receipt PO was not canceled'; END IF;

  -- Existing POS function remains callable and was not renamed/replaced.
  IF to_regprocedure('public.save_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)') IS NULL
    OR NOT has_function_privilege('authenticated',
      'public.save_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: POS Purchase Return compatibility missing'; END IF;
END
$test$;

ROLLBACK;
SELECT 'backoffice_purchase_return_e2e_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'self-created PO and Posted Goods Receipt','active non-purchase UOM Return',
    'tenant-scoped Receipt source rejection',
    'partial Bill UNINVOICED_FIRST allocation','partial Supplier payment',
    'AP Final and Supplier Refund Receivable split','exact FIFO and Stock zero',
    'source and FIFO over-return rejection',
    'balanced posted Return Journal','Supplier Credit Note source lineage',
    'stale Return review version rejection',
    'Supplier Payment stale-Draft validation rejection',
    'Supplier Payment net-Bill overpayment rejection','post exact retry',
    'zero-net-receipt PO cancellation','POS Purchase Return RPC compatibility',
    'all fixture writes rolled back')) details;
