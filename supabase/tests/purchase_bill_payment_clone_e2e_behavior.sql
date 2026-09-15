-- Clone-only fixture from canonical AUTO_PO and original generated Receipt behavior.
-- All master/account/stock preparation is rollback-only. No production execution.
BEGIN;
INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153146','purchase-warehouse-boundary@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase Warehouse Boundary Test"}'::jsonb,false,'authenticated','authenticated',
  clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153146',
  'purchase-warehouse-boundary@example.invalid','Purchase Warehouse Boundary Test',
  'super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;


DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153146';v_company uuid;
  v_timezone text;v_category uuid:=gen_random_uuid();v_uom uuid:=gen_random_uuid();
  v_active_product uuid:=gen_random_uuid();v_inactive_product uuid:=gen_random_uuid();
  v_source uuid:=gen_random_uuid();v_receiver uuid:=gen_random_uuid();
  v_supplier uuid:=gen_random_uuid();v_relation uuid:=gen_random_uuid();
  v_date date:='2099-12-29';v_effective timestamptz;v_setting_version bigint;v_batch uuid;
  v_posted_event uuid;
  v_invoice uuid;v_provisional uuid;v_bill jsonb;v_payment jsonb;v_payment_id uuid;
  v_amount numeric;v_bank uuid;v_event public.financial_events%rowtype;v_finance jsonb;
  v_payment_key uuid;v_bill_key uuid:=gen_random_uuid();v_posted_stock bigint;
  v_order_id uuid;
  v_order public.supplier_order_documents%rowtype;
  v_line public.supplier_order_lines%rowtype;
  v_receipt public.goods_receipt_documents%rowtype;
  v_revision_lines jsonb;v_result jsonb;v_operation uuid:=gen_random_uuid();
  v_post_key uuid:=gen_random_uuid();v_stock_before bigint;v_events_before bigint;
  v_bills_before bigint;v_saved_version bigint;v_billable numeric;v_message text;

