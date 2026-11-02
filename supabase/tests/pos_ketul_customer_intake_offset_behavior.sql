-- Rollback-only behavior test for KGFF direct Retail POS Ketul intake.
-- Uses current KGFF masters, reuses an authenticated actor's exact OPEN KGFF
-- session when available (otherwise creates a collision-safe fixture session),
-- creates sale/stock fixtures, and rolls every business effect back. Run only
-- after migration 20261031110000.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_actor uuid;v_store uuid;v_terminal uuid;v_warehouse uuid;
  v_customer uuid;v_sale_product uuid;v_sale_product_uom uuid;v_sale_uom uuid;
  v_ketul_product uuid;v_cash_method uuid;v_session uuid;
  v_fixture_session uuid:=gen_random_uuid();v_reused_session boolean:=false;
  v_batch uuid:=gen_random_uuid();v_fixture_movement uuid:=gen_random_uuid();
  v_client_key uuid:=gen_random_uuid();v_posting_key uuid:=gen_random_uuid();
  v_payload jsonb;v_saved jsonb;v_posted jsonb;v_retry jsonb;
  v_sale uuid;v_intake uuid;v_journal uuid;v_event uuid;
  v_sale_price numeric(20,4);v_external_due numeric(20,4);
  v_ketul_qty numeric(24,6):=3;v_ketul_unit_price numeric(20,4):=1;
  v_ketul_total numeric(20,4):=3;v_stock_before numeric(24,6);
  v_stock_after numeric(24,6);v_sale_stock numeric(24,6);
  v_timezone text;v_today date;v_period uuid;v_rejected boolean;
  v_before_effects jsonb;v_after_effects jsonb;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version='20261031110000')<>1 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Ketul migration missing';
  END IF;
  IF to_regprocedure('public.save_pos_sale_draft_with_ketul(jsonb)') IS NULL
    OR to_regprocedure(
      'public.post_pos_sale_with_ketul(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Ketul RPC missing';
  END IF;

  SELECT company.id,company.timezone INTO STRICT v_company,v_timezone
  FROM public.companies company
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=company.id
  WHERE company.company_code='KGFF' AND company.status='ACTIVE'
    AND setting.active_mode='RETAIL_CONFIRM_INVOICE';
  SELECT session.cashier_id,session.id,session.store_id,session.pos_id,
    session.sales_warehouse_id
  INTO v_actor,v_session,v_store,v_terminal,v_warehouse
  FROM public.cashier_sessions session
  JOIN public.profiles profile ON profile.id=session.cashier_id
  JOIN public.stores store ON store.company_id=session.company_id
    AND store.id=session.store_id AND store.status='ACTIVE'
  JOIN public.pos_terminals terminal ON terminal.company_id=session.company_id
    AND terminal.id=session.pos_id AND terminal.store_id=session.store_id
    AND terminal.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=session.company_id
    AND warehouse.id=session.sales_warehouse_id AND warehouse.is_active
    AND warehouse.is_sale_source
    AND (warehouse.store_id=session.store_id OR warehouse.store_id IS NULL)
  WHERE session.company_id=v_company
    AND session.status='OPEN'::public.session_status
    AND EXISTS(SELECT 1 FROM auth.users auth_user
      WHERE auth_user.id=session.cashier_id)
  ORDER BY public.private_is_super_admin(session.cashier_id) DESC,session.id
  LIMIT 1;
  v_reused_session:=FOUND;
  IF NOT v_reused_session THEN
    SELECT store.id INTO v_store FROM public.stores store
    WHERE store.company_id=v_company AND store.status='ACTIVE'
    ORDER BY store.id LIMIT 1;
    SELECT terminal.id INTO v_terminal FROM public.pos_terminals terminal
    WHERE terminal.company_id=v_company AND terminal.store_id=v_store
      AND terminal.status='ACTIVE' ORDER BY terminal.id LIMIT 1;
    SELECT warehouse.id INTO v_warehouse FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.is_active
      AND warehouse.is_sale_source
      AND (warehouse.store_id=v_store OR warehouse.store_id IS NULL)
    ORDER BY (warehouse.store_id=v_store) DESC,warehouse.id LIMIT 1;
    SELECT profile.id INTO STRICT v_actor
    FROM public.profiles profile
    WHERE EXISTS(SELECT 1 FROM auth.users auth_user WHERE auth_user.id=profile.id)
      AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions open_session
        WHERE open_session.cashier_id=profile.id
          AND open_session.status='OPEN'::public.session_status)
      AND (public.private_is_super_admin(profile.id)
        OR EXISTS(SELECT 1 FROM public.company_memberships membership
          WHERE membership.company_id=v_company AND membership.user_id=profile.id
            AND membership.status='ACTIVE'
            AND membership.role_code IN('COMPANY_OWNER','COMPANY_ADMIN'))
        OR EXISTS(SELECT 1 FROM public.store_memberships membership
          WHERE membership.company_id=v_company AND membership.store_id=v_store
            AND membership.user_id=profile.id AND membership.status='ACTIVE'
            AND membership.role_code IN('CASHIER','STORE_MANAGER')))
    ORDER BY public.private_is_super_admin(profile.id) DESC,profile.id LIMIT 1;
    v_session:=v_fixture_session;
  END IF;
  SELECT customer.id INTO v_customer FROM public.customers customer
  WHERE customer.company_id=v_company AND customer.is_active
  ORDER BY customer.is_system_customer DESC,customer.id LIMIT 1;
  SELECT method.id INTO v_cash_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.method_type='CASH' ORDER BY method.is_default DESC,method.id LIMIT 1;
  SELECT product.id INTO v_ketul_product
  FROM public.products product
  JOIN public.product_categories category
    ON category.company_id=product.company_id AND category.id=product.category_id
  WHERE product.company_id=v_company AND product.is_active AND NOT product.is_bundle
    AND category.is_active AND upper(btrim(category.category_name))='KETUL'
  ORDER BY product.sku,product.id LIMIT 1;
  WITH eligible_sale_uom AS MATERIALIZED (
    SELECT candidate.product_id,candidate.id,product.uom_id AS base_uom_id
    FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active
      AND NOT product.is_bundle
    JOIN public.uoms unit ON unit.company_id=candidate.company_id
      AND unit.id=candidate.uom_id AND unit.is_active
    LEFT JOIN public.product_categories category
      ON category.company_id=product.company_id AND category.id=product.category_id
    WHERE candidate.company_id=v_company AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0
      AND candidate.sale_price IS NOT NULL AND candidate.sale_price>=0
      AND COALESCE(upper(btrim(category.category_name)),'')<>'KETUL'
  )
  SELECT candidate.product_id,candidate.id,candidate.base_uom_id,
    (resolved.value->>'resolvedUnitPrice')::numeric
  INTO v_sale_product,v_sale_product_uom,v_sale_uom,v_sale_price
  FROM eligible_sale_uom candidate
  CROSS JOIN LATERAL (SELECT private.resolve_pos_sale_price(
    v_company,v_store,v_customer,candidate.id,1,clock_timestamp()) AS value) resolved
  WHERE (resolved.value->>'resolvedUnitPrice')::numeric>v_ketul_total
  ORDER BY candidate.id LIMIT 1;

  IF v_store IS NULL OR v_terminal IS NULL OR v_warehouse IS NULL
    OR v_customer IS NULL OR v_cash_method IS NULL OR v_ketul_product IS NULL
    OR v_sale_product IS NULL OR v_sale_product_uom IS NULL OR v_sale_price IS NULL THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: complete KGFF Store/Terminal/Warehouse/Customer/Cash/Product tuple required';
  END IF;

  IF NOT EXISTS(SELECT 1 FROM public.company_features feature
      WHERE feature.company_id=v_company AND feature.feature_code='ketul_enabled'
        AND feature.is_enabled) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: KGFF Ketul entitlement missing';
  END IF;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  IF auth.uid() IS DISTINCT FROM v_actor THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: authenticated actor context invalid';
  END IF;
  PERFORM public.set_active_company_context(v_company,'KETUL_TEST');

  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::date;
  SELECT period.id INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company
    AND v_today BETWEEN period.start_date AND period.end_date
  ORDER BY period.start_date DESC LIMIT 1 FOR UPDATE;
  IF v_period IS NULL THEN
    INSERT INTO public.accounting_periods(company_id,period_year,period_month,
      start_date,end_date,status,created_by,updated_by)
    VALUES(v_company,extract(year FROM v_today)::integer,
      extract(month FROM v_today)::integer,date_trunc('month',v_today)::date,
      (date_trunc('month',v_today)+interval '1 month'-interval '1 day')::date,
      'OPEN',v_actor,v_actor) RETURNING id INTO v_period;
  ELSIF (SELECT status FROM public.accounting_periods WHERE id=v_period)='LOCKED' THEN
    UPDATE public.accounting_periods SET status='REOPENED',
      closed_by=COALESCE(closed_by,v_actor),
      closed_at=COALESCE(closed_at,clock_timestamp()),reopened_by=v_actor,
      reopened_at=clock_timestamp(),
      reopen_reason='Rollback-only Ketul behavior fixture',updated_by=v_actor
    WHERE company_id=v_company AND id=v_period;
  END IF;

  SELECT COALESCE(stock.stock_qty,0) INTO v_sale_stock
  FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_sale_product
    AND stock.warehouse_id=v_warehouse;
  v_sale_stock:=COALESCE(v_sale_stock,0)+10;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_sale_product,v_warehouse,10,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,
    updated_at=clock_timestamp()
  RETURNING stock_qty INTO v_sale_stock;
  INSERT INTO public.product_batches(id,product_id,warehouse_id,purchase_detail_id,
    qty_purchased,qty_remaining,cogs_unit,company_id)
  VALUES(v_batch,v_sale_product,v_warehouse,NULL,10,10,1,v_company);
  INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
    movement_type,reference_table,reference_id,company_id,base_uom_id,
    base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
    movement_status,source_line_id,notes)
  SELECT v_fixture_movement,v_sale_product,v_warehouse,10,
    'PURCHASE'::public.stock_movement_type,'POS_KETUL_TEST',v_batch,v_company,
    product.uom_id,uom.name,v_sale_stock,v_actor,clock_timestamp(),'POSTED',
    v_batch,'Rollback-only Ketul sale-stock fixture'
  FROM public.products product JOIN public.uoms uom
    ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE product.company_id=v_company AND product.id=v_sale_product;

  SELECT COALESCE(stock.stock_qty,0) INTO v_stock_before
  FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_ketul_product
    AND stock.warehouse_id=v_warehouse;
  v_stock_before:=COALESCE(v_stock_before,0);
  IF NOT v_reused_session THEN
    INSERT INTO public.cashier_sessions(id,session_code,cashier_id,opening_balance,
      expected_cash,actual_cash,difference,status,company_id,store_id,pos_id,
      sales_warehouse_id,opening_cash_actual,master_version,updated_at)
    VALUES(v_session,'TST-KETUL-'||substr(replace(v_session::text,'-',''),1,12),
      v_actor,0,0,0,0,'OPEN'::public.session_status,v_company,v_store,v_terminal,
      v_warehouse,0,1,clock_timestamp());
  END IF;

  v_payload:=jsonb_build_object('clientTransactionId',v_client_key,
    'cashierSessionId',v_session,'customerId',v_customer,
    'draftLabel','Rollback-only Ketul behavior test','draftNotes',NULL,
    'selectedPricelistId',NULL,'pricingSelectionSource','AUTO',
    'lines',jsonb_build_array(jsonb_build_object('lineKey','KETUL-SALE-L1',
      'productUomId',v_sale_product_uom,'quantity',1)),
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'isTempo',false,'transactionDateIntent','PRESERVE','dueDate',NULL,
    'fulfillmentMode','PICKUP','deliveryFeeAmount',0,
    'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE','payments','[]'::jsonb,
    'ketulIntakeLines',jsonb_build_array(
      jsonb_build_object('productId',v_ketul_product,'quantity',1,
        'unitPrice',v_ketul_unit_price),
      jsonb_build_object('productId',v_ketul_product,'quantity',2,
        'unitPrice',v_ketul_unit_price)));

  v_rejected:=false;
  BEGIN
    PERFORM public.save_pos_sale_draft_with_ketul(v_payload||jsonb_build_object(
      'clientTransactionId',gen_random_uuid(),
      'ketulIntakeLines',jsonb_build_array(jsonb_build_object(
        'productId',v_ketul_product,'quantity',3,
        'unitPrice',v_sale_price+1))));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='KETUL_OFFSET_EXCEEDS_SALE_TOTAL' THEN v_rejected:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Ketul offset above Sale total accepted';
  END IF;

  v_saved:=public.save_pos_sale_draft_with_ketul(v_payload);
  v_sale:=(v_saved->>'salesId')::uuid;
  v_external_due:=(v_saved->>'grandTotalAfterRounding')::numeric-v_ketul_total;
  IF v_external_due<=0
    OR (v_saved->>'grandTotalAfterRounding')::numeric<>v_sale_price
    OR (v_saved->>'ketulOffsetTotal')::numeric<>v_ketul_total
    OR (v_saved->>'ketulLineCount')::integer<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: initial Ketul Draft invalid: %',v_saved;
  END IF;
  SELECT intake.id INTO STRICT v_intake
  FROM public.pos_ketul_customer_intakes intake
  WHERE intake.company_id=v_company AND intake.sales_id=v_sale
    AND intake.status='DRAFT' AND intake.total_amount=v_ketul_total;
  IF (SELECT count(*) FROM public.pos_ketul_customer_intake_lines line
      WHERE line.company_id=v_company AND line.intake_id=v_intake
        AND line.product_id=v_ketul_product AND line.quantity_base=v_ketul_qty
        AND line.unit_price=v_ketul_unit_price)<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: duplicate Ketul rows were not merged';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='pos_ketul_customer_intakes'
        AND movement.reference_id=v_intake) THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft Ketul changed Stock';
  END IF;

  v_payload:=v_payload||jsonb_build_object('saleId',v_sale,
    'masterVersion',(v_saved->>'masterVersion')::bigint,
    'payments',jsonb_build_array(jsonb_build_object(
      'clientPaymentKey',gen_random_uuid(),'paymentMethodId',v_cash_method,
      'amount',v_external_due,'tenderedAmount',v_external_due)));
  v_saved:=public.save_pos_sale_draft_with_ketul(v_payload);

  v_rejected:=false;
  BEGIN
    PERFORM public.post_pos_sale_with_ketul(v_sale,
      (v_saved->>'masterVersion')::bigint-1,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%STALE%' OR SQLERRM LIKE '%VERSION%' THEN
      v_rejected:=true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: stale Sale version accepted';
  END IF;

  v_posted:=public.post_pos_sale_with_ketul(v_sale,
    (v_saved->>'masterVersion')::bigint,v_posting_key);
  IF v_posted->>'documentStatus'<>'POSTED'
    OR COALESCE((v_posted->>'idempotentReplay')::boolean,false)
    OR (v_posted->>'ketulOffsetTotal')::numeric<>v_ketul_total THEN
    RAISE EXCEPTION 'TEST_FAILED: Ketul post did not finalize: %',v_posted;
  END IF;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;

  SELECT intake.financial_event_id,intake.finance_journal_id
  INTO STRICT v_event,v_journal
  FROM public.pos_ketul_customer_intakes intake
  WHERE intake.company_id=v_company AND intake.id=v_intake AND intake.status='POSTED'
    AND intake.posting_idempotency_key=v_posting_key;
  SELECT stock.stock_qty INTO STRICT v_stock_after FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_ketul_product
    AND stock.warehouse_id=v_warehouse;
  IF v_stock_after<>v_stock_before+v_ketul_qty
    OR (SELECT count(*) FROM public.product_batches batch
      WHERE batch.company_id=v_company AND batch.product_id=v_ketul_product
        AND batch.warehouse_id=v_warehouse AND batch.qty_purchased=v_ketul_qty
        AND batch.qty_remaining=v_ketul_qty
        AND batch.cogs_unit=v_ketul_unit_price)<>1
    OR (SELECT count(*) FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='pos_ketul_customer_intakes'
        AND movement.reference_id=v_intake AND movement.qty_change=v_ketul_qty
        AND movement.movement_status='POSTED')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Ketul Stock/FIFO inbound invalid';
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
    RAISE EXCEPTION 'TEST_FAILED: Ketul Finance Event/Journal invalid';
  END IF;
  IF (SELECT count(*) FROM public.sales_payments payment
      WHERE payment.company_id=v_company AND payment.sales_id=v_sale
        AND payment.payment_method_type_snapshot='KETUL_OFFSET'
        AND payment.amount=v_ketul_total
        AND payment.settlement_account_function_snapshot='CUSTOMER_KETUL_PAYABLE')<>1
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_sale
        AND sale.receipt_snapshot->'ketulIntake' IS NOT NULL
        AND (sale.receipt_snapshot->>'ketulOffsetTotal')::numeric=v_ketul_total
        AND (sale.receipt_snapshot->>'externalPaymentTotal')::numeric=v_external_due) THEN
    RAISE EXCEPTION 'TEST_FAILED: Ketul settlement/receipt contract invalid';
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
  v_retry:=public.post_pos_sale_with_ketul(v_sale,
    (SELECT master_version FROM public.sales_headers
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
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated Ketul effects';
  END IF;

  v_rejected:=false;
  BEGIN
    PERFORM public.save_pos_sale_draft_with_ketul(
      (v_payload-'saleId'-'masterVersion')
      ||jsonb_build_object('clientTransactionId',gen_random_uuid(),
        'isTempo',true,'dueDate',clock_timestamp()+interval '7 days',
        'payments','[]'::jsonb));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='KETUL_OFFSET_TEMPO_NOT_SUPPORTED' THEN v_rejected:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Tempo accepted Ketul intake';
  END IF;

  v_saved:=public.save_pos_sale_draft_with_ketul(
    (v_payload-'saleId'-'masterVersion'-'ketulIntakeLines')
    ||jsonb_build_object('clientTransactionId',gen_random_uuid(),
      'payments','[]'::jsonb,'ketulIntakeLines','[]'::jsonb));
  IF EXISTS(SELECT 1 FROM public.pos_ketul_customer_intakes intake
      WHERE intake.company_id=v_company
        AND intake.sales_id=(v_saved->>'salesId')::uuid) THEN
    RAISE EXCEPTION 'TEST_FAILED: non-Ketul Draft created Ketul intake';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'pos_ketul_customer_intake_offset_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'installed exact forward migration','authenticated KGFF Company scope',
    'OPEN KGFF session reuse or collision-safe fixture creation',
    'Direct Retail POS save with repeated Ketul rows merged server-side',
    'Ketul offset cannot exceed Sale total and does not reduce stored Sale total',
    'stale version rejected','atomic Sale plus Ketul post',
    'Ketul Stock and FIFO inbound','two-line Ketul Finance Journal',
    'hidden Ketul settlement leg and receipt snapshot','exact retry idempotency',
    'Tempo rejected','non-Ketul wrapper delegation',
    'all test effects rolled back')) details;
