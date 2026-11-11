-- Authenticated rollback-only behavior for Backoffice AR Task 5.
-- The fixture temporarily reverses the historical Task 2 allocation of one
-- native Backoffice Credit Note. Every write is rolled back by the nested
-- exception block; no production document or Journal survives this script.
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_other_company uuid;v_credit_item uuid;
  v_invoice_item uuid;v_other_invoice_item uuid;v_customer uuid;v_method uuid;v_today date;
  v_fixture_operation uuid:=gen_random_uuid();v_operation uuid;v_result jsonb;
  v_retry jsonb;v_reverse jsonb;v_credit_residual numeric(24,4);
  v_invoice_residual numeric(24,4);v_balance_before numeric(20,4);
  v_balance_after numeric(20,4);v_failed boolean:=false;v_allocation record;
  v_parity_installed boolean:=false;
  v_store uuid;v_warehouse uuid;v_product_uom uuid;v_customer_category uuid;
  v_order uuid;v_order_line uuid;v_delivery uuid;v_delivery_line uuid;
  v_invoice uuid;v_invoice_line uuid;v_return uuid;v_return_line uuid;
  v_receipt uuid;v_receipt_line uuid;v_note uuid;v_version bigint;
  v_invoice_source uuid;v_invoice_credit_before numeric(24,4);
  v_fixture_code text;
  v_counts_before jsonb;v_counts_after jsonb;v_phase text:='PRECONDITION';
  v_error_context text;