BEGIN
  SELECT company.id,company.timezone INTO v_company,v_timezone
  FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting
    ON setting.company_id=company.id
  WHERE company.status='ACTIVE' AND EXISTS(SELECT 1 FROM public.accounting_periods period
    WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
      AND (clock_timestamp() AT TIME ZONE company.timezone)::date BETWEEN period.start_date AND period.end_date)
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with Purchase setting required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);

  INSERT INTO public.product_categories(id,company_id,category_code,category_name,
    created_by,updated_by)
  VALUES(v_category,v_company,'PWB-'||left(replace(v_category::text,'-',''),12),
    'Purchase Warehouse Boundary rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,
    decimal_precision,created_by,updated_by)
  VALUES(v_uom,v_company,'PWB'||left(replace(v_uom::text,'-',''),10),
    'Purchase Boundary Test Unit','UNIT',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,
    uom,uom_id,weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,
    created_by,updated_by)
  VALUES(v_active_product,v_company,'PWA-'||left(replace(v_active_product::text,'-',''),12),
      'Active Product Without Receipt Warehouse','Purchase Warehouse Boundary rollback category',
      v_category,10,5,'Purchase Boundary Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor),
    (v_inactive_product,v_company,'PWI-'||left(replace(v_inactive_product::text,'-',''),12),
      'Inactive Archived Product','Purchase Warehouse Boundary rollback category',
      v_category,10,5,'Purchase Boundary Test Unit',v_uom,v_uom,1,false,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,
    purchase_allowed,sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES(v_company,v_active_product,v_uom,1,true,true,5,10,true,v_actor,v_actor),
    (v_company,v_inactive_product,v_uom,1,true,true,5,10,true,v_actor,v_actor);
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,is_sale_source,
    is_purchase_destination,is_active,created_by,updated_by)
  VALUES(v_source,v_company,'PWS'||left(replace(v_source::text,'-',''),10),
      'Active Non Receiving Source','CENTRAL',false,false,true,v_actor,v_actor),
    (v_receiver,v_company,'PWR'||left(replace(v_receiver::text,'-',''),10),
      'Explicit Receiving Warehouse','CENTRAL',false,true,true,v_actor,v_actor);

  UPDATE public.product_stocks SET stock_qty=0,updated_at=clock_timestamp()
  WHERE company_id=v_company AND stock_qty<0;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id,updated_at)
  VALUES(v_active_product,v_source,-4,v_company,clock_timestamp()),
    (v_inactive_product,v_source,-6,v_company,clock_timestamp());
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_default_warehouse(NULL,v_setting_version);
  SELECT master_version INTO v_setting_version
  FROM public.company_purchase_replenishment_settings WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_mode('AUTO_PO',v_setting_version);


  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,is_active,created_by,updated_by)
  VALUES(v_supplier,v_company,'GRC-'||left(replace(v_supplier::text,'-',''),12),
    'Generated Receipt clone supplier',true,v_actor,v_actor);
  INSERT INTO public.product_suppliers(id,company_id,product_id,supplier_id,
    purchase_uom_id,reference_purchase_price,is_preferred_supplier,is_active,
    selection_priority,created_by,updated_by)
  VALUES(v_relation,v_company,v_active_product,v_supplier,v_uom,5,false,true,1,v_actor,v_actor);
  SELECT master_version INTO v_setting_version FROM public.company_purchase_replenishment_settings
  WHERE company_id=v_company;
  PERFORM public.set_purchase_replenishment_default_warehouse(v_receiver,v_setting_version);
  v_effective:=((v_date+time '23:59:30') AT TIME ZONE v_timezone);
  v_result:=private.generate_purchase_daily_auto_po_core(v_company,v_date,v_actor,
    gen_random_uuid(),v_effective);
  v_batch:=(v_result->>'batchId')::uuid;
  SELECT document.* INTO STRICT v_order FROM public.supplier_order_documents document
  WHERE document.company_id=v_company AND document.purchase_daily_batch_id=v_batch
    AND document.supplier_id=v_supplier AND document.status='CONFIRMED';
  v_order_id:=v_order.id;
  SELECT line.* INTO STRICT v_line FROM public.supplier_order_lines line
  WHERE line.company_id=v_company AND line.document_id=v_order.id
    AND line.ordered_base_qty>1 AND line.estimated_unit_price>0
  ORDER BY line.line_no LIMIT 1;
  SELECT receipt.* INTO STRICT v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.supplier_order_id=v_order.id
    AND receipt.warehouse_id=v_line.destination_warehouse_id
    AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
    AND receipt.line_count=0;
  SELECT jsonb_agg(jsonb_build_object('lineId',line.id,'productId',line.product_id,
      'uomId',line.ordered_uom_id,'destinationWarehouseId',line.destination_warehouse_id,
      'quantity',line.ordered_qty,'estimatedUnitPrice',line.estimated_unit_price)
      ORDER BY line.line_no) INTO STRICT v_revision_lines
  FROM public.supplier_order_lines line
  WHERE line.company_id=v_company AND line.document_id=v_order.id;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  SELECT count(*) INTO v_stock_before FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_events_before FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_bills_before FROM public.supplier_invoice_documents WHERE company_id=v_company;

  -- An untouched system-generated Receipt is not a started warehouse receipt and must not block PO edit.
  v_result:=public.revise_purchase_supplier_order(v_order.id,v_order.master_version,
    v_operation,v_order.supplier_id,v_order.expected_date,'Rollback-only generated Receipt behavior',
    v_revision_lines);
  IF v_result->>'status'<>'CONFIRMED' OR COALESCE((v_result->>'exactRetry')::boolean,false) THEN
    RAISE EXCEPTION 'TEST_FAILED: PO edit with untouched generated Receipt invalid';
  END IF;
  SELECT receipt.* INTO STRICT v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.supplier_order_id=v_order.id
    AND receipt.warehouse_id=v_line.destination_warehouse_id
    AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT';

  -- Filling Draft has no Stock, Finance, or Bill effect.
  v_result:=public.save_generated_backoffice_goods_receipt(v_receipt.id,
    v_receipt.master_version,v_order.id,NULL,'Rollback-only partial Receipt',
    jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'supplierOrderLineId',v_line.id,'receivedUomId',v_line.ordered_uom_id,
      'receivedQty',1,'acceptedGoodQty',1,'damagedQty',0,'rejectedQty',0)));
  v_saved_version:=(v_result->>'masterVersion')::bigint;
  IF v_result->>'status'<>'DRAFT'
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock_before
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_events_before
    OR (SELECT count(*) FROM public.supplier_invoice_documents WHERE company_id=v_company)<>v_bills_before
    OR private.classify_purchase_order_bill_status(0,0,0,0,true)<>'NOT_READY' THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft Receipt created downstream effect';
  END IF;

  v_result:=public.post_generated_backoffice_goods_receipt(v_receipt.id,v_saved_version,v_post_key);
  IF v_result->>'status'<>'POSTED'
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<=v_stock_before
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<=v_events_before
    OR (SELECT count(*) FROM public.supplier_invoice_documents WHERE company_id=v_company)<>v_bills_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Receipt Post Stock/Finance/Bill boundary invalid';
  END IF;
  v_result:=public.post_generated_backoffice_goods_receipt(v_receipt.id,v_saved_version,v_post_key);
  IF COALESCE((v_result->>'idempotentReplay')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: Receipt Post exact retry invalid';
  END IF;
  SELECT sum(receipt_line.accepted_good_base_qty+receipt_line.damaged_base_qty)
    INTO v_billable
  FROM public.goods_receipt_lines receipt_line
  JOIN public.goods_receipt_documents receipt ON receipt.company_id=receipt_line.company_id
    AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
  JOIN public.supplier_order_lines line ON line.company_id=receipt_line.company_id
    AND line.id=receipt_line.supplier_order_line_id
  WHERE line.company_id=v_company AND line.document_id=v_order.id;
  IF private.classify_purchase_order_bill_status(v_billable,0,0,0,true)<>'READY'
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=v_company AND receipt.supplier_order_id=v_order.id
        AND receipt.warehouse_id=v_line.destination_warehouse_id
        AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
        AND receipt.line_count=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: partial Receipt did not make PO Bill-ready or generate remaining Receipt';
  END IF;

  -- Receipt Post moves the PO to PARTIALLY_RECEIVED. The canonical revision
  -- routine rejects that status before evaluating its Receipt-presence guard.
  SELECT * INTO STRICT v_order FROM public.supplier_order_documents
  WHERE company_id=v_company AND id=v_order_id;
  IF v_order.status<>'PARTIALLY_RECEIVED' THEN
    RAISE EXCEPTION 'TEST_FAILED: partial Receipt did not set PO PARTIALLY_RECEIVED';
  END IF;
  BEGIN
    PERFORM public.revise_purchase_supplier_order(v_order.id,v_order.master_version,
      gen_random_uuid(),v_order.supplier_id,v_order.expected_date,NULL,v_revision_lines);
    RAISE EXCEPTION 'TEST_FAILED: PO edit accepted after Receipt Post';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message NOT LIKE '%PURCHASE_PO_PRE_RECEIPT_REVISION_NOT_ALLOWED%' THEN RAISE; END IF;
  END;

  -- Continue the real posted partial Receipt to existing Supplier Bill and Payment.
  SELECT financial_event_id INTO STRICT v_posted_event FROM public.goods_receipt_documents
  WHERE company_id=v_company AND id=v_receipt.id;
  SELECT * INTO STRICT v_event FROM public.financial_events WHERE company_id=v_company AND id=v_posted_event;
  v_finance:=public.post_financial_event_by_id(v_event.id,v_event.event_version);
  IF v_finance->>'status'<>'POSTED' THEN RAISE EXCEPTION 'TEST_FAILED: Receipt finance: %',v_finance; END IF;
  SELECT id INTO STRICT v_provisional FROM public.goods_receipt_ap_provisionals
  WHERE company_id=v_company AND receipt_id=v_receipt.id AND status='OPEN';
  SELECT count(*) INTO v_posted_stock FROM public.stock_movements WHERE company_id=v_company;
  v_bill:=public.save_supplier_invoice_draft(NULL,NULL,v_supplier,
    'CLONE-BILL-'||left(replace(gen_random_uuid()::text,'-',''),12),
    current_date,current_date+30,'EXCLUSIVE','Rollback-only existing Supplier Bill',NULL,
    jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'productId',v_active_product,'invoiceUomId',v_uom,'invoiceQty',1,'unitPrice',5,
      'allocations',jsonb_build_array(jsonb_build_object('clientAllocationKey',gen_random_uuid(),
        'sourceApProvisionalId',v_provisional,'quantityBase',1)))));
  v_invoice:=(v_bill->>'documentId')::uuid;
  IF v_bill->>'status'<>'DRAFT' OR v_bill->>'matchingStatus'<>'MATCHED' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Bill Draft invalid: %',v_bill; END IF;
  v_finance:=public.get_purchase_supplier_orders();
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_finance->'supplierOrderBillSummaries') item
    WHERE item->>'supplierOrderId'=v_order.id::text AND item->>'billStatus'='DRAFT'
      AND EXISTS(SELECT 1 FROM jsonb_array_elements(item->'bills') bill WHERE bill->>'id'=v_invoice::text)) THEN
    RAISE EXCEPTION 'TEST_FAILED: real Bill Draft status/link missing'; END IF;
  v_bill:=public.validate_supplier_invoice(v_invoice,(v_bill->>'masterVersion')::bigint,v_bill_key);
  IF v_bill->>'status'<>'VALIDATED' THEN RAISE EXCEPTION 'TEST_FAILED: Bill validation: %',v_bill; END IF;
  SELECT * INTO STRICT v_event FROM public.financial_events
  WHERE company_id=v_company AND id=(v_bill->>'financialEventId')::uuid;
  v_finance:=public.post_financial_event_by_id(v_event.id,v_event.event_version);
  IF v_finance->>'status'<>'POSTED' THEN RAISE EXCEPTION 'TEST_FAILED: Bill journal: %',v_finance; END IF;
  v_finance:=public.get_purchase_supplier_orders();
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_finance->'supplierOrderBillSummaries') item
    WHERE item->>'supplierOrderId'=v_order.id::text AND item->>'billStatus'='BILLED') THEN
    RAISE EXCEPTION 'TEST_FAILED: real Billed status missing'; END IF;
  SELECT id INTO STRICT v_bank FROM public.chart_of_accounts
  WHERE company_id=v_company AND system_function_key='BANK'
    AND is_system_account AND is_active AND is_postable;
  FOREACH v_amount IN ARRAY ARRAY[2::numeric,3::numeric] LOOP
    v_payment_key:=gen_random_uuid();
    v_payment:=public.save_supplier_payment_draft(NULL,NULL,v_supplier,current_date,
      'BANK_TRANSFER',v_bank,'Rollback Bank','000000','Rollback Supplier',NULL,
      'Rollback-only partial Supplier payment','https://example.invalid/rollback-proof',
      jsonb_build_array(jsonb_build_object('clientAllocationKey',gen_random_uuid(),
        'invoiceId',v_invoice,'allocatedAmount',v_amount)));
    v_payment_id:=(v_payment->>'documentId')::uuid;
    v_payment:=public.validate_supplier_payment(v_payment_id,
      (v_payment->>'masterVersion')::bigint,v_payment_key);
    IF v_payment->>'status'<>'VALIDATED' THEN RAISE EXCEPTION 'TEST_FAILED: Payment validation: %',v_payment; END IF;
    SELECT * INTO STRICT v_event FROM public.financial_events
    WHERE company_id=v_company AND id=(v_payment->>'financialEventId')::uuid;
    v_finance:=public.post_financial_event_by_id(v_event.id,v_event.event_version);
    IF v_finance->>'status'<>'POSTED' OR NOT EXISTS(SELECT 1 FROM public.finance_journals
      WHERE company_id=v_company AND financial_event_id=v_event.id AND status='POSTED'
        AND total_debit=v_amount AND total_credit=v_amount) THEN
      RAISE EXCEPTION 'TEST_FAILED: Payment journal: %',v_finance; END IF;
    v_finance:=public.post_financial_event_by_id(v_event.id,v_event.event_version);
    IF COALESCE((v_finance->>'idempotentReplay')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION 'TEST_FAILED: Payment journal retry'; END IF;
  END LOOP;
  IF (SELECT sum(allocation.allocated_amount) FROM public.supplier_payment_allocations allocation
    JOIN public.supplier_payment_documents payment ON payment.company_id=allocation.company_id
      AND payment.id=allocation.document_id AND payment.status='VALIDATED'
    WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice)<>5
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_posted_stock THEN
    RAISE EXCEPTION 'TEST_FAILED: full Supplier settlement or stock-neutrality invalid'; END IF;

END
$test$;
ROLLBACK;
SELECT 'purchase_bill_payment_clone_e2e' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'PO has generated per-Warehouse Receipt','untouched Receipt does not block PO edit',
    'Draft Receipt has zero downstream effect','Receipt Post creates Stock/Finance effect',
    'Post exact retry','partial Receipt creates remaining Receipt','Bill-ready after Posted Receipt',
    'started Receipt blocks PO edit','no Supplier Bill auto-created','real Bill Draft link','Bill validate/post',
    'partial then full Supplier settlement','balanced supplier payment journals','journal retry','stock-neutral Bill/Payment','rollback')) details;
