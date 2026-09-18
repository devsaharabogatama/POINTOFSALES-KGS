-- Authenticated rollback-only behavior for Backoffice Sales Return Step 3/5.
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_customer_category uuid;v_fixture_code text;
  v_product_uom uuid;v_product uuid;v_method uuid;v_proof_mode text;
  v_today date;v_original_negative boolean;
  v_stock numeric;v_topup numeric;v_batch uuid:=gen_random_uuid();
  v_payload jsonb;v_result jsonb;v_order uuid;v_order_line uuid;
  v_delivery uuid;v_delivery_line uuid;v_version bigint;
  v_posted_invoice uuid;v_posted_line uuid;v_draft_invoice uuid;v_draft_line uuid;
  v_return uuid;v_return_line uuid;v_receipt uuid;v_receipt_line uuid;
  v_allocate_op uuid:=gen_random_uuid();v_allocate jsonb;v_retry jsonb;
  v_note uuid;v_post_op uuid:=gen_random_uuid();v_posted_note jsonb;
  v_payment_draft jsonb;v_payment_amount numeric(24,4);v_invoice_total numeric(24,4);
  v_statement jsonb;
  v_failed boolean;v_before_event bigint;v_before_journal bigint;
  v_phase text:='PRECONDITION';
BEGIN
  -- One anonymous statement only. The nested block is deliberately aborted at
  -- the end so every fixture write rolls back without relying on a separate
  -- BEGIN/ROLLBACK statement in the SQL editor.
  BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917131000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Step 3 runtime migration required';
  END IF;
  v_phase:='FIXTURE_SELECTION';
  SELECT profile.id INTO v_actor FROM auth.users auth_user
  JOIN public.profiles profile ON profile.id=auth_user.id
    AND profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,warehouse.allow_negative_stock,
    product_uom.id,product_uom.product_id,method.id,method.proof_mode,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_original_negative,
    v_product_uom,v_product,v_method,v_proof_mode,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed AND product_uom.factor_to_base=1
    AND product_uom.sale_price>0
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
    AND product.uom_id=product_uom.uom_id
  JOIN LATERAL(SELECT payment_method.id,payment_method.proof_mode
    FROM public.payment_methods payment_method
    WHERE payment_method.company_id=company.id AND payment_method.is_active
      AND payment_method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
    ORDER BY payment_method.is_default DESC,payment_method.id LIMIT 1) method ON true
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
        AND (clock_timestamp() AT TIME ZONE company.timezone)::date
          BETWEEN period.start_date AND period.end_date)
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='CUSTOMER_CREDIT_NOTE'
        AND category.is_active)
  ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin plus active Company, Store, sale Warehouse, priced Product-UOM, Payment Method, Credit Note category and current open period required';
  END IF;

  v_phase:='AUTH_AND_COMPANY_SETUP';
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET
    company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
    AND NOT customer.is_system_customer ORDER BY customer.id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT category.id INTO v_customer_category FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.is_system_category DESC,category.id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical active Customer Category required';
    END IF;
    v_fixture_code:='CNTEST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_result:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
      'Credit Note Rollback Customer',v_customer_category,NULL,NULL,NULL,
      'BUSINESS',0,NULL,'Rollback-only Credit Note fixture',TRUE,NULL,NULL);
    v_customer:=(v_result->>'customerId')::uuid;
    IF v_customer IS NULL THEN
      RAISE EXCEPTION 'TEST_FAILED: canonical rollback Customer fixture was not created';
    END IF;
  END IF;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;

  v_phase:='STOCK_FIFO_FIXTURE';
  -- Rollback-only stock/FIFO fixture.
  SELECT COALESCE(stock_qty,0) INTO v_stock FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_stock:=COALESCE(v_stock,0);v_topup:=CASE WHEN v_stock<12 THEN 12-v_stock ELSE 12 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=clock_timestamp()
  RETURNING stock_qty INTO v_stock;
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch,v_product,v_warehouse,v_topup,v_topup,
    greatest(COALESCE(product.cogs,1),1),v_company
  FROM public.products product WHERE product.company_id=v_company AND product.id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT gen_random_uuid(),v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_RETURN_CREDIT_TEST',v_batch,
    v_company,product.uom_id,uom.name,v_stock,v_actor,clock_timestamp(),
    'POSTED',v_batch,'Rollback-only Return Credit Note fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_product;

  v_phase:='SALES_ORDER_AND_DELIVERY';
  -- SO qty 6, fully accepted by Customer.
  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,'quantity',6)));
  v_result:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_order:=(v_result->'data'->>'id')::uuid;
  v_result:=public.confirm_backoffice_sales_order(v_order,
    (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_delivery:=(v_result->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id,sales_order_line_id INTO STRICT v_delivery_line,v_order_line
  FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery;
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  PERFORM public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,'quantityUom',6)),
    'Step 3 fixture Dispatch');
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  PERFORM public.receive_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    v_today,'Step 3 fixture Customer accepted');

  v_phase:='POSTED_INVOICE';
  -- Split the commercial state: 2 Posted, 2 Draft, 2 un-invoiced.
  v_result:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,
      'paymentTermId',NULL,'dueDate',v_today,'notes','Step 3 Posted source',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',2,'discountAmount',0,'taxApplied',false))));
  v_posted_invoice:=(v_result->'data'->>'id')::uuid;
  SELECT id INTO STRICT v_posted_line FROM public.backoffice_sales_invoice_lines
  WHERE company_id=v_company AND invoice_id=v_posted_invoice AND line_type='PRODUCT';
  PERFORM public.post_backoffice_sales_invoice(v_posted_invoice,
    (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT grand_total INTO STRICT v_invoice_total
  FROM public.backoffice_sales_invoices
  WHERE company_id=v_company AND id=v_posted_invoice;
  v_phase:='PARTIAL_CUSTOMER_PAYMENT';
  v_payment_amount:=round(v_invoice_total*0.75,4);
  v_payment_draft:=public.save_customer_receipt_allocated_draft(NULL,NULL,v_customer,
    v_today,v_method,'RETURN-CREDIT-PARTIAL',
    CASE WHEN v_proof_mode='REQUIRED' THEN 'https://example.invalid/rollback-only-proof'
      ELSE NULL END,
    'Rollback-only payment before Customer Credit Note',v_payment_amount,
    jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE',
      'sourceId',v_posted_invoice,'clientAllocationKey',gen_random_uuid(),
      'allocatedAmount',v_payment_amount)));
  PERFORM public.post_customer_receipt_unified(
    (v_payment_draft->>'documentId')::uuid,
    (v_payment_draft->>'masterVersion')::bigint,gen_random_uuid());
  v_phase:='DRAFT_INVOICE';
  v_result:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,
      'paymentTermId',NULL,'dueDate',v_today,'notes','Step 3 Draft source',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',2,'discountAmount',0,'taxApplied',false))));
  v_draft_invoice:=(v_result->'data'->>'id')::uuid;
  SELECT id INTO STRICT v_draft_line FROM public.backoffice_sales_invoice_lines
  WHERE company_id=v_company AND invoice_id=v_draft_invoice AND line_type='PRODUCT';

  v_phase:='RETURN_AND_PHYSICAL_RECEIPT';
  -- Physical Return qty 3 is received before Finance classification.
  v_result:=public.save_backoffice_sales_return_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('reason','Step 3 mixed Invoice allocation',
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',3,'reason','One qty for each financial destination'))));
  v_return:=(v_result->'data'->>'id')::uuid;
  v_result:=public.submit_backoffice_sales_return(v_return,
    (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_result:=public.approve_backoffice_sales_return(v_return,
    (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
  WHERE company_id=v_company AND return_id=v_return;
  v_result:=public.post_backoffice_sales_return_receipt(v_return,
    (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today,
    jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,'quantityUom',3,
      'warehouseId',v_warehouse,'disposition','RESTOCK','notes','Step 3 fixture')),
    'Step 3 physical receipt');
  v_receipt:=(v_result->>'receiptId')::uuid;
  SELECT id INTO STRICT v_receipt_line FROM public.backoffice_sales_return_receipt_lines
  WHERE company_id=v_company AND receipt_id=v_receipt;
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_returns
  WHERE company_id=v_company AND id=v_return;
  SELECT count(*) INTO v_before_event FROM public.financial_events;
  SELECT count(*) INTO v_before_journal FROM public.finance_journals;

  v_phase:='RETURN_INVOICE_ALLOCATION';
  v_allocate:=public.allocate_backoffice_sales_return_invoices(v_return,v_version,
    v_allocate_op,jsonb_build_array(
      jsonb_build_object('returnReceiptLineId',v_receipt_line,'allocationType','UNINVOICED',
        'quantityUom',1),
      jsonb_build_object('returnReceiptLineId',v_receipt_line,'allocationType','DRAFT_INVOICE',
        'invoiceId',v_draft_invoice,'invoiceLineId',v_draft_line,'quantityUom',1),
      jsonb_build_object('returnReceiptLineId',v_receipt_line,'allocationType','POSTED_INVOICE',
        'invoiceId',v_posted_invoice,'invoiceLineId',v_posted_line,'quantityUom',1)));
  v_retry:=public.allocate_backoffice_sales_return_invoices(v_return,v_version,
    v_allocate_op,jsonb_build_array(
      jsonb_build_object('returnReceiptLineId',v_receipt_line,'allocationType','UNINVOICED',
        'quantityUom',1),
      jsonb_build_object('returnReceiptLineId',v_receipt_line,'allocationType','DRAFT_INVOICE',
        'invoiceId',v_draft_invoice,'invoiceLineId',v_draft_line,'quantityUom',1),
      jsonb_build_object('returnReceiptLineId',v_receipt_line,'allocationType','POSTED_INVOICE',
        'invoiceId',v_posted_invoice,'invoiceLineId',v_posted_line,'quantityUom',1)));
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: allocation exact retry rejected';
  END IF;
  SELECT id INTO STRICT v_note FROM public.backoffice_sales_credit_notes
  WHERE company_id=v_company AND return_id=v_return AND source_invoice_id=v_posted_invoice
    AND status='DRAFT';
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
      WHERE line.company_id=v_company AND line.id=v_order_line
        AND line.returned_before_invoice_base_qty=2
        AND line.returned_after_invoice_base_qty=1
        AND line.draft_invoice_allocated_base_qty=1
        AND line.invoiced_base_qty=2 AND line.to_invoice_base_qty=1)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=v_company AND invoice.id=v_draft_invoice
        AND invoice.status='DRAFT' AND invoice.return_adjustment_pending_confirmation
        AND invoice.master_version>1)
    OR (SELECT count(*) FROM public.financial_events)<>v_before_event
    OR (SELECT count(*) FROM public.finance_journals)<>v_before_journal THEN
    RAISE EXCEPTION 'TEST_FAILED: explicit three-way Return allocation invalid';
  END IF;

  v_phase:='CREDIT_NOTE_POST';
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_credit_notes
  WHERE company_id=v_company AND id=v_note;
  v_posted_note:=public.post_backoffice_sales_credit_note(v_note,v_version,v_post_op);
  v_retry:=public.post_backoffice_sales_credit_note(v_note,v_version,v_post_op);
  v_phase:='CUSTOMER_STATEMENT';
  v_statement:=public.get_finance_customer_statement(v_customer,v_today,v_today,v_store);
  v_phase:='FINAL_ASSERTIONS';
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.id=v_note AND note.status='POSTED'
        AND note.grand_total>0 AND note.ar_reduction_amount>0
        AND note.refund_liability_amount>0
        AND note.ar_reduction_amount+note.refund_liability_amount=note.grand_total)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_returns document
      WHERE document.company_id=v_company AND document.id=v_return
        AND document.status='REFUND_PENDING')
    OR (SELECT round(COALESCE(sum(schedule.credited_amount),0),4)
        FROM public.backoffice_sales_invoice_receivable_schedules schedule
        WHERE schedule.company_id=v_company AND schedule.invoice_id=v_posted_invoice)
      <>round((SELECT note.ar_reduction_amount FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=v_company AND note.id=v_note),4)
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_statement->'rows') item
      WHERE item->>'sourceType'='CREDIT_NOTE' AND item->>'sourceProcess'='BACKOFFICE'
        AND item->>'sourceId'=v_note::text)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      JOIN public.backoffice_sales_credit_notes note
        ON note.company_id=journal.company_id AND note.financial_event_id=journal.financial_event_id
      WHERE note.company_id=v_company AND note.id=v_note AND journal.status='POSTED'
        AND journal.total_debit=note.grand_total AND journal.total_credit=note.grand_total) THEN
    RAISE EXCEPTION 'TEST_FAILED: Credit Note posting or exact retry invalid';
  END IF;

  v_failed:=false;
  BEGIN
    PERFORM public.allocate_backoffice_sales_return_invoices(v_return,v_version,
      gen_random_uuid(),jsonb_build_array(jsonb_build_object(
        'returnReceiptLineId',v_receipt_line,'allocationType','UNINVOICED','quantityUom',1)));
  EXCEPTION WHEN OTHERS THEN
    v_failed:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%';
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale Return allocation version accepted'; END IF;
  UPDATE public.warehouses SET allow_negative_stock=v_original_negative
  WHERE company_id=v_company AND id=v_warehouse;
  RAISE EXCEPTION 'BACKOFFICE_RETURN_CREDIT_NOTE_TEST_ROLLBACK'
    USING ERRCODE='P7701';
  EXCEPTION WHEN SQLSTATE 'P7701' THEN
    NULL;
  END;
  RAISE NOTICE 'backoffice_sales_return_credit_note_behavior PASS: all fixture writes rolled back';
EXCEPTION WHEN OTHERS THEN
  RAISE EXCEPTION 'TEST_PHASE_FAILED [%]: %',v_phase,SQLERRM
    USING ERRCODE=SQLSTATE,
      DETAIL='Assertion tetap aktif; seluruh fixture dibatalkan oleh transaksi test.';
END
$test$;
