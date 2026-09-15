-- Step 4B/6 rollback-only Retail -> Backoffice converter behavior.
-- Creates its own canonical Retail Draft; no operational document is borrowed.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000111004',
  'cutover-retail-backoffice@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Cutover Retail Backoffice Test"}'::jsonb,
  false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000111004',
  'cutover-retail-backoffice@example.invalid',
  'Cutover Retail Backoffice Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE
  v_actor uuid:='00000000-0000-0000-0000-000000111004';
  v_company uuid;v_store uuid;v_pos uuid;v_warehouse uuid;v_customer uuid;
  v_timezone text;
  v_today date;v_period_id uuid;
  v_product uuid;v_product_uom uuid;v_factor numeric;
  v_session uuid:=gen_random_uuid();v_sale_id uuid;v_fixture_stock numeric;
  v_scheduled_sale_id uuid;v_scheduled_target uuid;v_future_date date;
  v_future_at timestamptz;
  v_reserved_sale_id uuid;v_reserved_target uuid;v_reserved_version bigint;
  v_payload jsonb;v_saved jsonb;v_result jsonb;v_target uuid;v_source_total numeric;
  v_target_total numeric;v_stock_before numeric;v_stock_after numeric;
  v_event_before bigint;v_event_after bigint;v_journal_before bigint;v_journal_after bigint;
  v_movement_before bigint;v_movement_after bigint;v_fifo_before bigint;v_fifo_after bigint;
  v_operation uuid:=gen_random_uuid();v_retry jsonb;
  v_conflict_rejected boolean:=false;
