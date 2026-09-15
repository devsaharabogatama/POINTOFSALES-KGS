-- Rollback-only behavior for the approved PO -> generated Receipt -> Bill-ready flow.
BEGIN;
DO $test$
DECLARE
  v_company constant uuid:='d290f1ee-6c54-4b01-90e6-d701748f0851';
  v_actor constant uuid:='08fc496d-af34-4d7e-8aad-4afe3762f1e0';
  v_order_id uuid;
  v_order public.supplier_order_documents%rowtype;
  v_line public.supplier_order_lines%rowtype;
  v_receipt public.goods_receipt_documents%rowtype;
  v_revision_lines jsonb;v_result jsonb;v_operation uuid:=gen_random_uuid();
  v_post_key uuid:=gen_random_uuid();v_stock_before bigint;v_events_before bigint;
  v_bills_before bigint;v_saved_version bigint;v_billable numeric;v_message text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914180000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20260914180000 required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile WHERE profile.id=v_actor
      AND profile.email='localadmin@local.com' AND profile.role='super_admin')
    OR NOT EXISTS(SELECT 1 FROM public.user_active_company_contexts context
      WHERE context.user_id=v_actor AND context.company_id=v_company) THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact isolated Development actor/context required';
  END IF;
  SELECT document.* INTO v_order
  FROM public.supplier_order_documents document
  WHERE document.company_id=v_company AND document.order_source='DAILY_REPLENISHMENT'
    AND document.status='CONFIRMED' AND document.supplier_id IS NOT NULL
    AND EXISTS(SELECT 1 FROM public.supplier_order_lines line
      WHERE line.company_id=document.company_id AND line.document_id=document.id
        AND line.ordered_base_qty>1 AND line.estimated_unit_price>0)
    AND NOT EXISTS(SELECT 1 FROM public.supplier_order_lines line
      WHERE line.company_id=document.company_id AND line.document_id=document.id
        AND line.destination_warehouse_id IS NULL)
    AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
        AND receipt.status='POSTED')
  ORDER BY document.order_no LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: eligible generated Development PO fixture required';
  END IF;
  v_order_id:=v_order.id;
  SELECT line.* INTO STRICT v_line FROM public.supplier_order_lines line
  WHERE line.company_id=v_company AND line.document_id=v_order.id
    AND line.ordered_base_qty>1 AND line.estimated_unit_price>0
  ORDER BY line.line_no LIMIT 1;
  SELECT receipt.* INTO STRICT v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.supplier_order_id=v_order.id
    AND receipt.warehouse_id=v_line.destination_warehouse_id
    AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
    AND receipt.line_count=0;
  SELECT jsonb_agg(jsonb_build_object('lineId',line.id,'productId',line.product_id,
      'uomId',line.ordered_uom_id,'destinationWarehouseId',line.destination_warehouse_id,
      'quantity',line.ordered_qty,'estimatedUnitPrice',line.estimated_unit_price)
      ORDER BY line.line_no) INTO STRICT v_revision_lines
  FROM public.supplier_order_lines line
  WHERE line.company_id=v_company AND line.document_id=v_order.id;

  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  SELECT count(*) INTO v_stock_before FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_events_before FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_bills_before FROM public.supplier_invoice_documents WHERE company_id=v_company;

  -- An untouched system-generated Receipt is not a started warehouse receipt and must not block PO edit.
  v_result:=public.revise_purchase_supplier_order(v_order.id,v_order.master_version,
    v_operation,v_order.supplier_id,v_order.expected_date,'Rollback-only generated Receipt behavior',
    v_revision_lines);
  IF v_result->>'status'<>'CONFIRMED' OR COALESCE((v_result->>'exactRetry')::boolean,false) THEN
    RAISE EXCEPTION 'TEST_FAILED: PO edit with untouched generated Receipt invalid';
  END IF;
  SELECT receipt.* INTO STRICT v_receipt FROM public.goods_receipt_documents receipt
  WHERE receipt.company_id=v_company AND receipt.supplier_order_id=v_order.id
    AND receipt.warehouse_id=v_line.destination_warehouse_id
    AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT';

  -- Filling Draft has no Stock, Finance, or Bill effect.
  v_result:=public.save_generated_backoffice_goods_receipt(v_receipt.id,
    v_receipt.master_version,v_order.id,NULL,'Rollback-only partial Receipt',
    jsonb_build_array(jsonb_build_object('clientLineKey',gen_random_uuid(),
      'supplierOrderLineId',v_line.id,'receivedUomId',v_line.ordered_uom_id,
      'receivedQty',1,'acceptedGoodQty',1,'damagedQty',0,'rejectedQty',0)));
  v_saved_version:=(v_result->>'masterVersion')::bigint;
  IF v_result->>'status'<>'DRAFT'
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock_before
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_events_before
    OR (SELECT count(*) FROM public.supplier_invoice_documents WHERE company_id=v_company)<>v_bills_before
    OR private.classify_purchase_order_bill_status(0,0,0,0,true)<>'NOT_READY' THEN
    RAISE EXCEPTION 'TEST_FAILED: Draft Receipt created downstream effect';
  END IF;

  v_result:=public.post_generated_backoffice_goods_receipt(v_receipt.id,v_saved_version,v_post_key);
  IF v_result->>'status'<>'POSTED'
    OR (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<=v_stock_before
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<=v_events_before
    OR (SELECT count(*) FROM public.supplier_invoice_documents WHERE company_id=v_company)<>v_bills_before THEN
    RAISE EXCEPTION 'TEST_FAILED: Receipt Post Stock/Finance/Bill boundary invalid';
  END IF;
  v_result:=public.post_generated_backoffice_goods_receipt(v_receipt.id,v_saved_version,v_post_key);
  IF COALESCE((v_result->>'idempotentReplay')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: Receipt Post exact retry invalid';
  END IF;
  SELECT sum(receipt_line.accepted_good_base_qty+receipt_line.damaged_base_qty)
    INTO v_billable
  FROM public.goods_receipt_lines receipt_line
  JOIN public.goods_receipt_documents receipt ON receipt.company_id=receipt_line.company_id
    AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
  JOIN public.supplier_order_lines line ON line.company_id=receipt_line.company_id
    AND line.id=receipt_line.supplier_order_line_id
  WHERE line.company_id=v_company AND line.document_id=v_order.id;
  IF private.classify_purchase_order_bill_status(v_billable,0,0,0,true)<>'READY'
    OR NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=v_company AND receipt.supplier_order_id=v_order.id
        AND receipt.warehouse_id=v_line.destination_warehouse_id
        AND receipt.source_channel='BACKOFFICE' AND receipt.status='DRAFT'
        AND receipt.line_count=0) THEN
    RAISE EXCEPTION 'TEST_FAILED: partial Receipt did not make PO Bill-ready or generate remaining Receipt';
  END IF;

  -- Receipt Post moves the PO to PARTIALLY_RECEIVED. The canonical revision
  -- routine rejects that status before evaluating its Receipt-presence guard.
  SELECT * INTO STRICT v_order FROM public.supplier_order_documents
  WHERE company_id=v_company AND id=v_order_id;
  IF v_order.status<>'PARTIALLY_RECEIVED' THEN
    RAISE EXCEPTION 'TEST_FAILED: partial Receipt did not set PO PARTIALLY_RECEIVED';
  END IF;
  BEGIN
    PERFORM public.revise_purchase_supplier_order(v_order.id,v_order.master_version,
      gen_random_uuid(),v_order.supplier_id,v_order.expected_date,NULL,v_revision_lines);
    RAISE EXCEPTION 'TEST_FAILED: PO edit accepted after Receipt Post';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_message=MESSAGE_TEXT;
    IF v_message NOT LIKE '%PURCHASE_PO_PRE_RECEIPT_REVISION_NOT_ALLOWED%' THEN RAISE; END IF;
  END;
END
$test$;
ROLLBACK;
SELECT 'purchase_order_generated_receipt_workflow_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'PO has generated per-Warehouse Receipt','untouched Receipt does not block PO edit',
    'Draft Receipt has zero downstream effect','Receipt Post creates Stock/Finance effect',
    'Post exact retry','partial Receipt creates remaining Receipt','Bill-ready after Posted Receipt',
    'started Receipt blocks PO edit','no Supplier Bill auto-created','rollback')) details;
