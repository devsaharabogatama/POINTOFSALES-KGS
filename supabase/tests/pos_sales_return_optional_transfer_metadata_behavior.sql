-- Authenticated rollback-only behavior for optional Sales Return Transfer
-- metadata. Exercises both blank metadata and populated metadata through the
-- direct Retail POS path; all business effects are rolled back.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_actor uuid;v_session uuid;v_store uuid;v_sale uuid;
  v_payment uuid;v_workspace jsonb;v_sale_json jsonb;v_line jsonb;
  v_lines jsonb;v_refunds jsonb;v_result jsonb;v_retry jsonb;
  v_document uuid;v_qty numeric;v_refund numeric;
  v_operation uuid;v_refund_key uuid;
  v_changed_rejected boolean:=false;v_blank_case_rolled_back boolean:=false;
  v_before_events bigint;v_before_movements bigint;v_before_restorations bigint;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20261102100000','20261102110000'))<>2 THEN
    RAISE EXCEPTION
      'TEST_PRECONDITION_FAILED: direct Return and optional metadata migrations required';
  END IF;

  SELECT session.company_id,session.cashier_id,session.id,session.store_id
  INTO v_company,v_actor,v_session,v_store
  FROM public.cashier_sessions session
  JOIN public.company_sales_process_settings setting
    ON setting.company_id=session.company_id
    AND setting.active_mode='RETAIL_CONFIRM_INVOICE'
  WHERE session.status='OPEN'::public.session_status
    AND EXISTS(SELECT 1 FROM auth.users auth_user
      WHERE auth_user.id=session.cashier_id)
    AND EXISTS(SELECT 1 FROM public.payment_methods method
      WHERE method.company_id=session.company_id AND method.is_active
        AND method.method_type='TRANSFER'
        AND method.effective_from<=clock_timestamp()
        AND (method.effective_to IS NULL
          OR method.effective_to>=clock_timestamp())
        AND (method.available_all_stores OR EXISTS(
          SELECT 1 FROM public.payment_method_store_assignments assignment
          WHERE assignment.company_id=method.company_id
            AND assignment.payment_method_id=method.id
            AND assignment.store_id=session.store_id)))
    AND EXISTS(SELECT 1 FROM public.sales_headers sale
      JOIN public.sales_details detail ON detail.company_id=sale.company_id
        AND detail.sales_id=sale.id
      JOIN public.sale_stock_requirements requirement
        ON requirement.company_id=detail.company_id
        AND requirement.sales_detail_id=detail.id
      WHERE sale.company_id=session.company_id AND sale.store_id=session.store_id
        AND sale.sales_origin='POS'
        AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
        AND sale.document_status='POSTED'
        AND EXISTS(SELECT 1 FROM public.sale_fifo_allocations allocation
          WHERE allocation.company_id=requirement.company_id
            AND allocation.stock_requirement_id=requirement.id))
  ORDER BY session.id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: open Retail POS Session, Transfer method and FIFO Sale required';
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM public.set_active_company_context(v_company,'POS_RETURN_TEST');

  v_workspace:=public.get_pos_returnable_sales(NULL,100);
  SELECT candidate.value INTO v_sale_json
  FROM jsonb_array_elements(v_workspace->'sales') candidate
  WHERE EXISTS(SELECT 1 FROM public.sales_details detail
    JOIN public.sale_stock_requirements requirement
      ON requirement.company_id=detail.company_id
      AND requirement.sales_detail_id=detail.id
    WHERE detail.company_id=v_company
      AND detail.sales_id=(candidate.value->>'id')::uuid
      AND EXISTS(SELECT 1 FROM public.sale_fifo_allocations allocation
        WHERE allocation.company_id=requirement.company_id
          AND allocation.stock_requirement_id=requirement.id))
  ORDER BY candidate.value->>'transaction_date' DESC LIMIT 1;
  IF v_sale_json IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: returnable Retail FIFO Sale required'; END IF;
  v_sale:=(v_sale_json->>'id')::uuid;

  SELECT line.value INTO v_line FROM jsonb_array_elements(v_sale_json->'lines') line
  WHERE EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=v_company
      AND requirement.sales_detail_id=(line.value->>'sourceSalesDetailId')::uuid
      AND EXISTS(SELECT 1 FROM public.sale_fifo_allocations allocation
        WHERE allocation.company_id=requirement.company_id
          AND allocation.stock_requirement_id=requirement.id))
  ORDER BY line.value->>'sourceSalesDetailId' LIMIT 1;
  IF v_line IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: returnable FIFO line required'; END IF;
  v_qty:=round((v_line->>'remainingQuantity')::numeric/2,6);
  IF v_qty<=0 THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: positive partial Return quantity required'; END IF;
  v_refund:=round((v_line->>'refundableLineAmount')::numeric*v_qty/
    (v_line->>'soldQuantity')::numeric,4);
  IF v_refund<=0 THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: positive partial refund required'; END IF;

  SELECT method.id INTO v_payment FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.method_type='TRANSFER'
    AND method.effective_from<=clock_timestamp()
    AND (method.effective_to IS NULL OR method.effective_to>=clock_timestamp())
    AND (method.available_all_stores OR EXISTS(
      SELECT 1 FROM public.payment_method_store_assignments assignment
      WHERE assignment.company_id=method.company_id
        AND assignment.payment_method_id=method.id
        AND assignment.store_id=v_store))
  ORDER BY method.is_default DESC,method.id LIMIT 1;
  IF v_payment IS NULL THEN RAISE EXCEPTION
    'TEST_PRECONDITION_FAILED: active Transfer refund method required'; END IF;

  v_lines:=jsonb_build_array(jsonb_build_object(
    'sourceSalesDetailId',v_line->>'sourceSalesDetailId','quantity',v_qty,
    'condition','SALEABLE','destinationWarehouseId',NULL));
  SELECT count(*) INTO v_before_events FROM public.financial_events
    WHERE company_id=v_company AND source_table='sales_return_documents';
  SELECT count(*) INTO v_before_movements FROM public.stock_movements
    WHERE company_id=v_company AND reference_table='sales_return_documents';
  SELECT count(*) INTO v_before_restorations
    FROM public.sales_return_fifo_restorations WHERE company_id=v_company;

  -- Case 1: blank strings must be accepted and stored as NULL. The nested
  -- subtransaction is deliberately rolled back so the same source can also
  -- prove populated metadata preservation below.
  BEGIN
    v_operation:=gen_random_uuid();v_refund_key:=gen_random_uuid();
    v_refunds:=jsonb_build_array(jsonb_build_object(
      'clientRefundKey',v_refund_key,'paymentMethodId',v_payment,
      'amount',v_refund,'transferDestination','','transferReference','',
      'proofUrl',NULL));
    v_result:=public.submit_pos_sales_return_with_delivery_fee(
      v_sale,v_session,'NONE','Rollback optional Transfer metadata behavior',
      v_lines,v_refunds,false,v_operation);
    v_document:=(v_result->>'documentId')::uuid;
    IF v_result->>'status'<>'POSTED' OR v_result->>'approvalMode'<>'OPTIONAL'
      OR NOT EXISTS(SELECT 1 FROM public.sales_return_refunds refund
        WHERE refund.company_id=v_company AND refund.document_id=v_document
          AND refund.payment_method_type_snapshot='TRANSFER'
          AND refund.transfer_destination IS NULL
          AND refund.transfer_reference IS NULL
          AND refund.proof_url IS NULL) THEN
      RAISE EXCEPTION
        'TEST_FAILED: blank Transfer metadata was not normalized to NULL';
    END IF;
    v_retry:=public.submit_pos_sales_return_with_delivery_fee(
      v_sale,v_session,'NONE','Rollback optional Transfer metadata behavior',
      v_lines,v_refunds,false,v_operation);
    IF NOT (v_retry->>'idempotentReplay')::boolean
      OR (v_retry->>'documentId')::uuid<>v_document THEN
      RAISE EXCEPTION 'TEST_FAILED: optional metadata exact retry duplicated Return';
    END IF;
    BEGIN
      PERFORM public.submit_pos_sales_return_with_delivery_fee(
        v_sale,v_session,'NONE','Changed retry must fail',
        v_lines,v_refunds,false,v_operation);
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM='POS_SALES_RETURN_CHANGED_RETRY' THEN
        v_changed_rejected:=true;
      ELSE RAISE; END IF;
    END;
    IF NOT v_changed_rejected THEN RAISE EXCEPTION
      'TEST_FAILED: changed retry was accepted'; END IF;
    RAISE EXCEPTION 'ROLLBACK_BLANK_METADATA_CASE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='ROLLBACK_BLANK_METADATA_CASE' THEN
      v_blank_case_rolled_back:=true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_blank_case_rolled_back THEN RAISE EXCEPTION
    'TEST_FAILED: blank metadata subtransaction did not roll back'; END IF;

  -- Case 2: provided metadata must remain exact and all canonical downstream
  -- effects must still occur.
  v_operation:=gen_random_uuid();v_refund_key:=gen_random_uuid();
  v_refunds:=jsonb_build_array(jsonb_build_object(
    'clientRefundKey',v_refund_key,'paymentMethodId',v_payment,
    'amount',v_refund,'transferDestination','BCA QA 123',
    'transferReference','QA-TRANSFER-001',
    'proofUrl','https://example.test/return-proof'));
  v_result:=public.submit_pos_sales_return_with_delivery_fee(
    v_sale,v_session,'NONE','Rollback populated Transfer metadata behavior',
    v_lines,v_refunds,false,v_operation);
  v_document:=(v_result->>'documentId')::uuid;
  IF v_result->>'status'<>'POSTED' OR v_result->>'approvalMode'<>'OPTIONAL'
    OR NOT EXISTS(SELECT 1 FROM public.sales_return_refunds refund
      WHERE refund.company_id=v_company AND refund.document_id=v_document
        AND refund.payment_method_type_snapshot='TRANSFER'
        AND refund.transfer_destination='BCA QA 123'
        AND refund.transfer_reference='QA-TRANSFER-001'
        AND refund.proof_url='https://example.test/return-proof')
    OR (SELECT count(*) FROM public.financial_events
      WHERE company_id=v_company
        AND source_table='sales_return_documents')<>v_before_events+1
    OR (SELECT count(*) FROM public.stock_movements
      WHERE company_id=v_company
        AND reference_table='sales_return_documents')<=v_before_movements
    OR (SELECT count(*) FROM public.sales_return_fifo_restorations
      WHERE company_id=v_company)<=v_before_restorations THEN
    RAISE EXCEPTION
      'TEST_FAILED: populated metadata or downstream effects were not preserved';
  END IF;

  RAISE NOTICE 'pos_sales_return_optional_transfer_metadata_behavior PASS: %',
    jsonb_build_object(
      'blankMetadataNormalized',true,
      'populatedMetadataPreserved',true,
      'retailDirectFinalization',true,
      'stockMovement',true,'fifoRestoration',true,'financeEvent',true,
      'exactRetry',true,'changedRetryRejected',true,'rollback',true);
END
$test$;

ROLLBACK;