BEGIN
  SELECT company.id,store.id,terminal.id,warehouse.id,customer.id,
    product_uom.product_id,product_uom.id,product_uom.factor_to_base,company.timezone
  INTO v_company,v_store,v_pos,v_warehouse,v_customer,v_product,v_product_uom,
    v_factor,v_timezone
  FROM public.companies company
  JOIN LATERAL(SELECT candidate.* FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
  JOIN LATERAL(SELECT candidate.* FROM public.pos_terminals candidate
    WHERE candidate.company_id=company.id AND candidate.store_id=store.id
      AND candidate.status='ACTIVE' ORDER BY candidate.id LIMIT 1) terminal ON true
  JOIN LATERAL(SELECT candidate.* FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.is_sale_source
      AND (candidate.store_id=store.id OR candidate.store_id IS NULL)
    ORDER BY (candidate.store_id=store.id) DESC,candidate.id LIMIT 1) warehouse ON true
  JOIN LATERAL(SELECT candidate.* FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1) customer ON true
  JOIN LATERAL(SELECT candidate.id,candidate.product_id,candidate.factor_to_base
    FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms uom ON uom.company_id=candidate.company_id
      AND uom.id=candidate.uom_id AND uom.is_active
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0
      AND candidate.sale_price>0
      AND (private.resolve_pos_sale_price(company.id,store.id,customer.id,
        candidate.id,1,clock_timestamp())->>'resolvedUnitPrice')::numeric>0
    ORDER BY candidate.id LIMIT 1) product_uom ON true
  WHERE company.status='ACTIVE'
  ORDER BY company.id LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active canonical Company/Store/Terminal/Warehouse/Customer/Product-UOM tuple required';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'CUTOVER_TEST');
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET
    is_enabled=true,config=excluded.config,updated_by=excluded.updated_by;

  -- A confirmed Retail fixture must be TEMPO: a non-TEMPO confirmation requires
  -- payment intents, while any payment request correctly makes a cutover source
  -- ineligible. Make only the current period postable inside this rollback-only
  -- test instead of assuming the Development database already has one open.
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::date;
  SELECT period.id INTO v_period_id
  FROM public.accounting_periods period
  WHERE period.company_id=v_company
    AND v_today BETWEEN period.start_date AND period.end_date
  ORDER BY period.id LIMIT 1 FOR UPDATE;
  IF v_period_id IS NULL THEN
    INSERT INTO public.accounting_periods(company_id,period_year,period_month,
      start_date,end_date,status,created_by,updated_by)
    VALUES(v_company,extract(year FROM v_today)::integer,
      extract(month FROM v_today)::integer,date_trunc('month',v_today)::date,
      (date_trunc('month',v_today)+interval '1 month'-interval '1 day')::date,
      'OPEN',v_actor,v_actor)
    RETURNING id INTO v_period_id;
  ELSE
    UPDATE public.accounting_periods SET status='REOPENED',
      closed_by=COALESCE(closed_by,v_actor),
      closed_at=COALESCE(closed_at,clock_timestamp()),
      reopened_by=v_actor,reopened_at=clock_timestamp(),
      reopen_reason='Rollback-only cutover converter behavior fixture',
      updated_by=v_actor
    WHERE company_id=v_company AND id=v_period_id AND status='LOCKED';
  END IF;

  -- Ensure this rollback-only fixture has deterministic headroom after every
  -- pre-existing Retail and Backoffice reservation. This prevents canonical
  -- Retail confirmation from legitimately opening procurement and changing
  -- the scenario being tested; no Stock Movement is fabricated.
  SELECT GREATEST(0,
    COALESCE((SELECT sum(line.reserved_base_qty-line.released_base_qty-
      line.dispatched_base_qty)
      FROM public.sales_stock_reservation_lines line
      JOIN public.sales_stock_reservations reservation
        ON reservation.company_id=line.company_id
       AND reservation.id=line.reservation_id
      WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
        AND line.stock_product_id=v_product
        AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')),0)
    +COALESCE((SELECT sum(line.reserved_base_qty-line.released_base_qty-
      line.in_transit_base_qty-line.completed_base_qty)
      FROM public.backoffice_sales_reservation_lines line
      JOIN public.backoffice_sales_reservations reservation
        ON reservation.company_id=line.company_id
       AND reservation.id=line.reservation_id
      WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
        AND line.product_id=v_product AND reservation.status<>'RELEASED'),0)
    )+10*v_factor INTO v_fixture_stock;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_product,v_warehouse,v_fixture_stock,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=excluded.stock_qty,updated_at=clock_timestamp();

  INSERT INTO public.cashier_sessions(id,session_code,cashier_id,opening_balance,
    expected_cash,actual_cash,difference,status,company_id,store_id,pos_id,
    sales_warehouse_id,opening_cash_actual,master_version,updated_at)
  VALUES(v_session,'TST-CUT-'||substr(replace(v_session::text,'-',''),1,12),
    v_actor,0,0,0,0,'OPEN'::public.session_status,v_company,v_store,v_pos,
    v_warehouse,0,1,clock_timestamp());

  v_payload:=jsonb_build_object('clientTransactionId',gen_random_uuid(),
    'cashierSessionId',v_session,'customerId',v_customer,
    'draftLabel','Rollback-only Retail cutover test','selectedPricelistId',NULL,
    'pricingSelectionSource','AUTO','lines',jsonb_build_array(jsonb_build_object(
      'lineKey','CUTOVER-RETAIL-L1','productUomId',v_product_uom,'quantity',2,
      'lineDiscountType','PERCENT','lineDiscountInput',5)),
    'globalDiscount',100,'roundingDirection','NONE','roundingIncrement',100,
    'isTempo',false,'transactionDateIntent','PRESERVE','dueDate',NULL,
    'fulfillmentMode','DELIVERY','deliveryRecipientName','Cutover Test',
    'deliveryRecipientPhone',NULL,'deliveryAddress',NULL,
    'deliveryScheduledAt',NULL,'deliveryNotes',NULL,'deliveryFeeAmount',250,
    'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE','payments','[]'::jsonb);
  v_saved:=public.save_pos_sale_draft_with_pricelist(v_payload);
  v_sale_id:=(v_saved->>'salesId')::uuid;
  SELECT grand_total_after_rounding INTO STRICT v_source_total
  FROM public.sales_headers WHERE company_id=v_company AND id=v_sale_id;

  SELECT COALESCE(sum(stock_qty),0) INTO v_stock_before FROM public.product_stocks
    WHERE company_id=v_company;
  SELECT count(*) INTO v_event_before FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_journal_before FROM public.journal_entries WHERE company_id=v_company;
  SELECT count(*) INTO v_movement_before FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_fifo_before FROM public.sale_fifo_allocations WHERE company_id=v_company;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  v_result:=private.convert_retail_sale_to_backoffice_order(
    v_company,v_sale_id,v_actor,v_operation);
  v_retry:=private.convert_retail_sale_to_backoffice_order(
    v_company,v_sale_id,v_actor,v_operation);
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  v_target:=(v_result->>'targetDocumentId')::uuid;

  IF v_target IS NULL OR v_result->>'targetStatus'<>'DRAFT'
    OR COALESCE((v_result->>'sourceClosed')::boolean,false) IS NOT TRUE
    OR COALESCE((v_result->>'commercialSnapshotPreserved')::boolean,false) IS NOT TRUE
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_sale_id
        AND sale.document_status='CANCELED' AND sale.order_runtime_status='CANCELED') THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft mapping or source retirement invalid: %',v_result;
  END IF;
  SELECT grand_total INTO STRICT v_target_total FROM public.backoffice_sales_orders
  WHERE company_id=v_company AND id=v_target;
  IF round(v_target_total,4) IS DISTINCT FROM round(v_source_total,4)
    OR (SELECT count(*) FROM public.backoffice_sales_order_lines
      WHERE company_id=v_company AND sales_order_id=v_target)<>1
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_reservations
      WHERE company_id=v_company AND sales_order_id=v_target) THEN
    RAISE EXCEPTION 'TEST_FAILED: target commercial/line/Draft fulfillment shape invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_details source
    LEFT JOIN public.backoffice_sales_order_lines target
      ON target.company_id=source.company_id AND target.sales_order_id=v_target
      AND target.product_id=source.product_id
      AND target.pricing_snapshot->>'productUomId'=source.product_uom_id::text
    WHERE source.company_id=v_company AND source.sales_id=v_sale_id
      AND (target.id IS NULL OR target.unit_price IS DISTINCT FROM source.price
        OR target.line_discount_amount IS DISTINCT FROM source.line_discount_amount
        OR target.allocated_order_discount_amount
          IS DISTINCT FROM source.allocated_order_discount_amount
        OR target.line_total IS DISTINCT FROM source.line_total
        OR target.tax_rule_id IS DISTINCT FROM source.tax_rule_id
        OR target.tax_rule_version IS DISTINCT FROM source.tax_rule_version
        OR target.tax_base IS DISTINCT FROM source.tax_base
        OR target.tax_amount IS DISTINCT FROM source.tax_amount
        OR target.tax_rounding IS DISTINCT FROM source.tax_rounding
        OR NULLIF(target.pricing_snapshot->>'pricelistId','')::uuid
          IS DISTINCT FROM source.pricelist_id
        OR NULLIF(target.pricing_snapshot->>'pricelistRuleId','')::uuid
          IS DISTINCT FROM source.pricelist_rule_id)) THEN
    RAISE EXCEPTION 'TEST_FAILED: Retail line commercial/tax snapshot drifted';
  END IF;
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
    OR (v_retry->>'targetDocumentId')::uuid IS DISTINCT FROM v_target THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry did not return original target: %',v_retry;
  END IF;

  -- Create a future Scheduled TEMPO Draft through the canonical public Save;
  -- no direct fixture shaping and no operational Draft are used.
  v_future_date:=(clock_timestamp() AT TIME ZONE v_timezone)::date+1;
  v_future_at:=(v_future_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  v_payload:=v_payload||jsonb_build_object('clientTransactionId',gen_random_uuid(),
    'draftLabel','Rollback-only Scheduled cutover test','isTempo',true,
    'transactionDateIntent','CASHIER_SELECTED','transactionAt',v_future_at,
    'dueDate',v_future_at+interval '14 days','deliveryScheduledAt',v_future_at);
  v_saved:=public.save_pos_sale_draft_with_pricelist(v_payload);
  v_scheduled_sale_id:=(v_saved->>'salesId')::uuid;
  IF v_saved->>'orderTimingMode'<>'SCHEDULED' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Scheduled fixture invalid: %',v_saved;
  END IF;
  BEGIN
    PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
    PERFORM private.convert_retail_sale_to_backoffice_order(
      v_company,v_scheduled_sale_id,v_actor,v_operation);
  EXCEPTION WHEN OTHERS THEN
    v_conflict_rejected:=SQLERRM='IDEMPOTENCY_PAYLOAD_CONFLICT';
  END;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  IF NOT v_conflict_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: operation UUID reuse for a different source was not rejected';
  END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  v_result:=private.convert_retail_sale_to_backoffice_order(
    v_company,v_scheduled_sale_id,v_actor,gen_random_uuid());
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  v_scheduled_target:=(v_result->>'targetDocumentId')::uuid;
  IF v_result->>'targetStatus'<>'DRAFT'
    OR COALESCE((v_result->>'reservationTransferred')::boolean,false) IS NOT FALSE
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=v_scheduled_target
        AND document.order_date=v_future_date
        AND document.planned_delivery_date=v_future_date)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company
        AND reservation.sales_order_id=v_scheduled_target)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=v_company
        AND delivery.sales_order_id=v_scheduled_target) THEN
    RAISE EXCEPTION 'TEST_FAILED: future Scheduled Draft mapping or date preservation invalid: %',v_result;
  END IF;

  -- Canonically confirm a separate immediate Retail source so cancellation/
  -- release of an existing Reservation, Delivery Document, and Invoice
  -- snapshot is covered without inheriting the future Scheduled date.
  v_payload:=(v_payload-'transactionAt'-'deliveryScheduledAt')
    ||jsonb_build_object('clientTransactionId',gen_random_uuid(),
      'draftLabel','Rollback-only Reserved cutover test','isTempo',true,
      'transactionDateIntent','PRESERVE',
      'dueDate',clock_timestamp()+interval '14 days');
  v_saved:=public.save_pos_sale_draft_with_pricelist(v_payload);
  v_reserved_sale_id:=(v_saved->>'salesId')::uuid;
  v_reserved_version:=(v_saved->>'masterVersion')::bigint;
  IF v_saved->>'orderTimingMode'<>'IMMEDIATE' THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical immediate Reserved fixture invalid: %',v_saved;
  END IF;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  PERFORM public.confirm_pos_sales_order(v_reserved_sale_id,v_reserved_version,
    gen_random_uuid(),NULL);
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  v_result:=private.convert_retail_sale_to_backoffice_order(
    v_company,v_reserved_sale_id,v_actor,gen_random_uuid());
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  v_reserved_target:=(v_result->>'targetDocumentId')::uuid;
  IF v_result->>'targetStatus'<>'CONFIRMED'
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_reserved_sale_id
        AND sale.order_runtime_status='CANCELED' AND sale.document_status='CANCELED')
    OR NOT EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_id=v_reserved_sale_id
        AND reservation.status='RELEASED')
    OR NOT EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=v_company AND delivery.sales_id=v_reserved_sale_id
        AND delivery.status='CANCELED')
    OR NOT EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_reserved_sale_id)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company
        AND reservation.sales_order_id=v_reserved_target) THEN
    RAISE EXCEPTION 'TEST_FAILED: Reserved source formal cancellation/target transfer invalid: %',v_result;
  END IF;
  SELECT COALESCE(sum(stock_qty),0) INTO v_stock_after FROM public.product_stocks
    WHERE company_id=v_company;
  SELECT count(*) INTO v_event_after FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_journal_after FROM public.journal_entries WHERE company_id=v_company;
  SELECT count(*) INTO v_movement_after FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_fifo_after FROM public.sale_fifo_allocations WHERE company_id=v_company;
  IF v_stock_after IS DISTINCT FROM v_stock_before OR v_event_after<>v_event_before
    OR v_journal_after<>v_journal_before OR v_movement_after<>v_movement_before
    OR v_fifo_after<>v_fifo_before THEN
    RAISE EXCEPTION 'TEST_FAILED: converter created forbidden Stock/Finance effect';
  END IF;
END
$test$;

SELECT 'sales_process_cutover_retail_to_backoffice_converter_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'self-created canonical Retail Draft','Draft maps to Backoffice Quotation',
    'rollback-only Stock headroom isolates converter from procurement shortage',
    'commercial and tax snapshot preserved',
    'future Scheduled timing remains Draft Quotation with planned date preserved',
    'Reserved lifecycle maps to confirmed SO with Reservation and initial DO',
    'Reserved source releases Reservation and cancels Delivery while retaining immutable Invoice history',
    'same operation is an exact retry','operation reuse for another source is rejected',
    'source closes only in same transaction',
    'zero Stock Movement/FIFO/Finance effect'),'transactionEnd','ROLLBACK') details;
ROLLBACK;
