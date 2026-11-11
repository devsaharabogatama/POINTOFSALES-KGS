-- Rollback-only behavior for Backoffice AR Task 3.
BEGIN;

DO $test$
DECLARE v_candidate record;v_actor uuid;v_company uuid;v_invoice uuid;v_customer uuid;
  v_method uuid;v_receipt_date date;v_company_today date;v_invoice_item uuid;v_saved jsonb;v_posted jsonb;
  v_retry jsonb;v_receipt uuid;v_receipt_item uuid;v_journal uuid;v_before_used numeric;
  v_after_used numeric;v_credit_used numeric;v_operation uuid:=gen_random_uuid();
  v_invoice_payment jsonb;v_invoice_payment_retry jsonb;v_invoice_payment_receipt uuid;
  v_rejected boolean:=false;v_open_items jsonb;v_counts_before jsonb;v_counts_after jsonb;
  v_store uuid;v_warehouse uuid;v_product_uom uuid;v_customer_category uuid;
  v_order uuid;v_order_line uuid;v_delivery uuid;v_delivery_line uuid;v_version bigint;
  v_fixture_code text;v_local_fixture boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105110000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110110000')
    OR to_regprocedure('public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migrations 20261105110000 and 20261110110000 must be installed';
  END IF;

  SELECT jsonb_build_object('retailSales',(SELECT count(*) FROM public.sales_headers),
    'stockMovements',(SELECT count(*) FROM public.stock_movements),
    'fifoAllocations',(SELECT count(*) FROM public.sale_fifo_allocations))
  INTO v_counts_before;

  FOR v_candidate IN
    SELECT membership.user_id actor_id,membership.company_id
    FROM public.company_memberships membership
    JOIN auth.users auth_user ON auth_user.id=membership.user_id
    JOIN public.company_sales_process_settings setting
      ON setting.company_id=membership.company_id
     AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    WHERE membership.status='ACTIVE'
    ORDER BY membership.created_at,membership.user_id
  LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_candidate.actor_id,'role','authenticated')::text,true);
      PERFORM set_config('request.jwt.claim.sub',v_candidate.actor_id::text,true);
      PERFORM set_config('request.jwt.claim.role','authenticated',true);
      PERFORM public.set_active_company_context(v_candidate.company_id,'BACKOFFICE');
      PERFORM public.get_finance_ar_open_items(NULL,false);
      PERFORM private.acp_require_permission_capability(
        v_candidate.company_id,'finance.customer_receipts','CREATE_DRAFT');
      PERFORM private.acp_require_permission_capability(
        v_candidate.company_id,'finance.customer_receipts','POST');

      SELECT invoice.id,invoice.customer_id,item.id,method.id,
        greatest(invoice.invoice_date,period.start_date)
      INTO v_invoice,v_customer,v_invoice_item,v_method,v_receipt_date
      FROM public.backoffice_sales_invoices invoice
      JOIN public.ar_open_item_registry item ON item.company_id=invoice.company_id
        AND item.scope_kind='BACKOFFICE' AND item.item_kind='INVOICE'
        AND item.source_id=invoice.id AND item.direction='DEBIT'
      JOIN public.accounting_periods period ON period.company_id=invoice.company_id
        AND period.status IN('OPEN','REOPENED')
        AND period.end_date>=invoice.invoice_date
        AND period.start_date<=(current_timestamp AT TIME ZONE
          (SELECT company.timezone FROM public.companies company
            WHERE company.id=invoice.company_id))::date
      JOIN LATERAL(SELECT payment.id FROM public.payment_methods payment
        WHERE payment.company_id=invoice.company_id AND payment.is_active
          AND payment.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
          AND payment.proof_mode<>'REQUIRED'
        ORDER BY payment.is_default DESC,payment.id LIMIT 1) method ON true
      LEFT JOIN LATERAL(SELECT COALESCE(sum(allocation.allocated_amount),0) used
        FROM public.ar_open_item_allocations allocation
        WHERE allocation.company_id=item.company_id
          AND allocation.debit_item_id=item.id) item_usage ON true
      WHERE invoice.company_id=v_candidate.company_id AND invoice.status='POSTED'
        AND greatest(invoice.invoice_date,period.start_date)<=least(period.end_date,
          (current_timestamp AT TIME ZONE
            (SELECT company.timezone FROM public.companies company
              WHERE company.id=invoice.company_id))::date)
        AND item.original_amount-item_usage.used>=4
        AND private.backoffice_invoice_receivable_before_receipts(
          invoice.company_id,invoice.id,greatest(invoice.invoice_date,period.start_date))>=4
      ORDER BY invoice.invoice_date,invoice.id,period.start_date LIMIT 1;
      IF v_invoice IS NULL THEN CONTINUE; END IF;
      v_actor:=v_candidate.actor_id;v_company:=v_candidate.company_id;
      EXIT;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN CONTINUE; END IF;
      RAISE;
    END;
  END LOOP;
  IF v_actor IS NULL THEN
    SELECT profile.id INTO v_actor FROM auth.users auth_user
    JOIN public.profiles profile ON profile.id=auth_user.id
      AND profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;
    PERFORM set_config('request.jwt.claims',jsonb_build_object(
      'sub',v_actor,'role','authenticated')::text,true);
    PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
    PERFORM set_config('request.jwt.claim.role','authenticated',true);
    SELECT company.id,store.id,warehouse.id,product_uom.id,
      (clock_timestamp() AT TIME ZONE company.timezone)::date
    INTO v_company,v_store,v_warehouse,v_product_uom,v_receipt_date
    FROM public.companies company
    JOIN public.company_sales_process_settings process ON process.company_id=company.id
      AND process.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
    JOIN public.warehouses warehouse ON warehouse.company_id=company.id
      AND warehouse.is_active AND warehouse.is_sale_source
      AND (warehouse.store_id IS NULL OR warehouse.store_id=store.id)
    JOIN public.product_uoms product_uom ON product_uom.company_id=company.id
      AND product_uom.is_active AND product_uom.sales_allowed
      AND product_uom.factor_to_base=1 AND product_uom.sale_price>=10
    JOIN public.products product ON product.company_id=product_uom.company_id
      AND product.id=product_uom.product_id AND product.is_active
      AND NOT product.is_bundle AND product.uom_id=product_uom.uom_id
    WHERE company.status='ACTIVE'
      AND NOT public.private_company_feature_enabled(company.id,'tax_sales_enabled')
      AND EXISTS(SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
          AND (clock_timestamp() AT TIME ZONE company.timezone)::date
            BETWEEN period.start_date AND period.end_date)
      AND EXISTS(SELECT 1 FROM public.payment_methods payment
        WHERE payment.company_id=company.id AND payment.is_active
          AND payment.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
          AND payment.proof_mode<>'REQUIRED')
    ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
    IF v_company IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical local Backoffice fixture foundation required';
    END IF;
    PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
    PERFORM private.acp_require_permission_capability(
      v_company,'finance.customer_receipts','CREATE_DRAFT');
    PERFORM private.acp_require_permission_capability(
      v_company,'finance.customer_receipts','POST');
    SELECT payment.id INTO v_method FROM public.payment_methods payment
    WHERE payment.company_id=v_company AND payment.is_active
      AND payment.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
      AND payment.proof_mode<>'REQUIRED'
    ORDER BY payment.is_default DESC,payment.id LIMIT 1;
    SELECT customer.id INTO v_customer FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.is_active
      AND NOT customer.is_system_customer ORDER BY customer.id LIMIT 1;
    IF v_customer IS NULL THEN
      SELECT category.id INTO v_customer_category FROM public.customer_categories category
      WHERE category.company_id=v_company AND category.is_active
      ORDER BY category.is_system_category DESC,category.id LIMIT 1;
      IF v_customer_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Customer Category required';
      END IF;
      v_fixture_code:='AR3TEST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
      v_saved:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
        'AR Task 3 Rollback Customer',v_customer_category,NULL,NULL,NULL,
        'BUSINESS',0,NULL,'Rollback-only Task 3 fixture',true,NULL,NULL);
      v_customer:=(v_saved->>'customerId')::uuid;
    END IF;
    v_saved:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
      jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
        'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_receipt_date,
        'plannedDeliveryDate',v_receipt_date,'isTempo',false,'currencyCode','IDR',
        'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
        'lines',jsonb_build_array(jsonb_build_object(
          'productUomId',v_product_uom,'quantity',2))));
    v_order:=(v_saved->'data'->>'id')::uuid;
    v_saved:=public.confirm_backoffice_sales_order(v_order,
      (v_saved->'data'->>'masterVersion')::bigint,gen_random_uuid());
    v_delivery:=(v_saved->'fulfillment'->>'deliveryOrderId')::uuid;
    SELECT id,sales_order_line_id INTO STRICT v_delivery_line,v_order_line
    FROM public.backoffice_sales_delivery_order_lines
    WHERE company_id=v_company AND delivery_order_id=v_delivery;
    SELECT master_version INTO STRICT v_version
    FROM public.backoffice_sales_delivery_orders
    WHERE company_id=v_company AND id=v_delivery;
    PERFORM public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,
        'quantityUom',2)),'Task 3 rollback Dispatch');
    SELECT master_version INTO STRICT v_version
    FROM public.backoffice_sales_delivery_orders
    WHERE company_id=v_company AND id=v_delivery;
    PERFORM public.receive_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
      v_receipt_date,'Task 3 rollback accepted');
    v_saved:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),
      v_order,jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_receipt_date,
        'paymentTermId',NULL,'dueDate',v_receipt_date,'notes','Task 3 rollback source',
        'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
          'quantityUom',2,'discountAmount',0,'taxApplied',false))));
    v_invoice:=(v_saved->'data'->>'id')::uuid;
    PERFORM public.post_backoffice_sales_invoice(v_invoice,
      (v_saved->'data'->>'masterVersion')::bigint,gen_random_uuid());
    SELECT item.id INTO STRICT v_invoice_item FROM public.ar_open_item_registry item
    WHERE item.company_id=v_company AND item.scope_kind='BACKOFFICE'
      AND item.item_kind='INVOICE' AND item.source_id=v_invoice;
    v_local_fixture:=true;
    SELECT jsonb_build_object('retailSales',(SELECT count(*) FROM public.sales_headers),
      'stockMovements',(SELECT count(*) FROM public.stock_movements),
      'fifoAllocations',(SELECT count(*) FROM public.sale_fifo_allocations))
    INTO v_counts_before;
  END IF;

  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_company_today
  FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';

  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_before_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.debit_item_id=v_invoice_item;

  v_rejected:=false;
  BEGIN
    PERFORM public.save_customer_receipt_open_credit_draft(NULL,NULL,v_customer,
      v_company_today+1,v_method,'TASK3-FUTURE-DATE',NULL,'Rollback behavior',2,
      jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE',
        'sourceId',v_invoice,'clientAllocationKey',gen_random_uuid(),'allocatedAmount',1)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='CUSTOMER_RECEIPT_DATE_FUTURE' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: future Company Receipt date accepted'; END IF;
  v_rejected:=false;

  v_saved:=public.save_customer_receipt_open_credit_draft(NULL,NULL,v_customer,
    v_receipt_date,v_method,'TASK3-OPEN-CREDIT',NULL,'Rollback behavior',2,
    jsonb_build_array(jsonb_build_object('sourceType','BACKOFFICE_SALES_INVOICE',
      'sourceId',v_invoice,'clientAllocationKey',gen_random_uuid(),'allocatedAmount',1)));
  v_receipt:=(v_saved->>'documentId')::uuid;
  IF (v_saved->>'allocatedAmount')::numeric<>1
    OR (v_saved->>'openCreditAmount')::numeric<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: open-credit Draft amount shape invalid';
  END IF;
  v_posted:=public.post_customer_receipt_unified(v_receipt,
    (v_saved->>'masterVersion')::bigint,v_operation);
  v_journal:=(v_posted->>'journalId')::uuid;

  SELECT item.id INTO STRICT v_receipt_item FROM public.ar_open_item_registry item
  WHERE item.company_id=v_company AND item.scope_kind='BACKOFFICE'
    AND item.item_kind='RECEIPT' AND item.source_id=v_receipt
    AND item.customer_id=v_customer AND item.direction='CREDIT'
    AND item.original_amount=2;
  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_after_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.debit_item_id=v_invoice_item;
  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_credit_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.credit_item_id=v_receipt_item;
  IF v_after_used-v_before_used<>1 OR v_credit_used<>1
    OR (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.customer_id=v_customer AND line.debit=2 AND line.credit=0)<>1
    OR (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND line.customer_id=v_customer AND line.debit=0 AND line.credit=2)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: open-credit posting or Journal shape invalid';
  END IF;
  v_open_items:=public.get_finance_ar_open_items(v_customer,false);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_open_items->'items') item
    WHERE (item->>'id')::uuid=v_receipt_item
      AND (item->>'originalAmount')::numeric=2
      AND (item->>'allocatedAmount')::numeric=1
      AND (item->>'residualAmount')::numeric=1) THEN
    RAISE EXCEPTION 'TEST_FAILED: Customer-scoped Receipt residual not visible';
  END IF;

  v_retry:=public.post_customer_receipt_unified(v_receipt,
    (v_saved->>'masterVersion')::bigint,v_operation);
  IF (v_retry->>'journalId')::uuid<>v_journal
    OR (SELECT count(*) FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.financial_event_id=(v_posted->>'financialEventId')::uuid)<>1
    OR (SELECT count(*) FROM public.ar_open_item_registry item
      WHERE item.company_id=v_company AND item.source_id=v_receipt
        AND item.item_kind='RECEIPT')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated Receipt effects';
  END IF;
  BEGIN
    PERFORM public.post_customer_receipt_unified(v_receipt,
      (v_saved->>'masterVersion')::bigint,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='FINAL_CUSTOMER_RECEIPT_IMMUTABLE' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: changed retry accepted'; END IF;

  -- Prove the Invoice detail modal entry point was rebound to the public wrapper.
  v_operation:=gen_random_uuid();
  v_invoice_payment:=public.register_backoffice_sales_invoice_payment(v_invoice,
    v_operation,v_receipt_date,v_method,1,'TASK3-INVOICE-MODAL',NULL,'Rollback behavior');
  v_invoice_payment_receipt:=(v_invoice_payment->'payment'->>'receiptId')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.ar_open_item_registry item
      WHERE item.company_id=v_company AND item.scope_kind='BACKOFFICE'
        AND item.item_kind='RECEIPT' AND item.source_id=v_invoice_payment_receipt
        AND item.original_amount=1)
    OR NOT EXISTS(SELECT 1 FROM public.ar_open_item_allocations allocation
      JOIN public.customer_receipt_backoffice_invoice_allocations source
        ON source.company_id=allocation.company_id
       AND source.id=allocation.source_id AND allocation.source_kind='RECEIPT_ALLOCATION'
      WHERE source.company_id=v_company AND source.document_id=v_invoice_payment_receipt) THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice payment modal bypassed open-item registration';
  END IF;
  v_invoice_payment_retry:=public.register_backoffice_sales_invoice_payment(v_invoice,
    v_operation,v_receipt_date,v_method,1,'TASK3-INVOICE-MODAL',NULL,'Rollback behavior');
  IF COALESCE((v_invoice_payment_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (v_invoice_payment_retry->'payment'->>'receiptId')::uuid<>v_invoice_payment_receipt THEN
    RAISE EXCEPTION 'TEST_FAILED: Invoice payment exact retry invalid';
  END IF;

  IF (SELECT count(DISTINCT audit.entity_kind)
      FROM public.ar_open_item_audit audit WHERE audit.company_id=v_company)<>3
    OR EXISTS(SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_registry item
        ON item.company_id=audit.company_id AND item.id=audit.entity_id
      WHERE audit.company_id=v_company AND audit.entity_kind='REGISTRY'
        AND (item.id IS NULL OR audit.actor_id<>item.created_by
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(item)))
    OR EXISTS(SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_operations operation
        ON operation.company_id=audit.company_id AND operation.id=audit.entity_id
      WHERE audit.company_id=v_company AND audit.entity_kind='OPERATION'
        AND (operation.id IS NULL OR audit.actor_id<>operation.actor_id
          OR audit.state_snapshot IS DISTINCT FROM to_jsonb(operation)))
    OR EXISTS(SELECT 1 FROM public.ar_open_item_audit audit
      LEFT JOIN public.ar_open_item_allocations allocation
        ON allocation.company_id=audit.company_id AND allocation.id=audit.entity_id
      WHERE audit.company_id=v_company AND audit.entity_kind='ALLOCATION'
        AND (allocation.id IS NULL OR audit.actor_id<>allocation.created_by
          OR audit.state_snapshot IS DISTINCT FROM CASE
            WHEN audit.state_snapshot ? 'effective_date' THEN to_jsonb(allocation)
            ELSE to_jsonb(allocation)-'effective_date' END)) THEN
    RAISE EXCEPTION 'TEST_FAILED: Task 2 audit actor/snapshot lineage invalid';
  END IF;
  v_rejected:=false;
  BEGIN
    UPDATE public.ar_open_item_registry SET document_no=document_no
    WHERE company_id=v_company AND id=v_receipt_item;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='AR_OPEN_ITEM_HISTORY_IMMUTABLE' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: open-item registry mutation accepted'; END IF;
  IF has_table_privilege('authenticated','public.ar_open_item_registry','SELECT')
    OR has_table_privilege('authenticated','public.ar_open_item_operations','SELECT')
    OR has_table_privilege('authenticated','public.ar_open_item_allocations','SELECT')
    OR has_table_privilege('authenticated','public.ar_open_item_audit','SELECT') THEN
    RAISE EXCEPTION 'TEST_FAILED: authenticated direct open-item table read is open';
  END IF;

  SELECT jsonb_build_object('retailSales',(SELECT count(*) FROM public.sales_headers),
    'stockMovements',(SELECT count(*) FROM public.stock_movements),
    'fifoAllocations',(SELECT count(*) FROM public.sale_fifo_allocations))
  INTO v_counts_after;
  IF v_counts_after<>v_counts_before THEN
    RAISE EXCEPTION 'TEST_FAILED: AR operation changed Retail/Stock/FIFO rows';
  END IF;
END
$test$;

SELECT 'backoffice_ar_invoice_receipt_allocation_runtime_behavior' AS check_name,
  'PASS' AS status,0::bigint AS violation_rows,jsonb_build_object('tested',ARRAY[
    'installed exact forward migration','authenticated Backoffice Finance actor',
    'next active Company date denied while valid period date remains accepted',
    'partial Invoice allocation plus Customer-scoped residual open credit',
    'single full Cash/Bank-to-AR Journal','append-only Receipt and allocation registration',
    'read RPC residual visibility','exact retry idempotency','changed retry denial',
    'Invoice detail payment entry-point wrapper binding','zero Retail/Stock/FIFO effect',
    'Task 2 registry/operation/allocation audit lineage and append-only boundary',
    'direct authenticated open-item table denial',
    'all test writes rolled back']) AS details;
ROLLBACK;
