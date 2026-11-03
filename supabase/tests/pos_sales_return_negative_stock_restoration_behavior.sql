-- Authenticated rollback-only behavior for the exact negative-stock Return
-- failure reported on INV-20261101-0000000951. No business effect persists.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_actor uuid;v_session uuid;v_store uuid;v_sale uuid;
  v_workspace jsonb;v_sale_json jsonb;v_line jsonb;v_payment uuid;
  v_lines jsonb;v_refunds jsonb;v_result jsonb;v_retry jsonb;
  v_operation uuid:=gen_random_uuid();v_refund_key uuid:=gen_random_uuid();
  v_document uuid;v_negative uuid;v_requirement uuid;
  v_qty numeric;v_refund numeric;v_provisional numeric;
  v_before_replenished numeric;v_before_stock numeric;v_before_events bigint;
  v_after_stock numeric;v_return_line uuid;v_restoration uuid;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102120000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: negative Return migration missing';
  END IF;
  SELECT sale.company_id,sale.store_id,sale.id,requirement.id,negative.id,
    negative.provisional_unit_cost,negative.replenished_base_qty
  INTO v_company,v_store,v_sale,v_requirement,v_negative,v_provisional,
    v_before_replenished
  FROM public.sales_headers sale
  JOIN public.sales_details detail ON detail.company_id=sale.company_id
    AND detail.sales_id=sale.id
  JOIN public.sale_stock_requirements requirement
    ON requirement.company_id=detail.company_id
   AND requirement.sales_detail_id=detail.id
  JOIN public.negative_stock_sale_allocations negative
    ON negative.company_id=requirement.company_id
   AND negative.stock_requirement_id=requirement.id
  WHERE sale.invoice_no='INV-20261101-0000000951'
    AND sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND negative.shortage_base_qty-negative.replenished_base_qty=5;
  IF NOT FOUND THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: exact unreplenished invoice 0951 fixture changed'; END IF;

  SELECT session.cashier_id,session.id INTO v_actor,v_session
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.store_id=v_store
    AND session.status='OPEN'::public.session_status
    AND EXISTS(SELECT 1 FROM auth.users auth_user
      WHERE auth_user.id=session.cashier_id)
  ORDER BY session.opened_at DESC,session.id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: exact Company/Store needs an authenticated OPEN Session'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM public.set_active_company_context(v_company,'POS_RETURN_TEST');

  v_workspace:=public.get_pos_returnable_sales('INV-20261101-0000000951',10);
  SELECT candidate.value INTO v_sale_json
  FROM jsonb_array_elements(v_workspace->'sales') candidate
  WHERE (candidate.value->>'id')::uuid=v_sale;
  IF v_sale_json IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: exact invoice is no longer returnable'; END IF;
  SELECT candidate.value INTO v_line
  FROM jsonb_array_elements(v_sale_json->'lines') candidate
  WHERE EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=v_company AND requirement.id=v_requirement
      AND requirement.sales_detail_id=(candidate.value->>'sourceSalesDetailId')::uuid);
  IF v_line IS NULL OR (v_line->>'remainingQuantity')::numeric<5 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact line no longer has five returnable units';
  END IF;
  v_qty:=5;
  v_refund:=round((v_line->>'refundableLineAmount')::numeric*v_qty/
    (v_line->>'soldQuantity')::numeric,4);

  SELECT method.id INTO v_payment FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.method_type IN('CASH','TRANSFER')
    AND method.effective_from<=clock_timestamp()
    AND (method.effective_to IS NULL OR method.effective_to>=clock_timestamp())
    AND (method.available_all_stores OR EXISTS(
      SELECT 1 FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=method.company_id
        AND assignment.payment_method_id=method.id
        AND assignment.store_id=v_store))
  ORDER BY (method.method_type='TRANSFER') DESC,method.is_default DESC,method.id
  LIMIT 1;
  IF v_payment IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: active Cash or Transfer refund method required'; END IF;

  v_lines:=jsonb_build_array(jsonb_build_object(
    'sourceSalesDetailId',v_line->>'sourceSalesDetailId','quantity',v_qty,
    'condition','SALEABLE','destinationWarehouseId',NULL));
  v_refunds:=jsonb_build_array(jsonb_build_object(
    'clientRefundKey',v_refund_key,'paymentMethodId',v_payment,'amount',v_refund,
    'transferDestination',NULL,'transferReference',NULL,'proofUrl',NULL));
  SELECT stock.stock_qty INTO v_before_stock
  FROM public.sale_stock_requirements requirement
  LEFT JOIN public.product_stocks stock
    ON stock.company_id=requirement.company_id
   AND stock.product_id=requirement.stock_product_id
   AND stock.warehouse_id=(SELECT warehouse_id
     FROM public.negative_stock_sale_allocations WHERE company_id=v_company AND id=v_negative)
  WHERE requirement.company_id=v_company AND requirement.id=v_requirement;
  v_before_stock:=COALESCE(v_before_stock,0);
  SELECT count(*) INTO v_before_events FROM public.financial_events
  WHERE company_id=v_company AND source_table='sales_return_documents';

  v_result:=public.submit_pos_sales_return_with_delivery_fee(v_sale,v_session,
    'NONE','Rollback negative-stock Return behavior',v_lines,v_refunds,false,
    v_operation);
  v_document:=(v_result->>'documentId')::uuid;
  IF v_result->>'status'<>'POSTED' THEN RAISE EXCEPTION
    'TEST_FAILED: exact negative-stock Return was not Posted'; END IF;
  SELECT line.id INTO STRICT v_return_line FROM public.sales_return_lines line
  WHERE line.company_id=v_company AND line.document_id=v_document;
  SELECT restoration.id INTO STRICT v_restoration
  FROM public.sales_return_negative_stock_restorations restoration
  WHERE restoration.company_id=v_company AND restoration.document_id=v_document
    AND restoration.return_line_id=v_return_line
    AND restoration.source_negative_allocation_id=v_negative
    AND restoration.source_mode='OUTSTANDING_PROVISIONAL'
    AND restoration.quantity_base=5
    AND restoration.unit_cost=v_provisional;
  SELECT stock.stock_qty INTO STRICT v_after_stock
  FROM public.sale_stock_requirements requirement
  JOIN public.negative_stock_sale_allocations negative
    ON negative.company_id=requirement.company_id AND negative.id=v_negative
  JOIN public.product_stocks stock ON stock.company_id=requirement.company_id
    AND stock.product_id=requirement.stock_product_id
    AND stock.warehouse_id=negative.warehouse_id
  WHERE requirement.company_id=v_company AND requirement.id=v_requirement;

  IF (SELECT replenished_base_qty FROM public.negative_stock_sale_allocations
      WHERE company_id=v_company AND id=v_negative)<>v_before_replenished+5
    OR v_after_stock<>v_before_stock+5
    OR NOT EXISTS(SELECT 1 FROM public.product_batches batch
      WHERE batch.company_id=v_company
        AND batch.sales_return_negative_allocation_id=v_negative
        AND batch.sales_return_line_id=v_return_line
        AND batch.qty_purchased=5 AND batch.qty_remaining=0)
    OR NOT EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=v_company
        AND movement.reference_table='sales_return_documents'
        AND movement.reference_id=v_document AND movement.source_line_id=v_restoration
        AND movement.qty_change=5)
    OR (SELECT fifo_cost_restored FROM public.sales_return_lines
      WHERE company_id=v_company AND id=v_return_line)<>round(5*v_provisional,4)
    OR (SELECT count(*) FROM public.financial_events
      WHERE company_id=v_company
        AND source_table='sales_return_documents')<>v_before_events+1 THEN
    RAISE EXCEPTION 'TEST_FAILED: negative Return Stock/HPP/Finance lineage incomplete';
  END IF;

  v_retry:=public.submit_pos_sales_return_with_delivery_fee(v_sale,v_session,
    'NONE','Rollback negative-stock Return behavior',v_lines,v_refunds,false,
    v_operation);
  IF NOT (v_retry->>'idempotentReplay')::boolean
    OR (v_retry->>'documentId')::uuid<>v_document THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry duplicated negative Return';
  END IF;

  RAISE NOTICE 'pos_sales_return_negative_stock_restoration_behavior PASS: %',
    jsonb_build_object('tested',jsonb_build_array(
      'installed exact forward migration','authenticated exact invoice 0951',
      'exact source shortage closure','targeted batch consumed to zero',
      'Product Stock and movement once','provisional HPP reversal',
      'Finance Event','exact retry idempotency','all effects rolled back'));
END
$test$;

ROLLBACK;
