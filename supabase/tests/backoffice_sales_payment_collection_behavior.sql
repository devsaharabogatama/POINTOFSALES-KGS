-- Authenticated, self-contained and rollback-only payment collection behavior.
-- Run only after migration 20260911160000 on isolated Development.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_customer_category uuid;v_fixture_code text;
  v_product_uom uuid;v_product uuid;v_method uuid;v_today date;v_topup numeric;
  v_stock_after numeric;v_batch_id uuid:=gen_random_uuid();v_movement_id uuid:=gen_random_uuid();
  v_created jsonb;v_confirmed jsonb;v_dispatched jsonb;v_received jsonb;
  v_invoice_draft jsonb;v_invoice_posted jsonb;v_receipt_one jsonb;v_post_one jsonb;
  v_receipt_two jsonb;v_post_two jsonb;v_retry jsonb;v_order uuid;v_order_line uuid;
  v_workspace jsonb;v_aging jsonb;v_statement jsonb;
  v_delivery uuid;v_delivery_line uuid;v_invoice uuid;v_version bigint;
  v_grand numeric;v_first numeric;v_second numeric;v_event uuid;v_journal uuid;
  v_post_key_one uuid:=gen_random_uuid();v_post_key_two uuid:=gen_random_uuid();
  v_retail_alloc_before bigint;v_sales_before bigint;v_failed boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911163000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260911163000 unified AR reporting integration required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911161000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260911161000 payment account mapping fix required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911162000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260911162000 Invoice payment UI runtime required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users actor ON actor.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,warehouse.id,product_uom.id,
    product_uom.product_id,method.id,
    (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_company,v_store,v_warehouse,v_product_uom,v_product,v_method,v_today
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
    AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
  JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
    AND product_uom.is_active AND product_uom.sales_allowed AND product_uom.factor_to_base=1
  JOIN public.products product ON product.company_id=product_uom.company_id
    AND product.id=product_uom.product_id AND product.is_active AND NOT product.is_bundle
    AND product.uom_id=product_uom.uom_id
  JOIN LATERAL(
    SELECT payment_method.id
    FROM public.payment_methods payment_method
    WHERE payment_method.company_id=company.id AND payment_method.is_active
      AND payment_method.settlement_route IN('DIRECT_BANK','CASH_DRAWER')
    ORDER BY CASE payment_method.settlement_route WHEN 'DIRECT_BANK' THEN 1 ELSE 2 END,
      payment_method.id LIMIT 1
  ) method ON true
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
        AND (clock_timestamp() AT TIME ZONE company.timezone)::date
          BETWEEN period.start_date AND period.end_date)
  ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
  IF v_actor IS NULL OR v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Company, Product-UOM, Warehouse, Payment Method and current open period required';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();

  SELECT customer.id INTO v_customer
  FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
    AND NOT customer.is_system_customer
  ORDER BY customer.id LIMIT 1;
  IF v_customer IS NULL THEN
    SELECT category.id INTO v_customer_category
    FROM public.customer_categories category
    WHERE category.company_id=v_company AND category.is_active
    ORDER BY category.is_system_category DESC,category.id LIMIT 1;
    IF v_customer_category IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical active Customer Category required';
    END IF;
    v_fixture_code:='PAYTEST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    v_created:=public.save_customer_with_pricelist(
      NULL,NULL,v_fixture_code,'Payment Collection Rollback Customer',
      v_customer_category,NULL,NULL,NULL,'BUSINESS',0,NULL,
      'Rollback-only payment collection fixture',TRUE,NULL,NULL);
    v_customer:=(v_created->>'customerId')::uuid;
    IF v_customer IS NULL OR NOT EXISTS(
      SELECT 1 FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.id=v_customer
        AND customer.code=v_fixture_code AND customer.is_active
        AND NOT customer.is_system_customer
    ) THEN
      RAISE EXCEPTION 'TEST_FAILED: canonical rollback Customer fixture was not created';
    END IF;
  END IF;
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE
    SET is_enabled=true,updated_by=excluded.updated_by;

  -- Prepare the Company-mode prerequisite only inside outer rollback.
  -- Clear the guarded setup marker BEFORE invoking operational Sales RPCs.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company sales process setting required'; END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(
    v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');

  SELECT COALESCE(stock_qty,0) INTO v_stock_after FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  v_topup:=CASE WHEN COALESCE(v_stock_after,0)<10 THEN 10-COALESCE(v_stock_after,0) ELSE 10 END;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_topup,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE
    SET stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,
      updated_at=clock_timestamp();
  INSERT INTO public.product_batches(id,product_id,warehouse_id,qty_purchased,
    qty_remaining,cogs_unit,company_id)
  SELECT v_batch_id,v_product,v_warehouse,v_topup,v_topup,
    GREATEST(COALESCE(product.cogs,1),1),v_company
  FROM public.products product WHERE product.company_id=v_company AND product.id=v_product;
  SELECT stock_qty INTO STRICT v_stock_after FROM public.product_stocks
  WHERE company_id=v_company AND warehouse_id=v_warehouse AND product_id=v_product;
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_movement_id,v_product,v_warehouse,v_topup,
    'PURCHASE'::public.stock_movement_type,'BACKOFFICE_PAYMENT_COLLECTION_TEST',v_batch_id,
    v_company,product.uom_id,uom.name,v_stock_after,v_actor,clock_timestamp(),
    'POSTED',v_batch_id,'Rollback-only payment collection fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_product;

  SELECT count(*) INTO v_retail_alloc_before FROM public.customer_receipt_allocations;
  SELECT count(*) INTO v_sales_before FROM public.sales_headers;
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
    jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
      'selectedPricelistId',NULL,'orderDate',v_today,'plannedDeliveryDate',v_today,
      'isTempo',true,'dueDate',v_today+14,'currencyCode','IDR','globalDiscount',0,
      'deliveryFeeAmount',0,'roundingDirection','NONE','roundingIncrement',100,
      'lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,
        'quantity',1,'overrideUnitPrice',100000))));
  v_order:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_order,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());
  SELECT id INTO STRICT v_order_line FROM public.backoffice_sales_order_lines
  WHERE company_id=v_company AND sales_order_id=v_order;
  v_delivery:=(v_confirmed->'fulfillment'->>'deliveryOrderId')::uuid;
  SELECT id INTO STRICT v_delivery_line FROM public.backoffice_sales_delivery_order_lines
  WHERE company_id=v_company AND delivery_order_id=v_delivery;
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_dispatched:=public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,'quantityUom',1)),
    'Payment collection rollback fixture');
  SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
  WHERE company_id=v_company AND id=v_delivery;
  v_received:=public.receive_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
    v_today,'Payment collection rollback fixture');
  IF v_received->>'deliveryStatus'<>'COMPLETED' THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice delivery did not complete';
  END IF;

  v_invoice_draft:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),v_order,
    jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,'dueDate',v_today+14,
      'paymentTermId',NULL,'deliveryFeeAmount',0,
      'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
        'quantityUom',1,'unitPrice',100000,'discountAmount',0,'taxApplied',false))));
  v_invoice:=(v_invoice_draft->'data'->>'id')::uuid;
  v_invoice_posted:=public.post_backoffice_sales_invoice(v_invoice,
    (v_invoice_draft->'data'->>'masterVersion')::bigint,gen_random_uuid());
  IF v_invoice_posted->'data'->>'status'<>'POSTED'
    OR v_invoice_posted->'finance'->>'status'<>'POSTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Backoffice Invoice posting failed';
  END IF;
  SELECT grand_total INTO STRICT v_grand FROM public.backoffice_sales_invoices
  WHERE company_id=v_company AND id=v_invoice;
  v_first:=round(v_grand*0.4,4);v_second:=v_grand-v_first;

  v_receipt_one:=public.save_customer_receipt_allocated_draft(NULL,NULL,v_customer,v_today,
    v_method,'PAY-1',NULL,'Partial Backoffice Invoice payment',v_first,
    jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE',
      'sourceId',v_invoice,'clientAllocationKey',gen_random_uuid(),'allocatedAmount',v_first)));
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_receivable_schedules
    WHERE company_id=v_company AND invoice_id=v_invoice AND allocated_payment_amount<>0) THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft receipt changed Invoice outstanding';
  END IF;
  BEGIN
    PERFORM public.post_customer_receipt_unified(
      (v_receipt_one->>'documentId')::uuid,(v_receipt_one->>'masterVersion')::bigint+1,
      gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale payment posting was accepted'; END IF;
  v_post_one:=public.post_customer_receipt_unified(
    (v_receipt_one->>'documentId')::uuid,(v_receipt_one->>'masterVersion')::bigint,
    v_post_key_one);
  IF v_post_one->>'status'<>'POSTED'
    OR (SELECT round(sum(allocated_payment_amount),4)
      FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=v_invoice)<>v_first
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=v_invoice AND status='PARTIALLY_PAID') THEN
    RAISE EXCEPTION 'TEST_FAILED: first partial payment did not reconcile schedule';
  END IF;

  v_workspace:=public.get_finance_customer_receipts();
  v_aging:=public.get_finance_ar_aging(v_today,v_customer,v_store);
  v_statement:=public.get_finance_customer_statement(v_customer,v_today,v_today,v_store);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_workspace->'openInvoices') item
      WHERE item->>'sourceType'='BACKOFFICE_SALES_INVOICE'
        AND item->>'sourceId'=v_invoice::text
        AND round((item->>'remainingAmount')::numeric,4)=round(v_second,4))
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_workspace->'allocations') item
      WHERE item->>'source_type'='BACKOFFICE_SALES_INVOICE'
        AND item->>'source_id'=v_invoice::text
        AND round((item->>'allocated_amount')::numeric,4)=round(v_first,4))
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_aging->'invoices') item
      WHERE item->>'sourceProcess'='BACKOFFICE' AND item->>'sourceId'=v_invoice::text
        AND round((item->>'outstanding')::numeric,4)=round(v_second,4))
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_statement->'rows') item
      WHERE item->>'sourceType'='INVOICE' AND item->>'sourceProcess'='BACKOFFICE'
        AND item->>'sourceId'=v_invoice::text)
    OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_statement->'rows') item
      WHERE item->>'sourceType'='RECEIPT' AND item->>'sourceProcess'='BACKOFFICE'
        AND round((item->>'credit')::numeric,4)=round(v_first,4)) THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice Invoice is not reconciled across Receipt workspace, Aging and Statement';
  END IF;

  v_receipt_two:=public.register_backoffice_sales_invoice_payment(v_invoice,v_post_key_two,
    v_today,v_method,v_second,'PAY-2',NULL,'Final Backoffice Invoice payment');
  v_post_two:=v_receipt_two->'payment';
  IF v_post_two->>'status'<>'POSTED'
    OR v_receipt_two->'paymentContext'->'summary'->>'status'<>'PAID'
    OR jsonb_array_length(v_receipt_two->'paymentContext'->'payments')<>2
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=v_invoice
        AND (status<>'PAID' OR allocated_payment_amount<>amount_due))
    OR (SELECT round(sum(allocation.allocated_amount),4)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
       AND receipt.status='POSTED'
      WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice)<>round(v_grand,4) THEN
    RAISE EXCEPTION 'TEST_FAILED: final payment did not settle Invoice';
  END IF;
  SELECT financial_event_id INTO STRICT v_event
  FROM public.customer_receipt_documents
  WHERE company_id=v_company AND id=(v_post_two->>'receiptId')::uuid;
  SELECT id INTO STRICT v_journal FROM public.finance_journals
  WHERE company_id=v_company AND financial_event_id=v_event AND status='POSTED';
  IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.id=v_journal
        AND round(journal.total_debit,4)=round(v_second,4)
        AND round(journal.total_credit,4)=round(v_second,4))
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.debit=v_second AND line.credit=0)
    OR NOT EXISTS(SELECT 1 FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.credit=v_second AND line.debit=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: final receipt journal is not balanced';
  END IF;
  v_retry:=public.register_backoffice_sales_invoice_payment(v_invoice,v_post_key_two,
    v_today,v_method,v_second,'PAY-2',NULL,'Final Backoffice Invoice payment');
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (SELECT count(*) FROM public.finance_journals
      WHERE company_id=v_company AND financial_event_id=v_event)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated payment effect';
  END IF;
  v_workspace:=public.get_finance_customer_receipts();
  v_aging:=public.get_finance_ar_aging(v_today,v_customer,v_store);
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_workspace->'openInvoices') item
      WHERE item->>'sourceType'='BACKOFFICE_SALES_INVOICE' AND item->>'sourceId'=v_invoice::text)
    OR EXISTS(SELECT 1 FROM jsonb_array_elements(v_aging->'invoices') item
      WHERE item->>'sourceProcess'='BACKOFFICE' AND item->>'sourceId'=v_invoice::text) THEN
    RAISE EXCEPTION 'TEST_FAILED: paid Backoffice Invoice remains open in Receipt workspace or Aging';
  END IF;
  v_failed:=false;
  BEGIN
    PERFORM public.register_backoffice_sales_invoice_payment(v_invoice,gen_random_uuid(),
      v_today,v_method,1,'PAY-OVER',NULL,'Rejected overpayment');
  EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM LIKE '%CUSTOMER_RECEIPT_OVER_ALLOCATION%'; END;
  IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: over-allocation was accepted'; END IF;
  IF (SELECT count(*) FROM public.customer_receipt_allocations)<>v_retail_alloc_before
    OR (SELECT count(*) FROM public.sales_headers)<>v_sales_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Backoffice payment changed Retail allocation or Sales';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_payment_collection_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical completed SO and posted Invoice','Draft payment zero final effect',
    'stale version denied','unified post dispatch','partial payment schedule','final settlement schedule',
    'posted allocation reconciliation','balanced Cash/Bank to AR journal',
    'atomic Invoice register payment','payment context and receipt history',
    'unified Receipt workspace','Backoffice AR Aging installment','Customer Statement source tracing',
    'exact retry','over-allocation denied','Retail allocation and Sales unchanged',
    'all fixture writes rolled back']) details;
