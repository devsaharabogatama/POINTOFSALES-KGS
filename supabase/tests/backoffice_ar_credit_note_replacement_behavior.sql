-- Authenticated rollback-only behavior for Backoffice AR Task 6.
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_product_uom uuid;
  v_customer uuid;v_customer_category uuid;v_today date;v_result jsonb;v_retry jsonb;
  v_order uuid;v_order_line uuid;v_delivery uuid;v_delivery_line uuid;v_invoice uuid;
  v_invoice_line uuid;v_return uuid;v_return_line uuid;v_receipt uuid;v_receipt_line uuid;
  v_note uuid;v_version bigint;v_operation uuid:=gen_random_uuid();v_replacement uuid;
  v_replacement_line uuid;v_replacement_version bigint;v_credit_item uuid;v_debit_item uuid;
  v_amount numeric;v_before_order jsonb;v_after_order jsonb;v_before_boundary jsonb;
  v_after_boundary jsonb;v_failed boolean:=false;v_code text;v_phase text:='PRECONDITION';
  v_context text;
BEGIN
  BEGIN
    IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20261110100000') THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Task 6 migration required';
    END IF;
    SELECT profile.id INTO v_actor FROM auth.users auth_user
    JOIN public.profiles profile ON profile.id=auth_user.id
      AND profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Super Admin required'; END IF;
    PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object(
      'sub',v_actor,'role','authenticated')::text,true);

    v_phase:='FIXTURE_FOUNDATION';
    SELECT company.id,store.id,warehouse.id,product_uom.id,
      (clock_timestamp() AT TIME ZONE company.timezone)::date
    INTO v_company,v_store,v_warehouse,v_product_uom,v_today
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
      AND EXISTS(SELECT 1 FROM public.transaction_categories category
        WHERE category.company_id=company.id AND category.is_active
          AND category.system_key='CUSTOMER_CREDIT_NOTE')
    ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
    IF v_company IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Backoffice fixture foundation required';
    END IF;
    PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
    PERFORM private.acp_require_permission_capability(
      v_company,'finance.customer_credit_notes','POST');
    PERFORM private.acp_require_permission_capability(
      v_company,'sales.backoffice_orders','CREATE_DRAFT');
    SELECT customer.id INTO v_customer FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.is_active
      AND NOT customer.is_system_customer ORDER BY customer.id LIMIT 1;
    IF v_customer IS NULL THEN
      SELECT category.id INTO v_customer_category FROM public.customer_categories category
      WHERE category.company_id=v_company AND category.is_active
      ORDER BY category.is_system_category DESC,category.id LIMIT 1;
      v_code:='AR6TEST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
      v_result:=public.save_customer_with_pricelist(NULL,NULL,v_code,
        'AR Task 6 Rollback Customer',v_customer_category,NULL,NULL,NULL,
        'BUSINESS',0,NULL,'Rollback-only Task 6 fixture',true,NULL,NULL);
      v_customer:=(v_result->>'customerId')::uuid;
    END IF;
    v_phase:='SOURCE_ORDER';
    v_result:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
      jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
        'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
        'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
        'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
        'lines',jsonb_build_array(jsonb_build_object(
          'productUomId',v_product_uom,'quantity',2))));
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
      jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,
        'quantityUom',2)),'Task 6 rollback Dispatch');
    SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders
    WHERE company_id=v_company AND id=v_delivery;
    PERFORM public.receive_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
      v_today,'Task 6 rollback accepted');

    v_phase:='SOURCE_INVOICE';
    v_result:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),
      v_order,jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,
        'paymentTermId',NULL,'dueDate',v_today,'notes','Task 6 source Invoice',
        'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
          'quantityUom',2,'discountAmount',0,'taxApplied',false))));
    v_invoice:=(v_result->'data'->>'id')::uuid;
    SELECT id INTO STRICT v_invoice_line FROM public.backoffice_sales_invoice_lines
    WHERE company_id=v_company AND invoice_id=v_invoice AND line_type='PRODUCT';
    PERFORM public.post_backoffice_sales_invoice(v_invoice,
      (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());

    v_phase:='RETURN_AND_DRAFT_CREDIT';
    v_result:=public.save_backoffice_sales_return_draft(NULL,NULL,gen_random_uuid(),
      v_order,jsonb_build_object('reason','Task 6 rollback Return',
        'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
          'quantityUom',1,'reason','Task 6 rollback'))));
    v_return:=(v_result->'data'->>'id')::uuid;
    v_result:=public.submit_backoffice_sales_return(v_return,
      (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
    v_result:=public.approve_backoffice_sales_return(v_return,
      (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
    SELECT id INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
    WHERE company_id=v_company AND return_id=v_return;
    v_result:=public.post_backoffice_sales_return_receipt(v_return,
      (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today,
      jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,
        'quantityUom',1,'warehouseId',v_warehouse,'disposition','RESTOCK',
        'notes','Task 6 rollback receipt')),'Task 6 rollback receipt');
    v_receipt:=(v_result->>'receiptId')::uuid;
    SELECT id INTO STRICT v_receipt_line FROM public.backoffice_sales_return_receipt_lines
    WHERE company_id=v_company AND receipt_id=v_receipt;
    SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_returns
    WHERE company_id=v_company AND id=v_return;
    PERFORM public.allocate_backoffice_sales_return_invoices(v_return,v_version,
      gen_random_uuid(),jsonb_build_array(jsonb_build_object(
        'returnReceiptLineId',v_receipt_line,'allocationType','POSTED_INVOICE',
        'invoiceId',v_invoice,'invoiceLineId',v_invoice_line,'quantityUom',1)));
    SELECT id,master_version INTO STRICT v_note,v_version
    FROM public.backoffice_sales_credit_notes
    WHERE company_id=v_company AND return_id=v_return
      AND source_invoice_id=v_invoice AND status='DRAFT';
    SELECT jsonb_build_object('sales',(SELECT count(*) FROM public.sales_headers),
      'stock',(SELECT count(*) FROM public.stock_movements),
      'fifo',(SELECT count(*) FROM public.sale_fifo_allocations),
      'dispatch',(SELECT count(*) FROM public.backoffice_sales_delivery_orders))
    INTO v_before_boundary;
    SELECT jsonb_build_object('draft',draft_invoice_allocated_base_qty,
      'invoiced',invoiced_base_qty,'toInvoice',to_invoice_base_qty)
    INTO v_before_order FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND id=v_order_line;

    v_phase:='ATOMIC_ACTION';
    v_result:=public.post_backoffice_credit_note_create_replacement_invoice(
      v_note,v_version,v_operation);
    v_replacement:=(v_result->>'replacementInvoiceId')::uuid;
    v_amount:=(v_result->>'allocatedToSource')::numeric;
    IF v_amount<=0 OR (v_result->>'remainingCredit')::numeric<>0 THEN
      RAISE EXCEPTION 'TEST_FAILED: source residual allocation invalid';
    END IF;
    SELECT id INTO STRICT v_credit_item FROM public.ar_open_item_registry
    WHERE company_id=v_company AND item_kind='CREDIT_NOTE' AND source_id=v_note;
    SELECT id INTO STRICT v_debit_item FROM public.ar_open_item_registry
    WHERE company_id=v_company AND item_kind='INVOICE' AND source_id=v_invoice;
    IF private.ar5_item_allocated(v_company,v_credit_item,NULL)<>v_amount
      OR private.ar5_item_allocated(v_company,v_debit_item,NULL)<>v_amount THEN
      RAISE EXCEPTION 'TEST_FAILED: open-item allocation lineage invalid';
    END IF;
    IF EXISTS(SELECT 1 FROM public.financial_events event
        WHERE event.company_id=v_company AND event.source_table='backoffice_sales_invoices'
          AND event.source_id=v_replacement)
      OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations allocation
        WHERE allocation.company_id=v_company AND allocation.invoice_id=v_replacement) THEN
      RAISE EXCEPTION 'TEST_FAILED: replacement Draft has Finance or qty allocation effect';
    END IF;
    SELECT id INTO STRICT v_replacement_line FROM public.backoffice_sales_invoice_lines
    WHERE company_id=v_company AND invoice_id=v_replacement
      AND source_kind='CREDIT_NOTE_REPLACEMENT'
      AND replacement_source_invoice_line_id=v_invoice_line;
    v_retry:=public.post_backoffice_credit_note_create_replacement_invoice(
      v_note,v_version,v_operation);
    IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
      OR (v_retry->>'replacementInvoiceId')::uuid<>v_replacement THEN
      RAISE EXCEPTION 'TEST_FAILED: exact retry invalid';
    END IF;
    v_failed:=false;
    BEGIN
      PERFORM public.post_backoffice_credit_note_create_replacement_invoice(
        v_note,v_version+1,v_operation);
    EXCEPTION WHEN OTHERS THEN v_failed:=SQLERRM='IDEMPOTENCY_PAYLOAD_CONFLICT'; END;
    IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: changed retry accepted'; END IF;

    v_phase:='REPLACEMENT_EDIT_AND_POST';
    SELECT master_version INTO STRICT v_replacement_version
    FROM public.backoffice_sales_invoices WHERE company_id=v_company AND id=v_replacement;
    v_result:=public.save_backoffice_sales_invoice_draft(v_replacement,
      v_replacement_version,gen_random_uuid(),v_order,jsonb_build_object(
        'invoiceType','REGULAR','invoiceDate',v_today,'dueDate',v_today,
        'deliveryFeeAmount',0,'notes','Task 6 edited replacement',
        'lines',jsonb_build_array(jsonb_build_object(
          'salesOrderLineId',v_order_line,
          'replacementSourceInvoiceLineId',v_invoice_line,'quantityUom',1,
          'unitPrice',(SELECT (source_snapshot->>'enteredGrossUnitPrice')::numeric
            FROM public.backoffice_sales_invoice_lines WHERE company_id=v_company
              AND id=v_replacement_line),'discountAmount',0,'taxApplied',false)),
        'acceptedOverageLines','[]'::jsonb));
    v_replacement_version:=(v_result->'data'->>'masterVersion')::bigint;
    PERFORM public.post_backoffice_sales_invoice(
      v_replacement,v_replacement_version,gen_random_uuid());
    IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_invoices invoice
        JOIN public.financial_events event ON event.company_id=invoice.company_id
          AND event.id=invoice.financial_event_id AND event.status='POSTED'::public.event_status
        JOIN public.ar_open_item_registry item ON item.company_id=invoice.company_id
          AND item.item_kind='INVOICE' AND item.source_id=invoice.id
        WHERE invoice.company_id=v_company AND invoice.id=v_replacement
          AND invoice.status='POSTED') THEN
      RAISE EXCEPTION 'TEST_FAILED: replacement Invoice normal Finance post missing';
    END IF;
    IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.invoice_id=v_replacement) THEN
      RAISE EXCEPTION 'TEST_FAILED: replacement post created qty allocation';
    END IF;
    SELECT jsonb_build_object('draft',draft_invoice_allocated_base_qty,
      'invoiced',invoiced_base_qty,'toInvoice',to_invoice_base_qty)
    INTO v_after_order FROM public.backoffice_sales_order_lines
    WHERE company_id=v_company AND id=v_order_line;
    IF v_after_order<>v_before_order THEN
      RAISE EXCEPTION 'TEST_FAILED: replacement changed Sales Order qty counters';
    END IF;
    SELECT jsonb_build_object('sales',(SELECT count(*) FROM public.sales_headers),
      'stock',(SELECT count(*) FROM public.stock_movements),
      'fifo',(SELECT count(*) FROM public.sale_fifo_allocations),
      'dispatch',(SELECT count(*) FROM public.backoffice_sales_delivery_orders))
    INTO v_after_boundary;
    IF v_after_boundary<>v_before_boundary THEN
      RAISE EXCEPTION 'TEST_FAILED: unexpected Retail/Stock/FIFO or extra Dispatch effect';
    END IF;
    RAISE EXCEPTION 'BACKOFFICE_AR_TASK6_TEST_ROLLBACK' USING ERRCODE='P7702';
  EXCEPTION WHEN SQLSTATE 'P7702' THEN NULL;
  END;
  RAISE NOTICE 'backoffice_ar_credit_note_replacement_behavior PASS: all fixture writes rolled back';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_context=PG_EXCEPTION_CONTEXT;
  RAISE EXCEPTION 'TEST_PHASE_FAILED [%]: %',v_phase,SQLERRM
    USING ERRCODE=SQLSTATE,DETAIL='Assertions remain active; context: '||COALESCE(v_context,'');
END
$test$;

SELECT 'backoffice_ar_credit_note_replacement_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'installed exact forward migration','authenticated Backoffice actor',
    'canonical SO/Dispatch/Invoice/Return/Credit Note fixture',
    'atomic Credit Note post plus source residual allocation',
    'Customer-scoped open-item lineage','replacement Draft without Finance effect',
    'replacement commercial copy without old settlement copy',
    'exact retry and changed retry denial','replacement Draft edit',
    'replacement normal Invoice Finance post','zero Sales Order qty-counter duplication',
    'zero Retail/Stock/FIFO and extra Dispatch effect','all fixture writes rolled back']) details;
