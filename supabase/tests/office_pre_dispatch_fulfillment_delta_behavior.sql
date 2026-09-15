-- Procurement recovery phase2: rollback-only pre-dispatch lifecycle behavior.
-- Creates its own canonical Retail Draft; no operational document is borrowed.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000151411',
  'cutover-retention@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Cutover Retail Backoffice Test"}'::jsonb,
  false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000151411',
  'cutover-retention@example.invalid',
  'Cutover Retail Backoffice Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE
  v_actor uuid:='00000000-0000-0000-0000-000000151411';
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
  v_reservation_id uuid;v_delivery_id uuid;v_delivery_no text;v_reservation_version bigint;v_delivery_line_id uuid;
  v_state_before jsonb;v_state_after jsonb;v_request uuid;v_request_qty numeric;v_original_cap numeric;v_revision_operation uuid;v_version bigint;
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
  VALUES(v_product,v_warehouse,0,v_company)
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
    'isTempo',true,'transactionDateIntent','PRESERVE','dueDate',clock_timestamp()+interval '7 days',
    'fulfillmentMode','DELIVERY','deliveryRecipientName','Cutover Test',
    'deliveryRecipientPhone',NULL,'deliveryAddress',NULL,
    'deliveryScheduledAt',NULL,'deliveryNotes',NULL,'deliveryFeeAmount',250,
    'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE','payments','[]'::jsonb);
  v_saved:=public.save_pos_sale_draft_with_pricelist(v_payload);
  v_sale_id:=(v_saved->>'salesId')::uuid;
  SELECT grand_total_after_rounding INTO STRICT v_source_total
  FROM public.sales_headers WHERE company_id=v_company AND id=v_sale_id;


 UPDATE public.warehouses SET allow_negative_stock=true WHERE company_id=v_company AND id=v_warehouse;
 PERFORM public.confirm_pos_sales_order(v_sale_id,(v_saved->>'masterVersion')::bigint,gen_random_uuid(),NULL);
 SELECT master_version INTO STRICT v_version FROM public.cashier_sessions WHERE company_id=v_company AND id=v_session;
 PERFORM public.close_cashier_session(v_session,v_version,0);
 SELECT header.stock_request_document_id,line.demand_base_qty INTO STRICT v_request,v_original_cap
 FROM public.sales_order_procurement_demand_lines line JOIN public.sales_order_procurement_demands header
 ON header.company_id=line.company_id AND header.id=line.demand_id WHERE line.company_id=v_company AND line.sales_id=v_sale_id;
 SELECT jsonb_build_object(
  'demand',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.sales_order_procurement_demand_lines line WHERE company_id=v_company AND sales_id=v_sale_id),
  'request',(SELECT to_jsonb(document) FROM public.stock_request_documents document WHERE id=v_request),
  'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.stock_request_lines line WHERE company_id=v_company AND document_id=v_request),
  'stock',(SELECT jsonb_agg(to_jsonb(stock) ORDER BY product_id,warehouse_id) FROM public.product_stocks stock WHERE company_id=v_company),
  'movement',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
  'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
  'finance',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
  'journal',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company))
 INTO v_state_before;
 PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
 v_result:=private.convert_retail_sale_to_backoffice_order(v_company,v_sale_id,v_actor,v_operation);
 v_target:=(v_result->>'targetDocumentId')::uuid;
 IF v_result->>'targetStatus'<>'CONFIRMED' OR NOT (v_result->>'reservationTransferred')::boolean THEN
  RAISE EXCEPTION 'TEST_FAILED: converter did not create confirmed SO/Reservation/DO: %',v_result; END IF;
 SELECT jsonb_build_object(
  'demand',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.sales_order_procurement_demand_lines line WHERE company_id=v_company AND sales_id=v_sale_id),
  'request',(SELECT to_jsonb(document) FROM public.stock_request_documents document WHERE id=v_request),
  'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.stock_request_lines line WHERE company_id=v_company AND document_id=v_request),
  'stock',(SELECT jsonb_agg(to_jsonb(stock) ORDER BY product_id,warehouse_id) FROM public.product_stocks stock WHERE company_id=v_company),
  'movement',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
  'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
  'finance',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
  'journal',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company))
 INTO v_state_after;
 IF v_state_before IS DISTINCT FROM v_state_after THEN RAISE EXCEPTION 'TEST_FAILED: conversion changed preserved procurement/stock/finance'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.sales_headers WHERE company_id=v_company AND id=v_sale_id AND order_runtime_status='CANCELED')
 OR NOT EXISTS(SELECT 1 FROM public.sales_stock_reservations WHERE company_id=v_company AND sales_id=v_sale_id AND status='RELEASED')
 OR (SELECT count(*) FROM public.sales_cutover_procurement_links WHERE company_id=v_company AND target_sales_order_id=v_target)<>1
 OR (SELECT count(*) FROM public.backoffice_sales_delivery_orders WHERE company_id=v_company AND sales_order_id=v_target)<>1
 THEN RAISE EXCEPTION 'TEST_FAILED: source release/unique link/DO invalid'; END IF;
 v_retry:=private.convert_retail_sale_to_backoffice_order(v_company,v_sale_id,v_actor,v_operation);
 IF NOT (v_retry->>'exactRetry')::boolean OR v_retry->>'targetDocumentId'<>v_target::text THEN RAISE EXCEPTION 'TEST_FAILED: exact converter retry invalid'; END IF;
 SELECT id INTO STRICT v_reservation_id FROM public.backoffice_sales_reservations WHERE company_id=v_company AND sales_order_id=v_target;
 SELECT id,delivery_no INTO STRICT v_delivery_id,v_delivery_no FROM public.backoffice_sales_delivery_orders WHERE company_id=v_company AND sales_order_id=v_target;
 v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
  'orderDate',v_today,'plannedDeliveryDate',v_today,'isTempo',true,'dueDate',v_today+7,
  'currencyCode','IDR','revisionReason','Rollback-only lifecycle test','lines',
  jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,'quantity',1)),
  'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100);
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=v_target;
 v_revision_operation:=gen_random_uuid();
 v_saved:=public.save_backoffice_sales_order_draft(v_target,v_version,v_revision_operation,v_payload);
 SELECT requested_base_qty INTO STRICT v_request_qty FROM public.stock_request_lines WHERE company_id=v_company AND document_id=v_request AND product_id=v_product;
 IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations WHERE company_id=v_company AND id=v_reservation_id AND total_reserved_base_qty=v_factor)
 OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders WHERE company_id=v_company AND id=v_delivery_id AND delivery_no=v_delivery_no AND total_planned_base_qty=v_factor)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_order_lines WHERE company_id=v_company AND delivery_order_id=v_delivery_id AND planned_base_qty<>v_factor)
 OR (SELECT count(*) FROM public.backoffice_sales_fulfillment_audit WHERE company_id=v_company AND sales_order_id=v_target AND action='UPDATE_PLAN' AND before_state->'lines' IS NOT NULL)<>2
 THEN RAISE EXCEPTION 'TEST_FAILED: same-parent delta/audit invalid'; END IF;
 SELECT master_version INTO STRICT v_reservation_version FROM public.backoffice_sales_reservations WHERE company_id=v_company AND id=v_reservation_id;
 IF v_request_qty<>v_factor OR NOT EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines
  WHERE company_id=v_company AND sales_id=v_sale_id AND demand_base_qty=v_original_cap AND released_base_qty=v_original_cap-v_factor)
 THEN RAISE EXCEPTION 'TEST_FAILED: Office revision did not reduce existing request without rewriting original demand cap: %',v_request_qty; END IF;
 PERFORM public.save_backoffice_sales_order_draft(v_target,v_version,v_revision_operation,v_payload);
 IF (SELECT master_version FROM public.backoffice_sales_reservations WHERE id=v_reservation_id)<>v_reservation_version THEN RAISE EXCEPTION 'TEST_FAILED: retry rebuilt reservation'; END IF;
 BEGIN
  PERFORM public.save_backoffice_sales_order_draft(v_target,v_version,gen_random_uuid(),v_payload);
  RAISE EXCEPTION 'TEST_FAILED: stale revision accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE '%VERSION%' THEN RAISE; END IF; END;
 -- A failed rebuild must restore all detached/rebuilt state, including old request.
 SELECT jsonb_build_object('so',(SELECT to_jsonb(header) FROM public.backoffice_sales_orders header WHERE id=v_target),
  'reservation',(SELECT to_jsonb(header) FROM public.backoffice_sales_reservations header WHERE id=v_reservation_id),
  'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE reservation_id=v_reservation_id),
  'delivery',(SELECT to_jsonb(header) FROM public.backoffice_sales_delivery_orders header WHERE id=v_delivery_id),
  'audit',(SELECT count(*) FROM public.backoffice_sales_fulfillment_audit WHERE company_id=v_company))
 INTO v_state_before;
 UPDATE public.warehouses SET allow_negative_stock=false WHERE company_id=v_company AND id=v_warehouse;
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=v_target;
 BEGIN
  PERFORM public.save_backoffice_sales_order_draft(v_target,v_version,gen_random_uuid(),jsonb_set(v_payload,'{lines,0,quantity}','3'::jsonb));
  RAISE EXCEPTION 'TEST_FAILED: negative Warehouse opt-out ignored';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'BACKOFFICE_SALES_NEGATIVE_RESERVATION_REQUIRES_WAREHOUSE_OPT_IN' THEN RAISE; END IF; END;
 SELECT jsonb_build_object('so',(SELECT to_jsonb(header) FROM public.backoffice_sales_orders header WHERE id=v_target),
  'reservation',(SELECT to_jsonb(header) FROM public.backoffice_sales_reservations header WHERE id=v_reservation_id),
  'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE reservation_id=v_reservation_id),
  'delivery',(SELECT to_jsonb(header) FROM public.backoffice_sales_delivery_orders header WHERE id=v_delivery_id),
  'audit',(SELECT count(*) FROM public.backoffice_sales_fulfillment_audit WHERE company_id=v_company))
 INTO v_state_after;
 IF v_state_before IS DISTINCT FROM v_state_after THEN RAISE EXCEPTION 'TEST_FAILED: failed revision left partial delta'; END IF;
 UPDATE public.warehouses SET allow_negative_stock=true WHERE company_id=v_company AND id=v_warehouse;
 v_payload:=jsonb_set(v_payload,'{lines,0,quantity}','2'::jsonb);
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=v_target;
 PERFORM public.save_backoffice_sales_order_draft(v_target,v_version,gen_random_uuid(),v_payload);
 SELECT requested_base_qty INTO STRICT v_request_qty FROM public.stock_request_lines WHERE company_id=v_company AND document_id=v_request AND product_id=v_product;
 IF v_request_qty<>v_original_cap THEN RAISE EXCEPTION 'TEST_FAILED: reinstated original obligation invalid'; END IF;
 v_payload:=jsonb_set(v_payload,'{lines,0,quantity}','3'::jsonb);
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=v_target;
 PERFORM public.save_backoffice_sales_order_draft(v_target,v_version,gen_random_uuid(),v_payload);
 IF (SELECT requested_base_qty FROM public.stock_request_lines WHERE company_id=v_company AND document_id=v_request AND product_id=v_product)<>v_original_cap
 THEN RAISE EXCEPTION 'TEST_FAILED: Office Reserve increase duplicated request'; END IF;
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=v_target;
 v_revision_operation:=gen_random_uuid();
 PERFORM public.cancel_backoffice_sales_order(v_target,v_version,v_revision_operation,'Rollback-only cancellation');
 PERFORM public.cancel_backoffice_sales_order(v_target,v_version,v_revision_operation,'Rollback-only cancellation');
 IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations WHERE id=v_reservation_id AND status='RELEASED' AND total_reserved_base_qty=total_released_base_qty)
 OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders WHERE id=v_delivery_id AND status='CANCELED' AND delivery_no=v_delivery_no)
 THEN RAISE EXCEPTION 'TEST_FAILED: canceled SO left active fulfillment'; END IF;
 IF EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines WHERE company_id=v_company AND sales_id=v_sale_id AND demand_base_qty<>released_base_qty)
 OR EXISTS(SELECT 1 FROM public.stock_request_lines WHERE company_id=v_company AND document_id=v_request AND is_active)
 THEN RAISE EXCEPTION 'TEST_FAILED: canceled Office obligation not released'; END IF;
 IF private.classify_sales_process_conversion_candidate('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,true,false,false,false,true,false,true)->>'decision'<>'BLOCKED'
 OR private.classify_sales_process_conversion_candidate('RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',false,false,false,false,true,true,false,true)->>'decision'<>'BLOCKED'
 THEN RAISE EXCEPTION 'TEST_FAILED: dispatch/payment classifiers weakened'; END IF;
 -- A real partial/full dispatch must prevent ordinary revision/cancellation.
 v_payload:=jsonb_set(v_payload,'{lines,0,quantity}','2'::jsonb);
 v_saved:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
 v_target:=(v_saved->'data'->>'id')::uuid;
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE id=v_target;
 PERFORM public.confirm_backoffice_sales_order(v_target,v_version,gen_random_uuid());
 SELECT id,master_version INTO STRICT v_delivery_id,v_version FROM public.backoffice_sales_delivery_orders WHERE sales_order_id=v_target;
 SELECT id INTO STRICT v_delivery_line_id FROM public.backoffice_sales_delivery_order_lines WHERE delivery_order_id=v_delivery_id;
 v_result:=public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,gen_random_uuid(),
   jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line_id,'quantityUom',1)),NULL);
 IF v_result->>'deliveryStatus'<>'PARTIALLY_SHIPPED' THEN RAISE EXCEPTION 'TEST_FAILED: partial dispatch fixture invalid: %',v_result; END IF;
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE id=v_target;
 BEGIN
  PERFORM public.save_backoffice_sales_order_draft(v_target,v_version,gen_random_uuid(),v_payload);
  RAISE EXCEPTION 'TEST_FAILED: partially dispatched SO revision accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'OFFICE_PRE_DISPATCH_FULFILLMENT_STATE_INVALID' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.cancel_backoffice_sales_order(v_target,v_version,gen_random_uuid(),'Denied partial fixture');
  RAISE EXCEPTION 'TEST_FAILED: partially dispatched SO cancellation accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'OFFICE_PRE_DISPATCH_FULFILLMENT_STATE_INVALID' THEN RAISE; END IF; END;
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_delivery_orders WHERE id=v_delivery_id;
 v_result:=public.dispatch_backoffice_sales_delivery(v_delivery_id,v_version,gen_random_uuid(),
   jsonb_build_array(jsonb_build_object('deliveryLineId',v_delivery_line_id,'quantityUom',1)),NULL);
 IF v_result->>'deliveryStatus'<>'IN_TRANSIT' THEN RAISE EXCEPTION 'TEST_FAILED: full dispatch fixture invalid: %',v_result; END IF;
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE id=v_target;
 BEGIN
  PERFORM public.cancel_backoffice_sales_order(v_target,v_version,gen_random_uuid(),'Denied full fixture');
  RAISE EXCEPTION 'TEST_FAILED: fully dispatched SO cancellation accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'OFFICE_PRE_DISPATCH_FULFILLMENT_STATE_INVALID' THEN RAISE; END IF; END;
 RAISE NOTICE 'PASS: canonical shortage/closed session; preserved request; same-parent revision/audit; exact retry/stale; Warehouse opt-out atomic rollback; cancellation; real partial/full dispatch protected; all fixtures rollback';
END $test$;
ROLLBACK;

