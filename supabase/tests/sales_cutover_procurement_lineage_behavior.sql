-- Procurement linkage foundation behavior, NOT converter activation.
-- Own canonical Retail Draft/Confirm/closed Session/Stock Request and Office Draft.
-- All fixture writes roll back. Compare operational state across link calls.
BEGIN;

INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
  is_super_admin,role,aud,email_confirmed_at)
VALUES('00000000-0000-0000-0000-000000151401',
  'cutover-procurement-lineage@example.invalid',
  '00000000-0000-0000-0000-000000000000',
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"name":"Cutover Retail Backoffice Test"}'::jsonb,
  false,'authenticated','authenticated',clock_timestamp())
ON CONFLICT(id) DO NOTHING;

INSERT INTO public.profiles(id,email,name,role)
VALUES('00000000-0000-0000-0000-000000151401',
  'cutover-procurement-lineage@example.invalid',
  'Cutover Retail Backoffice Test','super_admin'::public.user_role)
ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,role=excluded.role;

DO $test$
DECLARE
  v_actor uuid:='00000000-0000-0000-0000-000000151401';
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
  v_state_before jsonb;v_state_after jsonb;v_read jsonb;v_demand_count bigint;
  v_request uuid;v_other_company uuid:=gen_random_uuid();
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
    AND EXISTS(SELECT 1 FROM public.company_sales_process_settings setting
      WHERE setting.company_id=company.id AND setting.active_mode='RETAIL_CONFIRM_INVOICE')
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
  SELECT master_version INTO v_reserved_version FROM public.cashier_sessions WHERE company_id=v_company AND id=v_session;
  PERFORM public.close_cashier_session(v_session,v_reserved_version,0);
  SELECT count(*),min(header.stock_request_document_id::text)::uuid INTO v_demand_count,v_request
    FROM public.sales_order_procurement_demand_lines line
    JOIN public.sales_order_procurement_demands header ON header.company_id=line.company_id AND header.id=line.demand_id
    WHERE line.company_id=v_company AND line.sales_id=v_sale_id AND line.status='REQUESTED';
  IF v_demand_count<>1 OR v_request IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical shortage/closed-session fixture did not create Stock Request';
  END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  v_saved:=public.save_backoffice_sales_order_draft(NULL,NULL,v_operation,jsonb_build_object(
    'storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
    'orderDate',v_today,'plannedDeliveryDate',v_today,'isTempo',true,'dueDate',v_today+7,
    'currencyCode','IDR','lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',2)),
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100));
  v_target:=(v_saved#>>'{data,id}')::uuid;
  IF v_target IS NULL THEN RAISE EXCEPTION 'TEST_FAILED: canonical target save failed: %',v_saved; END IF;
  UPDATE public.backoffice_sales_orders SET commercial_snapshot=commercial_snapshot||
    jsonb_build_object('cutoverSourceDocumentId',v_sale_id)
    WHERE company_id=v_company AND id=v_target;
  SELECT jsonb_build_object(
    'source',(SELECT to_jsonb(source) FROM public.sales_headers source WHERE source.id=v_sale_id),
    'demand',(SELECT jsonb_agg(to_jsonb(line) ORDER BY line.id) FROM public.sales_order_procurement_demand_lines line WHERE line.company_id=v_company AND line.sales_id=v_sale_id),
    'request',(SELECT to_jsonb(request) FROM public.stock_request_documents request WHERE request.id=v_request),
    'requestLines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY line.id) FROM public.stock_request_lines line WHERE line.company_id=v_company AND line.document_id=v_request),
    'reservation',(SELECT jsonb_agg(to_jsonb(reservation) ORDER BY reservation.id) FROM public.sales_stock_reservations reservation WHERE reservation.company_id=v_company AND reservation.sales_id=v_sale_id),
    'stock',(SELECT jsonb_agg(to_jsonb(stock) ORDER BY stock.product_id,stock.warehouse_id) FROM public.product_stocks stock WHERE stock.company_id=v_company),
    'movements',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
    'events',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
    'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
    'journals',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company))
  INTO v_state_before;
  v_result:=private.link_sales_cutover_procurement(v_company,v_sale_id,v_target,v_actor,v_operation);
  v_retry:=private.link_sales_cutover_procurement(v_company,v_sale_id,v_target,v_actor,v_operation);
  v_read:=public.get_backoffice_sales_order_procurement_links(v_target);
  IF (v_result->>'linkedDemandLines')::bigint<>v_demand_count
    OR v_retry<>v_result OR jsonb_array_length(v_read->'links')<>v_demand_count
    OR v_read#>>'{links,0,stockRequestId}' IS DISTINCT FROM v_request::text
    OR v_read#>>'{links,0,stockRequestStatus}' IS DISTINCT FROM 'SUBMITTED' THEN
    RAISE EXCEPTION 'TEST_FAILED: linkage/retry/read contract invalid: %',v_read;
  END IF;
  SELECT jsonb_build_object(
    'source',(SELECT to_jsonb(source) FROM public.sales_headers source WHERE source.id=v_sale_id),
    'demand',(SELECT jsonb_agg(to_jsonb(line) ORDER BY line.id) FROM public.sales_order_procurement_demand_lines line WHERE line.company_id=v_company AND line.sales_id=v_sale_id),
    'request',(SELECT to_jsonb(request) FROM public.stock_request_documents request WHERE request.id=v_request),
    'requestLines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY line.id) FROM public.stock_request_lines line WHERE line.company_id=v_company AND line.document_id=v_request),
    'reservation',(SELECT jsonb_agg(to_jsonb(reservation) ORDER BY reservation.id) FROM public.sales_stock_reservations reservation WHERE reservation.company_id=v_company AND reservation.sales_id=v_sale_id),
    'stock',(SELECT jsonb_agg(to_jsonb(stock) ORDER BY stock.product_id,stock.warehouse_id) FROM public.product_stocks stock WHERE stock.company_id=v_company),
    'movements',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
    'events',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
    'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
    'journals',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company))
  INTO v_state_after;
  IF v_state_before IS DISTINCT FROM v_state_after THEN
    RAISE EXCEPTION 'TEST_FAILED: foundation mutated operational state';
  END IF;
  BEGIN
    PERFORM private.link_sales_cutover_procurement(v_company,v_sale_id,v_target,gen_random_uuid(),v_operation);
    RAISE EXCEPTION 'TEST_FAILED: invalid actor accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'CUTOVER_PROCUREMENT_LINK_CONTEXT_INVALID' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM private.link_sales_cutover_procurement(v_company,v_sale_id,v_target,v_actor,gen_random_uuid());
    RAISE EXCEPTION 'TEST_FAILED: invalid operation accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'CUTOVER_PROCUREMENT_LINK_SCOPE_INVALID' THEN RAISE; END IF;
  END;
  BEGIN
    DELETE FROM public.sales_cutover_procurement_links WHERE company_id=v_company AND target_sales_order_id=v_target;
    RAISE EXCEPTION 'TEST_FAILED: immutable link deleted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'CUTOVER_PROCUREMENT_LINK_IMMUTABLE' THEN RAISE; END IF;
  END;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  BEGIN
    PERFORM private.link_sales_cutover_procurement(v_company,v_sale_id,v_target,v_actor,v_operation);
    RAISE EXCEPTION 'TEST_FAILED: missing mutation context accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'CUTOVER_PROCUREMENT_LINK_CONTEXT_INVALID' THEN RAISE; END IF;
  END;
  INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES(v_other_company,'LNK-'||substr(replace(v_other_company::text,'-',''),1,12),
      'Rollback-only lineage tenant','lnk-'||replace(v_other_company::text,'-',''),'ACTIVE');
  -- Make the other tenant's Sales module eligible so this assertion reaches
  -- document tenant isolation rather than stopping at the feature gate.
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
    VALUES(v_other_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor);
  PERFORM public.set_active_company_context(v_other_company,'CUTOVER_TEST');
  BEGIN
    PERFORM public.get_backoffice_sales_order_procurement_links(v_target);
    RAISE EXCEPTION 'TEST_FAILED: other Company target readable';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'BACKOFFICE_SALES_ORDER_NOT_FOUND' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS: canonical requested demand; closed session; exact link retry; authorized read; immutable link; actor/operation/context/tenant denial; no operational delta; rollback-only';
END
$test$;
ROLLBACK;
