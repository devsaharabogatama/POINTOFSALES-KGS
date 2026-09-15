-- Purchase Daily Replenishment Step 6/6A rollback-only behavior.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000153146','purchase-ap-bridge-test@example.invalid',
  '00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Purchase AP Bridge Test"}'::jsonb,false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;
INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000153146','purchase-ap-bridge-test@example.invalid',
  'Purchase AP Bridge Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE v_actor uuid:='00000000-0000-0000-0000-000000153146';v_company uuid;
  v_category uuid:=gen_random_uuid();v_uom uuid:=gen_random_uuid();
  v_product uuid:=gen_random_uuid();v_zero_product uuid:=gen_random_uuid();
  v_warehouse uuid:=gen_random_uuid();v_supplier uuid:=gen_random_uuid();
  v_batch uuid:=gen_random_uuid();v_order uuid:=gen_random_uuid();
  v_order_line uuid:=gen_random_uuid();v_zero_order_line uuid:=gen_random_uuid();
  v_receipt uuid;v_zero_receipt uuid;v_receipt_line uuid;v_zero_receipt_line uuid;
  v_version bigint;v_result jsonb;v_retry jsonb;v_operation uuid:=gen_random_uuid();
  v_zero_operation uuid:=gen_random_uuid();v_event uuid;v_zero_event uuid;v_provisional uuid;
  v_receipt_event uuid;v_zero_receipt_event uuid;
  v_stock numeric;v_finance jsonb;
