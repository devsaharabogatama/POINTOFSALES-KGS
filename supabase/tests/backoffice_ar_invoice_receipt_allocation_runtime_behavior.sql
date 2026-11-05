-- Rollback-only behavior for Backoffice AR Task 3.
BEGIN;

DO $test$
DECLARE v_candidate record;v_actor uuid;v_company uuid;v_invoice uuid;v_customer uuid;
  v_method uuid;v_receipt_date date;v_invoice_item uuid;v_saved jsonb;v_posted jsonb;
  v_retry jsonb;v_receipt uuid;v_receipt_item uuid;v_journal uuid;v_before_used numeric;
  v_after_used numeric;v_credit_used numeric;v_operation uuid:=gen_random_uuid();
  v_invoice_payment jsonb;v_invoice_payment_retry jsonb;v_invoice_payment_receipt uuid;
  v_rejected boolean:=false;v_open_items jsonb;v_counts_before jsonb;v_counts_after jsonb;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261105110000')
    OR to_regprocedure('public.save_customer_receipt_open_credit_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20261105110000 must be installed';
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
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Backoffice Finance actor, open Invoice >= 4, payment method and open period required';
  END IF;

  SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_before_used
  FROM public.ar_open_item_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.debit_item_id=v_invoice_item;

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
    'partial Invoice allocation plus Customer-scoped residual open credit',
    'single full Cash/Bank-to-AR Journal','append-only Receipt and allocation registration',
    'read RPC residual visibility','exact retry idempotency','changed retry denial',
    'Invoice detail payment entry-point wrapper binding','zero Retail/Stock/FIFO effect',
    'all test writes rolled back']) AS details;
ROLLBACK;
