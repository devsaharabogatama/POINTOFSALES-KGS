-- Step 4C/6 authenticated rollback-only behavior. No operational row is borrowed.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_store uuid;v_warehouse uuid;v_customer uuid;
  v_product_uom uuid;v_timezone text;v_today date;v_future date;
  v_now timestamptz:=clock_timestamp();
  v_payload jsonb;v_created jsonb;v_confirmed jsonb;v_result jsonb;v_retry jsonb;
  v_price_result jsonb;
  v_draft_source uuid;v_draft_target uuid;v_confirmed_source uuid;v_confirmed_target uuid;
  v_future_non_tempo uuid;v_operation uuid:=gen_random_uuid();
  v_confirmed_operation uuid:=gen_random_uuid();v_conflict boolean:=false;
  v_preview jsonb;v_before jsonb;v_after jsonb;v_source_total numeric;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260911110000','20260911111000'))<>2 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: 20260911110000 and 20260911111000 required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Super Admin profile required';
  END IF;
  SELECT company.id,store.id,warehouse.id,customer.id,product_uom.id,company.timezone
    INTO v_company,v_store,v_warehouse,v_customer,v_product_uom,v_timezone
  FROM public.companies company
  JOIN LATERAL(SELECT candidate.id FROM public.stores candidate
    WHERE candidate.company_id=company.id AND candidate.status='ACTIVE'
    ORDER BY candidate.id LIMIT 1) store ON true
  JOIN LATERAL(SELECT candidate.id FROM public.warehouses candidate
    WHERE candidate.company_id=company.id AND candidate.is_active AND candidate.is_sale_source
    ORDER BY candidate.id LIMIT 1) warehouse ON true
  JOIN LATERAL(SELECT candidate.id FROM public.customers candidate
    WHERE candidate.company_id=company.id AND candidate.is_active
    ORDER BY candidate.is_system_customer DESC,candidate.id LIMIT 1) customer ON true
  JOIN LATERAL(SELECT candidate.id FROM public.product_uoms candidate
    JOIN public.products product ON product.company_id=candidate.company_id
      AND product.id=candidate.product_id AND product.is_active AND NOT product.is_bundle
    JOIN public.uoms uom ON uom.company_id=candidate.company_id
      AND uom.id=candidate.uom_id AND uom.is_active
    WHERE candidate.company_id=company.id AND candidate.is_active
      AND candidate.sales_allowed AND candidate.factor_to_base>0
      AND candidate.sale_price>0
      AND (SELECT count(*) FROM public.product_uoms exact
        WHERE exact.company_id=candidate.company_id AND exact.product_id=candidate.product_id
          AND exact.uom_id=candidate.uom_id AND exact.is_active AND exact.sales_allowed)=1
    ORDER BY candidate.id LIMIT 1) product_uom ON true
  WHERE company.status='ACTIVE'
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company/Store/sale-source Warehouse/Customer/exact non-Bundle Product-UOM tuple required';
  END IF;
  v_price_result:=private.resolve_pos_sale_price(v_company,v_store,v_customer,
    v_product_uom,1,clock_timestamp());
  IF (v_price_result->>'resolvedUnitPrice')::numeric<=0 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: selected canonical Product-UOM must resolve to a positive price';
  END IF;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE
    SET company_id=excluded.company_id,selected_at=clock_timestamp(),updated_at=clock_timestamp();
  INSERT INTO public.company_features(company_id,feature_code,is_enabled,config,updated_by)
  VALUES(v_company,'backoffice_delivered_qty_sales_enabled',true,'{}',v_actor)
  ON CONFLICT(company_id,feature_code) DO UPDATE SET is_enabled=true,updated_by=excluded.updated_by;
  UPDATE public.warehouses SET allow_negative_stock=true
  WHERE company_id=v_company AND id=v_warehouse;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::date;v_future:=v_today+2;
  -- This older converter test predates the root-creation mode gate.
  -- Prepare the source Company mode transactionally, then clear the trusted scope
  -- before public Sales creation. The entire test rolls this preparation back.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at='-infinity',
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company sales process setting required'; END IF;
  PERFORM set_config('kgs.sales_process_cutover_mutation','',true);
  PERFORM private.assert_sales_process_root_creation_allowed(v_company,'BACKOFFICE_DELIVERED_QTY_INVOICE');

  v_payload:=jsonb_build_object('storeId',v_store,'warehouseId',v_warehouse,
    'customerId',v_customer,'selectedPricelistId',NULL,'orderDate',v_today,
    'plannedDeliveryDate',v_today+1,'isTempo',false,'currencyCode','IDR',
    'globalDiscount',0,'roundingDirection','NONE','roundingIncrement',100,
    'deliveryFeeAmount',0,'deliveryFeeInvoiceDisplayMode','SHOW_SEPARATE',
    'lines',jsonb_build_array(jsonb_build_object(
      'productUomId',v_product_uom,'quantity',2,'lineDiscountType','PERCENT',
      'lineDiscountInput',5)),'notes','Step 4C rollback Draft fixture');
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_draft_source:=(v_created->'data'->>'id')::uuid;
  SELECT grand_total INTO STRICT v_source_total FROM public.backoffice_sales_orders
  WHERE company_id=v_company AND id=v_draft_source;

  v_payload:=v_payload||jsonb_build_object('orderDate',v_future,
    'plannedDeliveryDate',v_future,'isTempo',true,'dueDate',v_future+14,
    'notes','Step 4C rollback Scheduled fixture');
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_confirmed_source:=(v_created->'data'->>'id')::uuid;
  v_confirmed:=public.confirm_backoffice_sales_order(v_confirmed_source,
    (v_created->'data'->>'masterVersion')::bigint,gen_random_uuid());

  v_payload:=v_payload||jsonb_build_object('orderDate',v_future,
    'plannedDeliveryDate',v_future,'isTempo',false,'dueDate',NULL,
    'notes','Step 4C future non-TEMPO blocker fixture');
  v_created:=public.save_backoffice_sales_order_draft(NULL,NULL,gen_random_uuid(),v_payload);
  v_future_non_tempo:=(v_created->'data'->>'id')::uuid;

  SELECT jsonb_build_object('stock',(SELECT COALESCE(sum(stock_qty),0)
      FROM public.product_stocks WHERE company_id=v_company),
    'movements',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
    'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
    'events',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
    'journals',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company),
    'retailInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots WHERE company_id=v_company))
    INTO v_before;
  PERFORM set_config('kgs.sales_process_cutover_mutation','1',true);
  v_result:=private.convert_backoffice_order_to_retail_sale(
    v_company,v_draft_source,v_actor,v_operation);
  v_draft_target:=(v_result->>'targetDocumentId')::uuid;
  v_retry:=private.convert_backoffice_order_to_retail_sale(
    v_company,v_draft_source,v_actor,v_operation);
  IF NOT COALESCE((v_retry->>'exactRetry')::boolean,false)
    OR v_retry->>'targetDocumentId'<>v_draft_target::text THEN
    RAISE EXCEPTION 'TEST_FAILED: reverse converter exact retry invalid: %',v_retry;
  END IF;
  BEGIN
    PERFORM private.convert_backoffice_order_to_retail_sale(
      v_company,v_confirmed_source,v_actor,v_operation);
  EXCEPTION WHEN OTHERS THEN
    v_conflict:=SQLERRM LIKE '%IDEMPOTENCY_PAYLOAD_CONFLICT%';
  END;
  IF NOT v_conflict THEN RAISE EXCEPTION 'TEST_FAILED: operation reuse accepted'; END IF;
  IF v_result->>'targetStatus'<>'DRAFT_INPUT'
    OR NOT COALESCE((v_result->>'requiresRetailConfirmation')::boolean,false)
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_draft_target
        AND sale.sales_origin='BACKOFFICE_CUTOVER' AND sale.document_status='DRAFT'
        AND sale.order_runtime_status='DRAFT_INPUT' AND sale.session_id IS NULL
        AND sale.pos_id IS NULL AND sale.created_session_id IS NULL
        AND sale.grand_total_after_rounding=v_source_total)
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_id=v_draft_target)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_draft_target)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_orders source
      WHERE source.company_id=v_company AND source.id=v_draft_source
        AND source.status='CANCELED') THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft Backoffice to Retail Draft mapping invalid: %',v_result;
  END IF;

  v_result:=private.convert_backoffice_order_to_retail_sale(
    v_company,v_confirmed_source,v_actor,v_confirmed_operation);
  v_confirmed_target:=(v_result->>'targetDocumentId')::uuid;
  IF v_result->>'targetStatus'<>'DRAFT_INPUT'
    OR v_result->>'orderTimingMode'<>'SCHEDULED'
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_confirmed_target
        AND sale.document_status='DRAFT' AND sale.order_runtime_status='DRAFT_INPUT'
        AND sale.order_timing_mode='SCHEDULED' AND sale.planned_order_date=v_future)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_order_id=v_confirmed_source
        AND reservation.status='RELEASED'
        AND reservation.total_released_base_qty=reservation.total_reserved_base_qty)
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
      WHERE delivery.company_id=v_company AND delivery.sales_order_id=v_confirmed_source
        AND delivery.delivery_kind='INITIAL' AND delivery.status='CANCELED')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_operations operation
      WHERE operation.company_id=v_company AND operation.operation_id=v_confirmed_operation
        AND operation.sales_order_id=v_confirmed_source AND operation.operation_type='CANCEL')
    OR NOT EXISTS(SELECT 1 FROM public.backoffice_sales_order_audit audit
      WHERE audit.company_id=v_company AND audit.operation_id=v_confirmed_operation
        AND audit.sales_order_id=v_confirmed_source AND audit.action='CANCEL')
    OR EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.sales_id=v_confirmed_target)
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=v_company AND delivery.sales_id=v_confirmed_target)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_confirmed_target) THEN
    RAISE EXCEPTION 'TEST_FAILED: confirmed future TEMPO downgrade invalid: %',v_result;
  END IF;

  UPDATE public.company_sales_process_settings SET
    active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE',mode_effective_at=v_now,
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company;
  v_preview:=private.get_sales_process_cutover_preview_core(
    v_company,'RETAIL_CONFIRM_INVOICE');
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_preview->'candidates') candidate
    WHERE candidate->>'sourceDocumentId'=v_future_non_tempo::text
      AND candidate->>'decision'='BLOCKED'
      AND candidate->'blockerCodes' ? 'FUTURE_NON_TEMPO_MUST_FINISH_IN_BACKOFFICE') THEN
    RAISE EXCEPTION 'TEST_FAILED: future non-TEMPO preview blocker missing: %',v_preview;
  END IF;

  SELECT jsonb_build_object('stock',(SELECT COALESCE(sum(stock_qty),0)
      FROM public.product_stocks WHERE company_id=v_company),
    'movements',(SELECT count(*) FROM public.stock_movements WHERE company_id=v_company),
    'fifo',(SELECT count(*) FROM public.sale_fifo_allocations WHERE company_id=v_company),
    'events',(SELECT count(*) FROM public.financial_events WHERE company_id=v_company),
    'journals',(SELECT count(*) FROM public.journal_entries WHERE company_id=v_company),
    'retailInvoices',(SELECT count(*) FROM public.sales_invoice_snapshots WHERE company_id=v_company))
    INTO v_after;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'TEST_FAILED: forbidden Stock/FIFO/Invoice/Finance effect: before %, after %',
      v_before,v_after;
  END IF;
END
$test$;
ROLLBACK;

SELECT 'sales_process_cutover_backoffice_to_retail_converter_behavior' check_name,
  'PASS' status,0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'self-created Backoffice Draft maps to Retail Draft','source Draft closes atomically',
    'confirmed future TEMPO maps to Scheduled Retail Draft','Backoffice Reservation released',
    'Backoffice initial DO canceled','confirmed source CANCEL operation/audit FK lineage',
    'target has no Reservation/SJ/Invoice before confirmation',
    'future non-TEMPO preview is blocked','exact retry and operation conflict enforced',
    'commercial total and source lineage preserved','zero Stock/FIFO/Invoice/Finance effect'),
    'transactionEnd','ROLLBACK') details;