BEGIN
  SELECT company.id INTO v_company FROM public.companies company
  JOIN public.company_purchase_replenishment_settings setting ON setting.company_id=company.id
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
        AND (clock_timestamp() AT TIME ZONE company.timezone)::date
          BETWEEN period.start_date AND period.end_date)
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Step-1 Company with current open period required';
  END IF;
  INSERT INTO public.user_active_company_contexts(user_id,company_id,selection_source)
  VALUES(v_actor,v_company,'BACKOFFICE_TEST')
  ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selection_source=excluded.selection_source,updated_at=clock_timestamp();
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  IF NOT EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=v_company AND category.system_key='GOODS_RECEIPT'
        AND category.is_active) THEN
    INSERT INTO public.transaction_categories(id,company_id,category_code,category_name,
      system_key,description,is_active,created_by,updated_by)
    VALUES(v_category,v_company,'S6A-GR-'||upper(left(replace(v_category::text,'-',''),8)),
      'Step 6A Goods Receipt','GOODS_RECEIPT','Rollback-only Step 6A',true,v_actor,v_actor);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.system_function_key='INVENTORY_ASSET'
        AND account.is_active AND account.is_postable) THEN
    INSERT INTO public.chart_of_accounts(company_id,account_code,account_name,account_type,
      normal_balance,system_function_key,is_system_account,is_postable,
      allow_manual_posting,allow_reconciliation,created_by,updated_by)
    VALUES(v_company,'S6AINV-'||upper(left(replace(v_category::text,'-',''),6)),
      'Step 6A Inventory','ASSET','DEBIT','INVENTORY_ASSET',true,true,false,false,v_actor,v_actor);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.system_function_key='SUPPLIER_AP_PROVISIONAL'
        AND account.is_active AND account.is_postable) THEN
    INSERT INTO public.chart_of_accounts(company_id,account_code,account_name,account_type,
      normal_balance,system_function_key,is_system_account,is_postable,
      allow_manual_posting,allow_reconciliation,created_by,updated_by)
    VALUES(v_company,'S6AAP-'||upper(left(replace(v_category::text,'-',''),6)),
      'Step 6A AP Provisional','LIABILITY','CREDIT','SUPPLIER_AP_PROVISIONAL',
      true,true,false,true,v_actor,v_actor);
  END IF;
  INSERT INTO public.product_categories(id,company_id,category_code,category_name,created_by,updated_by)
  VALUES(v_category,v_company,'S6A-'||left(replace(v_category::text,'-',''),12),
    'Step 6A rollback category',v_actor,v_actor);
  INSERT INTO public.uoms(id,company_id,code,name,uom_type,allow_decimal,decimal_precision,
    created_by,updated_by)
  VALUES(v_uom,v_company,'S6A'||left(replace(v_uom::text,'-',''),9),
    'Step 6A Test Unit','UNIT',false,0,v_actor,v_actor);
  INSERT INTO public.products(id,company_id,sku,name,category,category_id,price,cogs,uom,uom_id,
    weight_reference_uom_id,weight_per_uom_kg,is_active,is_bundle,created_by,updated_by)
  VALUES(v_product,v_company,'S6A-'||left(replace(v_product::text,'-',''),12),
      'Step 6A Positive Product','Step 6A rollback category',v_category,20,12,
      'Step 6A Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor),
    (v_zero_product,v_company,'S6Z-'||left(replace(v_zero_product::text,'-',''),12),
      'Step 6A Zero Product','Step 6A rollback category',v_category,0,0,
      'Step 6A Test Unit',v_uom,v_uom,1,true,false,v_actor,v_actor);
  INSERT INTO public.product_uoms(company_id,product_id,uom_id,factor_to_base,purchase_allowed,
    sales_allowed,purchase_price,sale_price,is_active,created_by,updated_by)
  VALUES(v_company,v_product,v_uom,1,true,true,0,20,true,v_actor,v_actor),
    (v_company,v_zero_product,v_uom,1,true,true,0,0,true,v_actor,v_actor);
  INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,is_sale_source,
    is_purchase_destination,is_active,created_by,updated_by)
  VALUES(v_warehouse,v_company,'S6A'||left(replace(v_warehouse::text,'-',''),9),
    'Step 6A Receipt Warehouse','CENTRAL',false,true,true,v_actor,v_actor);
  INSERT INTO public.suppliers(id,company_id,supplier_code,supplier_name,is_active,created_by,updated_by)
  VALUES(v_supplier,v_company,'S6A-'||left(replace(v_supplier::text,'-',''),12),
    'Step 6A Assigned Supplier',true,v_actor,v_actor);
  INSERT INTO public.purchase_daily_batches(id,company_id,batch_no,business_date,mode_snapshot,
    status,cutoff_at,line_count,requested_total_base_qty,generated_by)
  VALUES(v_batch,v_company,'S6A-'||upper(left(replace(v_batch::text,'-',''),12)),
    '2099-12-31','AUTO_PO','DRAFT','2099-12-31 23:59:00+07',2,3,v_actor);
  INSERT INTO public.supplier_order_documents(id,company_id,order_no,store_id,
    destination_warehouse_id,supplier_id,order_date,ordered_by,status,line_count,
    total_ordered_base_qty,estimated_total,order_source,document_scope,
    purchase_daily_batch_id,supplier_assignment_status)
  VALUES(v_order,v_company,'PO-S6A-'||upper(left(replace(v_order::text,'-',''),10)),
    NULL,NULL,NULL,'2099-12-31',v_actor,'DRAFT',2,3,0,'DAILY_REPLENISHMENT',
    'COMPANY_MULTI_WAREHOUSE',v_batch,'SUPPLIER_PENDING');
  INSERT INTO public.supplier_order_lines(id,company_id,document_id,line_no,client_line_key,
    product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,ordered_base_qty,
    estimated_unit_price,estimated_subtotal,product_sku_snapshot,product_name_snapshot,
    ordered_uom_name_snapshot,source_warehouse_id,destination_warehouse_id)
  VALUES(v_order_line,v_company,v_order,1,gen_random_uuid(),v_product,v_uom,2,1,2,0,0,
      'S6A','Step 6A Positive Product','Step 6A Test Unit',v_warehouse,v_warehouse),
    (v_zero_order_line,v_company,v_order,2,gen_random_uuid(),v_zero_product,v_uom,1,1,1,0,0,
      'S6Z','Step 6A Zero Product','Step 6A Test Unit',v_warehouse,v_warehouse);
  UPDATE public.supplier_order_documents SET status='CONFIRMED',confirmed_by=v_actor,
    confirmed_at=clock_timestamp(),confirmation_idempotency_key=gen_random_uuid(),
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_order;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,0,v_company),(v_zero_product,v_warehouse,0,v_company);

  v_result:=public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_warehouse,NULL,NULL,
    jsonb_build_array(jsonb_build_object('supplierOrderLineId',v_order_line,
      'receivedUomId',v_uom,'receivedQty',2,'acceptedGoodQty',2)));
  v_receipt:=(v_result->>'documentId')::uuid;
  SELECT master_version INTO v_version FROM public.goods_receipt_documents
    WHERE company_id=v_company AND id=v_receipt;
  PERFORM public.post_purchase_daily_goods_receipt(v_receipt,v_version,gen_random_uuid());
  SELECT financial_event_id INTO v_receipt_event FROM public.goods_receipt_documents
    WHERE company_id=v_company AND id=v_receipt;
  SELECT master_version INTO v_version FROM public.goods_receipt_documents
    WHERE company_id=v_company AND id=v_receipt;
  SELECT id INTO v_receipt_line FROM public.goods_receipt_lines
    WHERE company_id=v_company AND document_id=v_receipt;
  v_result:=public.assign_purchase_daily_receipt_suppliers(v_receipt,v_version,v_operation,
    jsonb_build_array(jsonb_build_object('receiptLineId',v_receipt_line,'supplierId',v_supplier)));
  SELECT id INTO v_provisional FROM public.goods_receipt_ap_provisionals
    WHERE company_id=v_company AND receipt_line_id=v_receipt_line;
  IF (v_result->>'apProvisionalCount')::integer<>1 OR v_provisional IS NULL
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_ap_provisionals provisional
      WHERE provisional.id=v_provisional AND provisional.receipt_id=v_receipt
        AND provisional.supplier_id=v_supplier AND provisional.amount=24
        AND provisional.status='OPEN') THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment AP provisional bridge invalid'; END IF;
  v_retry:=public.assign_purchase_daily_receipt_suppliers(v_receipt,v_version,v_operation,
    jsonb_build_array(jsonb_build_object('receiptLineId',v_receipt_line,'supplierId',v_supplier)));
  IF NOT (v_retry->>'exactRetry')::boolean
    OR (SELECT count(*) FROM public.goods_receipt_ap_provisionals provisional
      WHERE provisional.company_id=v_company AND provisional.receipt_line_id=v_receipt_line)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment retry duplicated AP provisional'; END IF;
  SELECT financial_event_id INTO v_event FROM public.goods_receipt_supplier_assignment_operations
    WHERE company_id=v_company AND id=v_operation;
  IF NOT EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=v_company AND event.id=v_receipt_event
        AND private.f4b_financial_event_supported(event)) THEN
    RAISE EXCEPTION 'TEST_FAILED: pending-Supplier Receipt absent from canonical queue support'; END IF;
  IF EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=v_company AND event.id=v_event
        AND private.f4b_financial_event_supported(event)) THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment entered queue before Receipt accounting'; END IF;
  BEGIN
    PERFORM private.post_financial_event_core(v_company,v_event,1,v_actor);
    RAISE EXCEPTION 'TEST_FAILED: direct assignment posting bypassed Receipt accounting';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'GOODS_RECEIPT_FINANCE_MUST_POST_FIRST' THEN RAISE; END IF;
  END;
  v_result:=private.post_financial_event_core(v_company,v_receipt_event,1,v_actor);
  IF v_result->>'status'<>'POSTED' OR (v_result->>'totalDebit')::numeric<>24
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      JOIN public.finance_journals journal ON journal.company_id=line.company_id
        AND journal.id=line.journal_id AND journal.financial_event_id=v_receipt_event
      JOIN public.chart_of_accounts account ON account.company_id=line.company_id
        AND account.id=line.account_id
      WHERE line.company_id=v_company AND account.system_function_key='INVENTORY_ASSET'
        AND line.debit=24 AND line.credit=0 AND line.supplier_id IS NULL)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      JOIN public.finance_journals journal ON journal.company_id=line.company_id
        AND journal.id=line.journal_id AND journal.financial_event_id=v_receipt_event
      JOIN public.chart_of_accounts account ON account.company_id=line.company_id
        AND account.id=line.account_id
      WHERE line.company_id=v_company
        AND account.system_function_key='PURCHASE_UNASSIGNED_CLEARING'
        AND line.debit=0 AND line.credit=24 AND line.supplier_id IS NULL) THEN
    RAISE EXCEPTION 'TEST_FAILED: pending-Supplier Receipt journal invalid'; END IF;
  v_retry:=private.post_financial_event_core(v_company,v_receipt_event,1,v_actor);
  IF NOT (v_retry->>'idempotentReplay')::boolean
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.financial_event_id=v_receipt_event)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Receipt finance retry duplicated journal'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=v_company AND event.id=v_event
        AND private.f4b_financial_event_supported(event)) THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment absent after Receipt accounting'; END IF;
  v_result:=private.post_financial_event_core(v_company,v_event,1,v_actor);
  IF v_result->>'status'<>'POSTED' OR (v_result->>'totalDebit')::numeric<>24
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      JOIN public.finance_journals journal ON journal.company_id=line.company_id
        AND journal.id=line.journal_id AND journal.financial_event_id=v_event
      JOIN public.chart_of_accounts account ON account.company_id=line.company_id
        AND account.id=line.account_id
      WHERE line.company_id=v_company AND account.system_function_key='PURCHASE_UNASSIGNED_CLEARING'
        AND line.debit=24 AND line.credit=0 AND line.supplier_id=v_supplier)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      JOIN public.finance_journals journal ON journal.company_id=line.company_id
        AND journal.id=line.journal_id AND journal.financial_event_id=v_event
      JOIN public.chart_of_accounts account ON account.company_id=line.company_id
        AND account.id=line.account_id
      WHERE line.company_id=v_company AND account.system_function_key='SUPPLIER_AP_PROVISIONAL'
        AND line.debit=0 AND line.credit=24 AND line.supplier_id=v_supplier) THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment clearing journal invalid'; END IF;
  v_retry:=private.post_financial_event_core(v_company,v_event,1,v_actor);
  IF NOT (v_retry->>'idempotentReplay')::boolean
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.financial_event_id=v_event)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment finance retry duplicated journal'; END IF;
  SELECT stock_qty INTO v_stock FROM public.product_stocks
    WHERE product_id=v_product AND warehouse_id=v_warehouse;
  IF v_stock<>2 OR (SELECT master_version FROM public.goods_receipt_documents
      WHERE company_id=v_company AND id=v_receipt)<>v_version THEN
    RAISE EXCEPTION 'TEST_FAILED: assignment bridge rewrote Stock or Receipt'; END IF;
  v_finance:=public.get_finance_supplier_invoices();
  IF NOT (v_finance->'openApProvisionals' @>
      jsonb_build_array(jsonb_build_object('id',v_provisional)))
    OR EXISTS(SELECT 1 FROM public.supplier_invoice_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.source_ap_provisional_id=v_provisional) THEN
    RAISE EXCEPTION 'TEST_FAILED: existing Supplier Invoice eligibility boundary invalid'; END IF;

  v_result:=public.save_purchase_daily_goods_receipt(NULL,NULL,v_order,v_warehouse,NULL,NULL,
    jsonb_build_array(jsonb_build_object('supplierOrderLineId',v_zero_order_line,
      'receivedUomId',v_uom,'receivedQty',1,'acceptedGoodQty',1,
      'confirmZeroCost',true)));
  v_zero_receipt:=(v_result->>'documentId')::uuid;
  SELECT master_version INTO v_version FROM public.goods_receipt_documents
    WHERE company_id=v_company AND id=v_zero_receipt;
  PERFORM public.post_purchase_daily_goods_receipt(v_zero_receipt,v_version,gen_random_uuid());
  SELECT financial_event_id INTO v_zero_receipt_event FROM public.goods_receipt_documents
    WHERE company_id=v_company AND id=v_zero_receipt;
  SELECT master_version INTO v_version FROM public.goods_receipt_documents
    WHERE company_id=v_company AND id=v_zero_receipt;
  SELECT id INTO v_zero_receipt_line FROM public.goods_receipt_lines
    WHERE company_id=v_company AND document_id=v_zero_receipt;
  v_result:=public.assign_purchase_daily_receipt_suppliers(v_zero_receipt,v_version,v_zero_operation,
    jsonb_build_array(jsonb_build_object('receiptLineId',v_zero_receipt_line,'supplierId',v_supplier)));
  v_zero_event:=(v_result->>'financialEventId')::uuid;
  v_result:=private.post_financial_event_core(v_company,v_zero_receipt_event,1,v_actor);
  IF v_result->>'status'<>'CANCELED' OR v_result->>'reason'<>'NO_FINANCIAL_EFFECT'
    OR EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.financial_event_id=v_zero_receipt_event) THEN
    RAISE EXCEPTION 'TEST_FAILED: zero pending-Supplier Receipt did not close without journal'; END IF;
  v_result:=private.post_financial_event_core(v_company,v_zero_event,1,v_actor);
  IF v_result->>'status'<>'CANCELED' OR v_result->>'reason'<>'NO_FINANCIAL_EFFECT'
    OR EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.financial_event_id=v_zero_event) THEN
    RAISE EXCEPTION 'TEST_FAILED: zero assignment event did not close without journal'; END IF;
  RAISE NOTICE 'TEST_PASS: pending-Supplier Receipt posts Inventory to Clearing first; Supplier assignment then creates exact AP provisional and posts Clearing to AP; existing Supplier Invoice remains the Bill surface; Stock/Receipt stay unchanged; retries are exact; zero-value stages close without Journal';
END
$test$;

ROLLBACK;