BEGIN
  BEGIN
    IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20261106100000')
      OR to_regprocedure('public.apply_backoffice_ar_open_credit(uuid,jsonb,date,numeric,uuid)') IS NULL
      OR to_regprocedure('public.reverse_backoffice_ar_open_credit_action(uuid,date,text,uuid)') IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Task 5 migration 20261106100000 required';
    END IF;
    SELECT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110130000') INTO v_parity_installed;

    SELECT profile.id INTO v_actor FROM auth.users auth_user
    JOIN public.profiles profile ON profile.id=auth_user.id
      AND profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;
    PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object(
      'sub',v_actor,'role','authenticated')::text,true);

    v_phase:='FIXTURE_SELECTION';
    SELECT credit.company_id,credit.id,debit.id,credit.customer_id,
      (clock_timestamp() AT TIME ZONE company.timezone)::date
    INTO v_company,v_credit_item,v_invoice_item,v_customer,v_today
    FROM public.ar_open_item_registry credit
    JOIN public.backoffice_sales_credit_notes note
      ON note.company_id=credit.company_id AND note.id=credit.source_id
     AND note.status='POSTED' AND note.source_kind='BACKOFFICE'
    JOIN public.ar_open_item_registry debit
      ON debit.company_id=credit.company_id AND debit.item_kind='INVOICE'
     AND debit.source_id=note.source_invoice_id AND debit.customer_id=credit.customer_id
    JOIN public.companies company ON company.id=credit.company_id AND company.status='ACTIVE'
    JOIN public.company_sales_process_settings process
      ON process.company_id=company.id
     AND process.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    WHERE credit.scope_kind='BACKOFFICE' AND credit.item_kind='CREDIT_NOTE'
      AND credit.direction='CREDIT' AND credit.original_amount>=10
      AND debit.original_amount-private.ar5_item_allocated(
        debit.company_id,debit.id,NULL)+COALESCE((SELECT sum(CASE
          WHEN allocation.reversal_of_allocation_id IS NULL
            THEN allocation.allocated_amount ELSE -allocation.allocated_amount END)
        FROM public.ar_open_item_allocations allocation
        WHERE allocation.company_id=credit.company_id
          AND allocation.debit_item_id=debit.id
          AND allocation.credit_item_id=credit.id),0)>=10
      AND NOT public.private_company_feature_enabled(company.id,'tax_sales_enabled')
      AND EXISTS(SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=company.id AND period.status IN('OPEN','REOPENED')
          AND (clock_timestamp() AT TIME ZONE company.timezone)::date
            BETWEEN period.start_date AND period.end_date)
    ORDER BY credit.created_at,credit.id LIMIT 1;
    IF v_company IS NULL THEN
      -- Production normally supplies one historical native Credit Note. A
      -- schema-only local database deliberately has no business data, so build
      -- the same canonical lineage inside this rollback-only subtransaction.
      v_phase:='LOCAL_CANONICAL_FIXTURE';
      SELECT company.id,store.id,warehouse.id,product_uom.id,
        (clock_timestamp() AT TIME ZONE company.timezone)::date
      INTO v_company,v_store,v_warehouse,v_product_uom,v_today
      FROM public.companies company
      JOIN public.company_sales_process_settings process
        ON process.company_id=company.id
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
          WHERE category.company_id=company.id
            AND category.system_key='CUSTOMER_CREDIT_NOTE' AND category.is_active)
      ORDER BY company.id,store.id,warehouse.id,product_uom.id LIMIT 1;
      IF v_company IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: local canonical Backoffice fixture foundation required';
      END IF;
      PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
      SELECT customer.id INTO v_customer FROM public.customers customer
      WHERE customer.company_id=v_company AND customer.is_active
        AND NOT customer.is_system_customer ORDER BY customer.id LIMIT 1;
      IF v_customer IS NULL THEN
        SELECT category.id INTO v_customer_category
        FROM public.customer_categories category
        WHERE category.company_id=v_company AND category.is_active
        ORDER BY category.is_system_category DESC,category.id LIMIT 1;
        IF v_customer_category IS NULL THEN
          RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical Customer Category required';
        END IF;
        v_fixture_code:='AR5TEST-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
        v_result:=public.save_customer_with_pricelist(NULL,NULL,v_fixture_code,
          'AR Task 5 Rollback Customer',v_customer_category,NULL,NULL,NULL,
          'BUSINESS',0,NULL,'Rollback-only Task 5 fixture',true,NULL,NULL);
        v_customer:=(v_result->>'customerId')::uuid;
      END IF;

      v_phase:='LOCAL_ORDER_SAVE';
      v_result:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),
        jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
          'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
          'plannedDeliveryDate',v_today,'isTempo',false,'currencyCode','IDR',
          'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
          'lines',jsonb_build_array(jsonb_build_object(
            'productUomId',v_product_uom,'quantity',2))));
      v_order:=(v_result->'data'->>'id')::uuid;
      v_phase:='LOCAL_ORDER_CONFIRM';
      v_result:=public.confirm_backoffice_sales_order(v_order,
        (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
      v_delivery:=(v_result->'fulfillment'->>'deliveryOrderId')::uuid;
      SELECT id,sales_order_line_id INTO STRICT v_delivery_line,v_order_line
      FROM public.backoffice_sales_delivery_order_lines
      WHERE company_id=v_company AND delivery_order_id=v_delivery;
      SELECT master_version INTO STRICT v_version
      FROM public.backoffice_sales_delivery_orders
      WHERE company_id=v_company AND id=v_delivery;
      v_phase:='LOCAL_DELIVERY_DISPATCH';
      PERFORM public.dispatch_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
        jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line,
          'quantityUom',2)),'Task 5 rollback fixture Dispatch');
      SELECT master_version INTO STRICT v_version
      FROM public.backoffice_sales_delivery_orders
      WHERE company_id=v_company AND id=v_delivery;
      v_phase:='LOCAL_DELIVERY_RECEIPT';
      PERFORM public.receive_backoffice_sales_delivery(v_delivery,v_version,gen_random_uuid(),
        v_today,'Task 5 rollback fixture accepted');

      v_phase:='LOCAL_INVOICE_SAVE';
      v_result:=public.save_backoffice_sales_invoice_draft(NULL,NULL,gen_random_uuid(),
        v_order,jsonb_build_object('invoiceType','REGULAR','invoiceDate',v_today,
          'paymentTermId',NULL,'dueDate',v_today,'notes','Task 5 rollback source',
          'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
            'quantityUom',2,'discountAmount',0,'taxApplied',false))));
      v_invoice:=(v_result->'data'->>'id')::uuid;
      SELECT id INTO STRICT v_invoice_line FROM public.backoffice_sales_invoice_lines
      WHERE company_id=v_company AND invoice_id=v_invoice AND line_type='PRODUCT';
      v_phase:='LOCAL_INVOICE_POST';
      PERFORM public.post_backoffice_sales_invoice(v_invoice,
        (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());

      v_phase:='LOCAL_RETURN_SAVE';
      v_result:=public.save_backoffice_sales_return_draft(NULL,NULL,gen_random_uuid(),
        v_order,jsonb_build_object('reason','Task 5 rollback fixture Return',
          'lines',jsonb_build_array(jsonb_build_object('salesOrderLineId',v_order_line,
            'quantityUom',1,'reason','Task 5 rollback fixture'))));
      v_return:=(v_result->'data'->>'id')::uuid;
      v_phase:='LOCAL_RETURN_SUBMIT';
      v_result:=public.submit_backoffice_sales_return(v_return,
        (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
      v_phase:='LOCAL_RETURN_APPROVE';
      v_result:=public.approve_backoffice_sales_return(v_return,
        (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid());
      SELECT id INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
      WHERE company_id=v_company AND return_id=v_return;
      v_phase:='LOCAL_RETURN_RECEIPT';
      v_result:=public.post_backoffice_sales_return_receipt(v_return,
        (v_result->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today,
        jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,
          'quantityUom',1,'warehouseId',v_warehouse,'disposition','RESTOCK',
          'notes','Task 5 rollback fixture')),'Task 5 rollback physical receipt');
      v_receipt:=(v_result->>'receiptId')::uuid;
      SELECT id INTO STRICT v_receipt_line
      FROM public.backoffice_sales_return_receipt_lines
      WHERE company_id=v_company AND receipt_id=v_receipt;
      SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_returns
      WHERE company_id=v_company AND id=v_return;
      v_phase:='LOCAL_RETURN_ALLOCATION';
      v_result:=public.allocate_backoffice_sales_return_invoices(v_return,v_version,
        gen_random_uuid(),jsonb_build_array(jsonb_build_object(
          'returnReceiptLineId',v_receipt_line,'allocationType','POSTED_INVOICE',
          'invoiceId',v_invoice,'invoiceLineId',v_invoice_line,'quantityUom',1)));
      SELECT id,master_version INTO STRICT v_note,v_version
      FROM public.backoffice_sales_credit_notes
      WHERE company_id=v_company AND return_id=v_return
        AND source_invoice_id=v_invoice AND status='DRAFT';
      v_phase:='LOCAL_CREDIT_NOTE_PERMISSION';
      IF auth.uid() IS DISTINCT FROM v_actor THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: fixture actor context changed';
      END IF;
      PERFORM private.acp_require_permission_capability(
        v_company,'finance.customer_credit_notes','POST');
      v_phase:='LOCAL_CREDIT_NOTE_POST';
      PERFORM public.post_backoffice_sales_credit_note(
        v_note,v_version,gen_random_uuid());
      SELECT credit.id,debit.id,credit.customer_id
      INTO STRICT v_credit_item,v_invoice_item,v_customer
      FROM public.ar_open_item_registry credit
      JOIN public.ar_open_item_registry debit
        ON debit.company_id=credit.company_id AND debit.item_kind='INVOICE'
       AND debit.source_id=v_invoice AND debit.customer_id=credit.customer_id
      WHERE credit.company_id=v_company AND credit.item_kind='CREDIT_NOTE'
        AND credit.source_id=v_note AND credit.direction='CREDIT';
    END IF;
    IF v_company IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: native Backoffice Credit Note >= 10, source Invoice and current open period required';
    END IF;
    PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
    PERFORM private.acp_require_permission_capability(
      v_company,'finance.customer_receipts','POST');
    PERFORM private.acp_require_permission_capability(
      v_company,'finance.customer_refunds','POST');

    SELECT method.id INTO v_method FROM public.payment_methods method
    JOIN public.backoffice_sales_credit_notes note
      ON note.company_id=method.company_id AND note.id=(SELECT item.source_id
        FROM public.ar_open_item_registry item
        WHERE item.company_id=v_company AND item.id=v_credit_item)
    WHERE method.company_id=v_company AND method.is_active
      AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')
      AND (method.settlement_route='CASH_DRAWER'
        OR NULLIF(btrim(method.bank_account_function),'') IS NOT NULL)
      AND (method.available_all_stores OR EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=method.company_id
          AND assignment.payment_method_id=method.id AND assignment.store_id=note.store_id))
    ORDER BY (method.proof_mode<>'REQUIRED') DESC,method.is_default DESC,method.id LIMIT 1;
    IF v_method IS NULL THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: eligible Cash/Bank refund method required';
    END IF;

    v_phase:='FIXTURE_OPEN_CREDIT';
    -- Reverse only the ledger allocations in this rollback transaction. This
    -- does not reverse the historical Credit Note or its canonical Journal.
    INSERT INTO public.ar_open_item_operations(id,company_id,operation_kind,
      idempotency_key,request_hash,actor_id,operation_snapshot)
    VALUES(v_fixture_operation,v_company,'REVERSE_OPEN_CREDIT_ACTION',
      'TASK5-FIXTURE-'||v_fixture_operation,md5(v_fixture_operation::text),v_actor,
      jsonb_build_object('fixture',true,'creditItemId',v_credit_item));
    FOR v_allocation IN SELECT allocation.*
      FROM public.ar_open_item_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.credit_item_id=v_credit_item
        AND allocation.reversal_of_allocation_id IS NULL
        AND NOT EXISTS(SELECT 1 FROM public.ar_open_item_allocations reversal
          WHERE reversal.company_id=allocation.company_id
            AND reversal.reversal_of_allocation_id=allocation.id)
      ORDER BY allocation.created_at,allocation.id
    LOOP
      INSERT INTO public.ar_open_item_allocations(id,company_id,operation_id,
        debit_item_id,credit_item_id,allocated_amount,source_kind,source_id,
        reversal_of_allocation_id,effective_date,created_by)
      VALUES(gen_random_uuid(),v_company,v_fixture_operation,v_allocation.debit_item_id,
        v_allocation.credit_item_id,v_allocation.allocated_amount,'ALLOCATION_REVERSAL',
        gen_random_uuid(),v_allocation.id,v_today,v_actor);
    END LOOP;
    v_credit_residual:=(SELECT item.original_amount-private.ar5_item_allocated(
      v_company,item.id,NULL) FROM public.ar_open_item_registry item
      WHERE item.company_id=v_company AND item.id=v_credit_item);
    v_invoice_residual:=(SELECT item.original_amount-private.ar5_item_allocated(
      v_company,item.id,NULL) FROM public.ar_open_item_registry item
      WHERE item.company_id=v_company AND item.id=v_invoice_item);
    IF v_credit_residual<10 OR v_invoice_residual<10 THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: rollback fixture could not expose residual >= 10';
    END IF;

    -- Customer Balance is intentionally inactive in production at this gate.
    -- Activate it only inside this rolled-back fixture to prove generic code.
    PERFORM public.set_company_feature(
      v_company,'customer_balance_enabled',true,'{}'::jsonb);
    IF NOT EXISTS(SELECT 1 FROM public.customer_balance_company_policies policy
      WHERE policy.company_id=v_company AND policy.lifecycle_state='ACTIVE') THEN
      RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Customer Balance fixture activation failed';
    END IF;
    v_phase:='FIXTURE_CUSTOMER_BALANCE_PERMISSION';
    PERFORM private.acp_require_permission_capability(
      v_company,'finance.customer_balances','MANAGE');
    SELECT current_balance INTO v_balance_before FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=v_customer FOR UPDATE;
    SELECT jsonb_build_object('sales',(SELECT count(*) FROM public.sales_headers),
      'stock',(SELECT count(*) FROM public.stock_movements),
      'fifo',(SELECT count(*) FROM public.sale_fifo_allocations)) INTO v_counts_before;

    v_phase:='DIRECT_APPLY_AND_REVERSAL';
    SELECT item.id INTO v_other_invoice_item FROM public.ar_open_item_registry item
    WHERE item.company_id=v_company AND item.item_kind='INVOICE'
      AND item.direction='DEBIT' AND item.customer_id<>v_customer
    ORDER BY item.created_at,item.id LIMIT 1;
    IF v_other_invoice_item IS NOT NULL THEN
      v_failed:=false;
      BEGIN
        PERFORM public.apply_backoffice_ar_open_credit(v_credit_item,
          jsonb_build_array(jsonb_build_object('debitItemId',v_other_invoice_item,'amount',1)),
          v_today,v_credit_residual,gen_random_uuid());
      EXCEPTION WHEN OTHERS THEN
        v_failed:=SQLERRM='AR_OPEN_CREDIT_TARGET_INVOICE_INVALID';
      END;
      IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: cross-Customer allocation accepted'; END IF;
    END IF;
    v_operation:=gen_random_uuid();
    SELECT item.source_id INTO STRICT v_invoice_source
    FROM public.ar_open_item_registry item
    WHERE item.company_id=v_company AND item.id=v_invoice_item;
    IF v_parity_installed THEN
      v_invoice_credit_before:=private.ar4_backoffice_invoice_allocated_credit(
        v_company,v_invoice_source,NULL);
    END IF;
    v_result:=public.apply_backoffice_ar_open_credit(v_credit_item,
      jsonb_build_array(jsonb_build_object('debitItemId',v_invoice_item,'amount',1)),
      v_today,v_credit_residual,v_operation);
    IF v_parity_installed AND private.ar4_backoffice_invoice_allocated_credit(
        v_company,v_invoice_source,NULL)<>v_invoice_credit_before+1 THEN
      RAISE EXCEPTION 'TEST_FAILED: shared Invoice Credit consumer missed active allocation';
    END IF;
    v_retry:=public.apply_backoffice_ar_open_credit(v_credit_item,
      jsonb_build_array(jsonb_build_object('debitItemId',v_invoice_item,'amount',1)),
      v_today,v_credit_residual,v_operation);
    IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
      OR (v_retry->>'operationId')<>(v_result->>'operationId') THEN
      RAISE EXCEPTION 'TEST_FAILED: direct allocation exact retry invalid';
    END IF;
    v_failed:=false;
    BEGIN
      PERFORM public.apply_backoffice_ar_open_credit(v_credit_item,
        jsonb_build_array(jsonb_build_object('debitItemId',v_invoice_item,'amount',2)),
        v_today,v_credit_residual,v_operation);
    EXCEPTION WHEN OTHERS THEN
      v_failed:=SQLERRM='IDEMPOTENCY_PAYLOAD_CONFLICT';
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: changed retry accepted'; END IF;
    v_reverse:=public.reverse_backoffice_ar_open_credit_action(
      (v_result->>'operationId')::uuid,v_today,'Rollback behavior reversal',gen_random_uuid());
    IF (v_reverse->>'reversedOperationId')::uuid<>(v_result->>'operationId')::uuid
      OR (SELECT item.original_amount-private.ar5_item_allocated(v_company,item.id,NULL)
          FROM public.ar_open_item_registry item
          WHERE item.company_id=v_company AND item.id=v_credit_item)<>v_credit_residual
      THEN
      RAISE EXCEPTION 'TEST_FAILED: direct allocation reversal invalid';
    END IF;
    IF v_parity_installed AND private.ar4_backoffice_invoice_allocated_credit(
        v_company,v_invoice_source,NULL)<>v_invoice_credit_before THEN
      RAISE EXCEPTION 'TEST_FAILED: shared Invoice Credit consumer missed reversal';
    END IF;

    v_failed:=false;
    BEGIN
      PERFORM public.apply_backoffice_ar_open_credit(v_credit_item,
        jsonb_build_array(jsonb_build_object('debitItemId',v_invoice_item,'amount',1)),
        v_today,v_credit_residual-1,gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN
      v_failed:=SQLERRM='AR_OPEN_CREDIT_STALE_RESIDUAL';
    END;
    IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: stale Credit residual accepted'; END IF;

    v_phase:='CONVERT_AND_BALANCE_USE';
    v_result:=public.convert_backoffice_ar_open_credit_to_customer_balance(
      v_credit_item,3,v_today,'Rollback conversion',v_credit_residual,gen_random_uuid());
    v_credit_residual:=v_credit_residual-3;
    v_invoice_residual:=(SELECT item.original_amount-private.ar5_item_allocated(
      v_company,item.id,NULL) FROM public.ar_open_item_registry item
      WHERE item.company_id=v_company AND item.id=v_invoice_item);
    v_result:=public.apply_customer_balance_to_backoffice_invoice(v_invoice_item,1,
      v_today,'Rollback balance use',v_invoice_residual,v_balance_before+3,gen_random_uuid());
    SELECT current_balance INTO v_balance_after FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=v_customer;
    IF v_balance_after<>v_balance_before+2 THEN
      RAISE EXCEPTION 'TEST_FAILED: Customer Balance conversion/use delta invalid';
    END IF;

    v_phase:='REFUND_AND_REVERSAL';
    v_result:=public.refund_backoffice_ar_open_credit(v_credit_item,1,v_today,
      v_method,'TASK5-ROLLBACK','https://example.invalid/task5-rollback',
      'Rollback refund',v_credit_residual,gen_random_uuid());
    IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id=v_company AND journal.id=(v_result->>'journalId')::uuid
          AND journal.status='POSTED' AND journal.total_debit=1 AND journal.total_credit=1) THEN
      RAISE EXCEPTION 'TEST_FAILED: AR-native refund Journal invalid';
    END IF;
    v_reverse:=public.reverse_backoffice_ar_open_credit_action(
      (v_result->>'operationId')::uuid,v_today,'Rollback refund reversal',gen_random_uuid());
    IF NOT EXISTS(SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id=v_company AND journal.id=(v_reverse->>'journalId')::uuid
          AND journal.status='POSTED' AND journal.total_debit=1 AND journal.total_credit=1) THEN
      RAISE EXCEPTION 'TEST_FAILED: refund reversal Journal invalid';
    END IF;

    v_phase:='CROSS_COMPANY_AND_BOUNDARY';
    SELECT company.id INTO v_other_company FROM public.companies company
    JOIN public.company_sales_process_settings process ON process.company_id=company.id
      AND process.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
    WHERE company.status='ACTIVE' AND company.id<>v_company ORDER BY company.id LIMIT 1;
    IF v_other_company IS NOT NULL THEN
      PERFORM public.set_active_company_context(v_other_company,'BACKOFFICE');
      v_failed:=false;
      BEGIN
        PERFORM public.apply_backoffice_ar_open_credit(v_credit_item,
          jsonb_build_array(jsonb_build_object('debitItemId',v_invoice_item,'amount',1)),
          v_today,v_credit_residual,gen_random_uuid());
      EXCEPTION WHEN OTHERS THEN
        v_failed:=SQLERRM='AR_OPEN_CREDIT_NOT_FOUND';
      END;
      PERFORM public.set_active_company_context(v_company,'BACKOFFICE');
      IF NOT v_failed THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company action accepted'; END IF;
    END IF;
    SELECT jsonb_build_object('sales',(SELECT count(*) FROM public.sales_headers),
      'stock',(SELECT count(*) FROM public.stock_movements),
      'fifo',(SELECT count(*) FROM public.sale_fifo_allocations)) INTO v_counts_after;
    IF v_counts_after<>v_counts_before THEN
      RAISE EXCEPTION 'TEST_FAILED: AR actions changed Retail/Stock/FIFO rows';
    END IF;
    RAISE EXCEPTION 'BACKOFFICE_AR_TASK5_TEST_ROLLBACK' USING ERRCODE='P7701';
  EXCEPTION WHEN SQLSTATE 'P7701' THEN NULL;
  END;
  RAISE NOTICE 'backoffice_ar_open_credit_actions_behavior PASS: all fixture writes rolled back';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS v_error_context=PG_EXCEPTION_CONTEXT;
  RAISE EXCEPTION 'TEST_PHASE_FAILED [%]: %',v_phase,SQLERRM
    USING ERRCODE=SQLSTATE,
      DETAIL='Assertion tetap aktif; seluruh fixture dibatalkan oleh transaksi test. Context: '
        ||COALESCE(v_error_context,'');
END
$test$;

SELECT 'backoffice_ar_open_credit_actions_behavior' AS check_name,
  'PASS' AS status,0::bigint AS violation_rows,jsonb_build_object(
    'parityConsumerAssertions',EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261110130000'),'tested',ARRAY[
    'installed exact forward migration','authenticated Backoffice Finance actor',
    'historical or canonical local native Backoffice Credit Note fixture',
    'direct Credit Note allocation plus exact/changed retry','append-only direct allocation reversal',
    'stale residual and cross-Customer denial','open credit to Customer Balance conversion',
    'Customer Balance use only on Posted Invoice','AR-native Cash/Bank refund',
    'balanced refund and reversal Journals','cross-Company denial',
    'shared consumer parity when its migration is installed',
    'zero Retail/Stock/FIFO effect','all fixture writes rolled back']) AS details;
