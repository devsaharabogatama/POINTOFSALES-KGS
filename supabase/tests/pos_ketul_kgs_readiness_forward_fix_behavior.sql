-- Rollback-only KGS behavior for the Ketul readiness forward fix.
-- Reuses an authenticated OPEN KGS session and a positive-FIFO Sale product.
BEGIN;

DO $test$
DECLARE
  v_company UUID;
  v_actor UUID;
  v_store UUID;
  v_terminal UUID;
  v_warehouse UUID;
  v_session UUID;
  v_customer UUID;
  v_cash_method UUID;
  v_sale_product UUID;
  v_sale_product_uom UUID;
  v_ketul_product UUID;
  v_sale_price NUMERIC(20,4);
  v_ketul_qty NUMERIC(24,6):=2;
  v_ketul_unit_price NUMERIC(20,4):=1;
  v_ketul_total NUMERIC(20,4):=2;
  v_external_due NUMERIC(20,4);
  v_stock_before NUMERIC(24,6);
  v_stock_after NUMERIC(24,6);
  v_client_key UUID:=gen_random_uuid();
  v_posting_key UUID:=gen_random_uuid();
  v_payload JSONB;
  v_saved JSONB;
  v_posted JSONB;
  v_retry JSONB;
  v_readiness JSONB;
  v_sale UUID;
  v_intake UUID;
  v_event UUID;
  v_journal UUID;
  v_before_effects JSONB;
  v_after_effects JSONB;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20261031110000','20261101120000'))<>2 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact Ketul migration chain missing';
  END IF;
  IF to_regprocedure('public.get_pos_ketul_readiness()') IS NULL
    OR to_regprocedure('public.save_pos_sale_draft_with_ketul(jsonb)') IS NULL
    OR to_regprocedure('public.post_pos_sale_with_ketul(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Ketul runtime missing';
  END IF;

  SELECT company.id INTO STRICT v_company
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE company.id='d290f1ee-6c54-4b01-90e6-d701748f0851'::uuid
    AND company.company_code='KGS' AND company.status='ACTIVE'
    AND setting.active_mode='RETAIL_CONFIRM_INVOICE';

  SELECT session.cashier_id,session.id,session.store_id,session.pos_id,
    session.sales_warehouse_id
  INTO v_actor,v_session,v_store,v_terminal,v_warehouse
  FROM public.cashier_sessions session
  JOIN public.stores store ON store.company_id=session.company_id
    AND store.id=session.store_id AND store.status='ACTIVE'
  JOIN public.pos_terminals terminal ON terminal.company_id=session.company_id
    AND terminal.id=session.pos_id AND terminal.store_id=session.store_id
    AND terminal.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=session.company_id
    AND warehouse.id=session.sales_warehouse_id AND warehouse.is_active
    AND warehouse.is_sale_source
  WHERE session.company_id=v_company
    AND session.status='OPEN'::public.session_status
    AND EXISTS(SELECT 1 FROM auth.users auth_user
      WHERE auth_user.id=session.cashier_id)
  ORDER BY public.private_is_super_admin(session.cashier_id) DESC,session.id
  LIMIT 1;
  IF v_session IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated OPEN KGS session required';
  END IF;

  SELECT customer.id INTO v_customer
  FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
  ORDER BY customer.is_system_customer DESC,customer.id LIMIT 1;
  SELECT method.id INTO v_cash_method
  FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.method_type='CASH'
  ORDER BY method.is_default DESC,method.id LIMIT 1;
  SELECT product.id INTO v_ketul_product
  FROM public.products product
  JOIN public.product_categories category
    ON category.company_id=product.company_id AND category.id=product.category_id
  WHERE product.company_id=v_company AND product.is_active
    AND NOT product.is_bundle AND category.is_active
    AND upper(btrim(category.category_name))='KETUL'
  ORDER BY product.sku,product.id LIMIT 1;

  WITH eligible_sale_uom AS MATERIALIZED (
    SELECT candidate.product_id,candidate.id
    FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active
      AND NOT product.is_bundle
    JOIN public.uoms unit ON unit.company_id=candidate.company_id
      AND unit.id=candidate.uom_id AND unit.is_active
    JOIN public.product_stocks stock ON stock.company_id=product.company_id
      AND stock.product_id=product.id AND stock.warehouse_id=v_warehouse
      AND stock.stock_qty>=candidate.factor_to_base
    LEFT JOIN public.product_categories category
      ON category.company_id=product.company_id AND category.id=product.category_id
    WHERE candidate.company_id=v_company AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0
      AND candidate.sale_price IS NOT NULL AND candidate.sale_price>=0
      AND COALESCE(upper(btrim(category.category_name)),'')<>'KETUL'
      AND (SELECT COALESCE(sum(batch.qty_remaining),0)
        FROM public.product_batches batch
        WHERE batch.company_id=v_company AND batch.product_id=product.id
          AND batch.warehouse_id=v_warehouse AND batch.qty_remaining>0)
        >=candidate.factor_to_base
  )
  SELECT candidate.product_id,candidate.id,
    (resolved.value->>'resolvedUnitPrice')::numeric
  INTO v_sale_product,v_sale_product_uom,v_sale_price
  FROM eligible_sale_uom candidate
  CROSS JOIN LATERAL (SELECT private.resolve_pos_sale_price(
    v_company,v_store,v_customer,candidate.id,1,clock_timestamp()) AS value) resolved
  WHERE (resolved.value->>'resolvedUnitPrice')::numeric>v_ketul_total
  ORDER BY candidate.id LIMIT 1;
  IF v_customer IS NULL OR v_cash_method IS NULL OR v_ketul_product IS NULL
    OR v_sale_product IS NULL OR v_sale_product_uom IS NULL OR v_sale_price IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: complete KGS Customer/Cash/Product tuple required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.accounting_periods period
      JOIN public.companies company ON company.id=period.company_id
      WHERE period.company_id=v_company AND period.status IN('OPEN','REOPENED')
        AND (clock_timestamp() AT TIME ZONE company.timezone)::date
          BETWEEN period.start_date AND period.end_date) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: current KGS accounting period must be open';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'KETUL_TEST');
  IF auth.uid() IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated actor context invalid';
  END IF;

  v_readiness:=public.get_pos_ketul_readiness();
  IF NOT COALESCE((v_readiness->>'enabled')::boolean,false)
    OR NOT COALESCE((v_readiness->>'ready')::boolean,false)
    OR v_readiness->>'blockerCode' IS NOT NULL
    OR (v_readiness->>'productCount')::integer<>4 THEN
    RAISE EXCEPTION 'TEST_FAILED: KGS readiness invalid: %',v_readiness;
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(
      public.get_pos_payment_method_references(v_store)) method
      WHERE method->>'method_type'='KETUL_OFFSET') THEN
    RAISE EXCEPTION 'TEST_FAILED: internal Ketul method leaked to normal picker';
  END IF;

  SELECT COALESCE(stock.stock_qty,0) INTO v_stock_before
  FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_ketul_product
    AND stock.warehouse_id=v_warehouse;
  v_stock_before:=COALESCE(v_stock_before,0);

  v_payload:=jsonb_build_object(
    'clientTransactionId',v_client_key,'cashierSessionId',v_session,
    'customerId',v_customer,'draftLabel','Rollback-only KGS Ketul readiness test',
    'draftNotes',NULL,'selectedPricelistId',NULL,'pricingSelectionSource','AUTO',
    'lines',jsonb_build_array(jsonb_build_object(
      'lineKey','KGS-KETUL-SALE-L1','productUomId',v_sale_product_uom,'quantity',1)),
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'isTempo',false,'transactionDateIntent','PRESERVE','dueDate',NULL,
    'fulfillmentMode','PICKUP','deliveryFeeAmount',0,
    'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE','payments','[]'::jsonb,
    'ketulIntakeLines',jsonb_build_array(jsonb_build_object(
      'productId',v_ketul_product,'quantity',v_ketul_qty,
      'unitPrice',v_ketul_unit_price))
  );
  v_saved:=public.save_pos_sale_draft_with_ketul(v_payload);
  v_sale:=(v_saved->>'salesId')::uuid;
  v_external_due:=(v_saved->>'grandTotalAfterRounding')::numeric-v_ketul_total;
  IF v_external_due<=0 OR (v_saved->>'ketulOffsetTotal')::numeric<>v_ketul_total THEN
    RAISE EXCEPTION 'TEST_FAILED: KGS Ketul Draft invalid: %',v_saved;
  END IF;
  SELECT intake.id INTO STRICT v_intake
  FROM public.pos_ketul_customer_intakes intake
  WHERE intake.company_id=v_company AND intake.sales_id=v_sale
    AND intake.status='DRAFT' AND intake.total_amount=v_ketul_total;

  v_payload:=v_payload||jsonb_build_object(
    'saleId',v_sale,'masterVersion',(v_saved->>'masterVersion')::bigint,
    'payments',jsonb_build_array(jsonb_build_object(
      'clientPaymentKey',gen_random_uuid(),'paymentMethodId',v_cash_method,
      'amount',v_external_due,'tenderedAmount',v_external_due))
  );
  v_saved:=public.save_pos_sale_draft_with_ketul(v_payload);
  v_posted:=public.post_pos_sale_with_ketul(
    v_sale,(v_saved->>'masterVersion')::bigint,v_posting_key);
  IF v_posted->>'documentStatus'<>'POSTED'
    OR (v_posted->>'ketulOffsetTotal')::numeric<>v_ketul_total THEN
    RAISE EXCEPTION 'TEST_FAILED: KGS Ketul post invalid: %',v_posted;
  END IF;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;

  SELECT intake.financial_event_id,intake.finance_journal_id
  INTO STRICT v_event,v_journal
  FROM public.pos_ketul_customer_intakes intake
  WHERE intake.company_id=v_company AND intake.id=v_intake
    AND intake.status='POSTED' AND intake.posting_idempotency_key=v_posting_key;
  SELECT stock.stock_qty INTO STRICT v_stock_after
  FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_ketul_product
    AND stock.warehouse_id=v_warehouse;
  IF v_stock_after<>v_stock_before+v_ketul_qty
    OR (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='pos_ketul_customer_intakes'
        AND movement.reference_id=v_intake AND movement.qty_change=v_ketul_qty
        AND movement.movement_status='POSTED')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: KGS Ketul Stock movement invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=v_company AND event.id=v_event
        AND event.source_table='pos_ketul_customer_intakes'
        AND event.source_id=v_intake AND event.status='POSTED')
    OR NOT EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=v_company AND journal.id=v_journal
        AND journal.financial_event_id=v_event AND journal.status='POSTED')
    OR (SELECT count(*) FROM public.finance_journal_lines line
      JOIN public.chart_of_accounts account
        ON account.company_id=line.company_id AND account.id=line.account_id
      WHERE line.company_id=v_company AND line.journal_id=v_journal
        AND ((account.account_code='1030100-4' AND line.debit=v_ketul_total
            AND line.credit=0)
          OR (account.account_code='2010105-1' AND line.debit=0
            AND line.credit=v_ketul_total)))<>2 THEN
    RAISE EXCEPTION 'TEST_FAILED: KGS Ketul Finance Event/Journal invalid';
  END IF;
  IF (SELECT count(*) FROM public.sales_payments payment
      WHERE payment.company_id=v_company AND payment.sales_id=v_sale
        AND payment.payment_method_type_snapshot='KETUL_OFFSET'
        AND payment.amount=v_ketul_total
        AND payment.settlement_account_function_snapshot='CUSTOMER_KETUL_PAYABLE')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: KGS hidden Ketul settlement invalid';
  END IF;

  SELECT jsonb_build_object(
    'intakes',(SELECT count(*) FROM public.pos_ketul_customer_intakes
      WHERE company_id=v_company AND sales_id=v_sale),
    'movements',(SELECT count(*) FROM public.stock_movements
      WHERE company_id=v_company AND reference_table='pos_ketul_customer_intakes'
        AND reference_id=v_intake),
    'events',(SELECT count(*) FROM public.financial_events
      WHERE company_id=v_company AND source_table='pos_ketul_customer_intakes'
        AND source_id=v_intake),
    'journals',(SELECT count(*) FROM public.finance_journals
      WHERE company_id=v_company AND source_type='pos_ketul_customer_intakes'
        AND source_id=v_intake)) INTO v_before_effects;
  v_retry:=public.post_pos_sale_with_ketul(
    v_sale,(SELECT master_version FROM public.sales_headers
      WHERE company_id=v_company AND id=v_sale),v_posting_key);
  SELECT jsonb_build_object(
    'intakes',(SELECT count(*) FROM public.pos_ketul_customer_intakes
      WHERE company_id=v_company AND sales_id=v_sale),
    'movements',(SELECT count(*) FROM public.stock_movements
      WHERE company_id=v_company AND reference_table='pos_ketul_customer_intakes'
        AND reference_id=v_intake),
    'events',(SELECT count(*) FROM public.financial_events
      WHERE company_id=v_company AND source_table='pos_ketul_customer_intakes'
        AND source_id=v_intake),
    'journals',(SELECT count(*) FROM public.finance_journals
      WHERE company_id=v_company AND source_type='pos_ketul_customer_intakes'
        AND source_id=v_intake)) INTO v_after_effects;
  IF NOT COALESCE((v_retry->>'idempotentReplay')::boolean,false)
    OR v_before_effects<>v_after_effects THEN
    RAISE EXCEPTION 'TEST_FAILED: KGS exact retry duplicated effects';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'pos_ketul_kgs_readiness_forward_fix_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'installed exact forward chain','authenticated KGS OPEN session',
    'KGS server readiness true','internal method hidden from normal picker',
    'linked KGS Retail Ketul Draft and post','positive-FIFO Sale source',
    'Ketul Stock inbound','Dr Inventory and Cr Ketul Payable Journal',
    'hidden Ketul settlement leg','exact retry idempotency',
    'all test effects rolled back')) details;
