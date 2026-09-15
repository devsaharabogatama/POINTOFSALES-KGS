-- Procurement recovery phase2: two canonical sources share one Stock Request line.
-- Reduce/reinstate/cancel one converted SO without changing the other source.
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
  v_state_before jsonb;v_state_after jsonb;v_request uuid;v_request_qty numeric;v_original_cap numeric;v_revision_operation uuid;v_version bigint;v_other_sale uuid;v_plan_id uuid:=gen_random_uuid();v_item_id uuid:=gen_random_uuid();v_other_item uuid:=gen_random_uuid();v_setting_version bigint;v_other_source_version bigint;v_old_history jsonb;
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
 -- Second canonical order shares this session/Product request line.
 v_saved:=public.save_pos_sale_draft_with_pricelist(jsonb_set(v_payload,'{clientTransactionId}',to_jsonb(gen_random_uuid())));
 v_other_sale:=(v_saved->>'salesId')::uuid;
 PERFORM public.confirm_pos_sales_order(v_other_sale,(v_saved->>'masterVersion')::bigint,gen_random_uuid(),NULL);
 SELECT master_version INTO STRICT v_version FROM public.cashier_sessions WHERE company_id=v_company AND id=v_session;
 PERFORM public.close_cashier_session(v_session,v_version,0);
 SELECT header.stock_request_document_id,line.demand_base_qty INTO STRICT v_request,v_original_cap
 FROM public.sales_order_procurement_demand_lines line JOIN public.sales_order_procurement_demands header
 ON header.company_id=line.company_id AND header.id=line.demand_id WHERE line.company_id=v_company AND line.sales_id=v_sale_id;

 -- Reproduce a historical APPLIED/KEPT outcome, not a fabricated completed sale.
 -- All history fixture rows are owned and rolled back with the test.
 SELECT master_version INTO STRICT v_setting_version FROM public.company_sales_process_settings WHERE company_id=v_company;
 INSERT INTO public.sales_process_cutover_plans(id,company_id,source_mode,target_mode,effective_at,status,reason,
 expected_settings_version,operation_id,request_hash,preview_snapshot,created_by,applied_by,applied_at)
 VALUES(v_plan_id,v_company,'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',clock_timestamp()-interval '1 second',
 'APPLIED','Owned historical procurement-only retention fixture',v_setting_version,gen_random_uuid(),repeat('a',64),'{}',v_actor,v_actor,clock_timestamp());
 INSERT INTO public.sales_process_cutover_items(id,company_id,cutover_plan_id,source_mode,target_mode,
 source_document_type,source_document_id,source_document_no,source_status,source_master_version,decision,item_status,blocker_codes)
 SELECT mapping.item_id,v_company,v_plan_id,'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE',
 'RETAIL_SALE',source.id,source.draft_no,'RESERVED',source.master_version,'BLOCKED','KEPT','["OPEN_PROCUREMENT_MUST_FINISH"]'::jsonb
 FROM (VALUES(v_item_id,v_sale_id),(v_other_item,v_other_sale)) mapping(item_id,sales_id)
 JOIN public.sales_headers source ON source.id=mapping.sales_id;
 INSERT INTO public.sales_process_cutover_audit(company_id,cutover_plan_id,cutover_item_id,action,actor_id,operation_id,after_state)
 VALUES(v_company,v_plan_id,v_item_id,'KEEP_ITEM',v_actor,v_item_id,'{"sourceRetained":true}'),
 (v_company,v_plan_id,v_other_item,'KEEP_ITEM',v_actor,v_other_item,'{"sourceRetained":true}');
 PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
 UPDATE public.company_sales_process_settings SET active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',
 master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp() WHERE company_id=v_company;
 PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
 SELECT master_version INTO STRICT v_setting_version FROM public.company_sales_process_settings WHERE company_id=v_company;
 SELECT master_version INTO STRICT v_version FROM public.sales_headers WHERE id=v_sale_id;
 SELECT jsonb_build_object('plan',(SELECT to_jsonb(plan) FROM public.sales_process_cutover_plans plan WHERE id=v_plan_id),
 'items',(SELECT jsonb_agg(to_jsonb(item) ORDER BY id) FROM public.sales_process_cutover_items item WHERE cutover_plan_id=v_plan_id),
 'kept',(SELECT jsonb_agg(to_jsonb(audit) ORDER BY id) FROM public.sales_process_cutover_audit audit WHERE cutover_plan_id=v_plan_id AND action='KEEP_ITEM'))
 INTO v_old_history;
 BEGIN
  PERFORM public.recover_retained_sales_process_order(v_item_id,1,v_version-1,v_setting_version,v_operation);
  RAISE EXCEPTION 'TEST_FAILED: stale source accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'SALES_PROCESS_RECOVERY_SOURCE_VERSION_STALE' THEN RAISE; END IF; END;
 v_result:=public.recover_retained_sales_process_order(v_item_id,1,v_version,v_setting_version,v_operation);
 v_target:=(v_result->>'targetDocumentId')::uuid;
 v_retry:=public.recover_retained_sales_process_order(v_item_id,1,v_version,v_setting_version,v_operation);
 IF NOT (v_retry->>'exactRetry')::boolean OR v_retry->>'targetDocumentId'<>v_target::text THEN RAISE EXCEPTION 'TEST_FAILED: public recovery retry invalid'; END IF;
 BEGIN
  PERFORM public.recover_retained_sales_process_order(v_other_item,1,v_version,v_setting_version,v_operation);
  RAISE EXCEPTION 'TEST_FAILED: recovery operation conflict accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT' THEN RAISE; END IF; END;
 SELECT master_version INTO STRICT v_other_source_version FROM public.sales_headers WHERE id=v_other_sale;
 v_result:=public.recover_retained_sales_process_order(v_other_item,1,v_other_source_version,v_setting_version,gen_random_uuid());
 v_reserved_target:=(v_result->>'targetDocumentId')::uuid;
 IF (SELECT count(*) FROM public.sales_cutover_procurement_links WHERE company_id=v_company AND target_sales_order_id IN(v_target,v_reserved_target))<>2
 THEN RAISE EXCEPTION 'TEST_FAILED: two recovery links invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_sales_process_cutover_plan(v_plan_id)->'items') item
 WHERE item->>'itemId'=v_item_id::text AND item->>'recovered'='true' AND item->>'targetDocumentId'=v_target::text AND item->>'itemStatus'='KEPT')
 THEN RAISE EXCEPTION 'TEST_FAILED: immutable history read projection/link invalid'; END IF;
 SELECT jsonb_build_object('plan',(SELECT to_jsonb(plan) FROM public.sales_process_cutover_plans plan WHERE id=v_plan_id),
 'items',(SELECT jsonb_agg(to_jsonb(item) ORDER BY id) FROM public.sales_process_cutover_items item WHERE cutover_plan_id=v_plan_id),
 'kept',(SELECT jsonb_agg(to_jsonb(audit) ORDER BY id) FROM public.sales_process_cutover_audit audit WHERE cutover_plan_id=v_plan_id AND action='KEEP_ITEM'))
 INTO v_state_after;
 IF v_old_history IS DISTINCT FROM v_state_after THEN RAISE EXCEPTION 'TEST_FAILED: recovery rewrote old plan/item/KEEP history'; END IF;
 v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,'customerId',v_customer,
 'orderDate',v_today,'plannedDeliveryDate',v_today,'isTempo',true,'dueDate',v_today+7,
 'revisionReason','Shared converted source test','lines',jsonb_build_array(jsonb_build_object('productUomId',v_product_uom,'quantity',1)));
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE id=v_target;
 PERFORM public.save_backoffice_sales_order_draft(v_target,v_version,gen_random_uuid(),v_payload);
 IF (SELECT requested_base_qty FROM public.stock_request_lines WHERE document_id=v_request AND product_id=v_product)<>3*v_factor
 THEN RAISE EXCEPTION 'TEST_FAILED: two converted sources double counted request'; END IF;
 SELECT master_version INTO STRICT v_version FROM public.backoffice_sales_orders WHERE id=v_target;
 PERFORM public.cancel_backoffice_sales_order(v_target,v_version,gen_random_uuid(),'Shared linked cancellation');
 IF (SELECT requested_base_qty FROM public.stock_request_lines WHERE document_id=v_request AND product_id=v_product)<>2*v_factor
 THEN RAISE EXCEPTION 'TEST_FAILED: one linked cancellation removed other linked need'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_sales_process_cutover_preview('RETAIL_CONFIRM_INVOICE')->'candidates') candidate
 WHERE candidate->>'sourceDocumentId'=v_reserved_target::text AND candidate->>'decision'='BLOCKED'
 AND candidate->'blockerCodes' ? 'OPEN_PROCUREMENT_MUST_FINISH')
 THEN RAISE EXCEPTION 'TEST_FAILED: linked reverse preview ownership guard absent'; END IF;
 PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
 BEGIN
  PERFORM private.convert_backoffice_order_to_retail_sale(v_company,v_reserved_target,v_actor,gen_random_uuid());
  RAISE EXCEPTION 'TEST_FAILED: linked reverse kernel ownership guard bypassed';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'OPEN_PROCUREMENT_MUST_FINISH' THEN RAISE; END IF; END;
 PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_retained_sales_process_recovery_candidates()) candidate
 WHERE candidate->>'itemId' IN(v_item_id::text,v_other_item::text))
 THEN RAISE EXCEPTION 'TEST_FAILED: recovered items remain recovery candidates'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(private.backoffice_sales_order_snapshot(v_company,v_reserved_target)->'activity') activity
 WHERE activity->>'action'='CUTOVER_RECOVERY' AND activity->>'relatedDocumentId'=v_other_sale::text)
 THEN RAISE EXCEPTION 'TEST_FAILED: Office document activity lost source link'; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_sales_document_activity()) activity
 WHERE activity->>'salesId'=v_other_sale::text AND activity->'cutover'->>'targetDocumentId'=v_reserved_target::text)
 THEN RAISE EXCEPTION 'TEST_FAILED: Retail source document activity lost target link'; END IF;
 UPDATE public.profiles SET role='cashier'::public.user_role WHERE id=v_actor;
 BEGIN
  PERFORM public.recover_retained_sales_process_order(v_item_id,1,v_version,v_setting_version,gen_random_uuid());
  RAISE EXCEPTION 'TEST_FAILED: non-Super-Admin recovered item';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED' THEN RAISE; END IF; END;
 UPDATE public.profiles SET role='super_admin'::public.user_role WHERE id=v_actor;
 -- Other Company need not contain any operational data to prove tenant denial.
 v_scheduled_target:=gen_random_uuid();
 INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
 VALUES(v_scheduled_target,'REC-'||substr(replace(v_scheduled_target::text,'-',''),1,12),
 'Rollback-only recovery tenant','rec-'||replace(v_scheduled_target::text,'-',''),'ACTIVE');
 UPDATE public.user_active_company_contexts SET company_id=v_scheduled_target WHERE user_id=v_actor;
 BEGIN
  PERFORM public.recover_retained_sales_process_order(v_item_id,1,1,1,gen_random_uuid());
  RAISE EXCEPTION 'TEST_FAILED: other Company recovered source';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'SALES_PROCESS_RECOVERY_ITEM_NOT_FOUND' THEN RAISE; END IF; END;
 UPDATE public.user_active_company_contexts SET company_id=v_company WHERE user_id=v_actor;
END $test$;
ROLLBACK;
