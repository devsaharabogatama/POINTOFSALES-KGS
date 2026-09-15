BEGIN;
DO $test$
DECLARE v_company constant uuid:='d290f1ee-6c54-4b01-90e6-d701748f0851';
  v_actor constant uuid:='08fc496d-af34-4d7e-8aad-4afe3762f1e0';
  v_document public.supplier_order_documents%rowtype;v_line public.supplier_order_lines%rowtype;
  v_warehouse uuid;v_operation uuid:=gen_random_uuid();v_result jsonb;v_before jsonb;
  v_stock bigint;v_events bigint;v_bills bigint;v_stale_rejected boolean:=false;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914170000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20260914170000 required';
  END IF;
  SELECT * INTO v_document FROM public.supplier_order_documents document
  WHERE document.company_id=v_company AND document.order_source='DAILY_REPLENISHMENT'
    AND document.status='CONFIRMED'
    AND NOT EXISTS(SELECT 1 FROM public.goods_receipt_documents receipt
      WHERE receipt.company_id=document.company_id AND receipt.supplier_order_id=document.id
        AND receipt.status<>'CANCELED')
  ORDER BY document.order_no LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: unreceived confirmed daily PO required'; END IF;
  SELECT * INTO STRICT v_line FROM public.supplier_order_lines line
  WHERE line.company_id=v_company AND line.document_id=v_document.id
  ORDER BY line.line_no LIMIT 1;
  SELECT setting.default_purchase_receipt_warehouse_id INTO STRICT v_warehouse
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company;
  SELECT count(*) INTO v_stock FROM public.stock_movements WHERE company_id=v_company;
  SELECT count(*) INTO v_events FROM public.financial_events WHERE company_id=v_company;
  SELECT count(*) INTO v_bills FROM public.supplier_invoice_documents WHERE company_id=v_company;
  v_before:=private.purchase_supplier_order_document_snapshot(v_company,v_document.id);
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  PERFORM set_config('request.jwt.claim.role','authenticated',true);
  v_result:=public.revise_purchase_supplier_order(v_document.id,v_document.master_version,
    v_operation,v_document.supplier_id,v_document.order_date+1,'Rollback-only PO revision test',
    jsonb_build_array(jsonb_build_object('lineId',v_line.id,'productId',v_line.product_id,
      'uomId',v_line.ordered_uom_id,'destinationWarehouseId',v_warehouse,
      'quantity',v_line.ordered_qty+1,'estimatedUnitPrice',v_line.estimated_unit_price+1)));
  IF v_result->>'status'<>'CONFIRMED'
    OR (v_result->>'masterVersion')::bigint<>v_document.master_version+1
    OR NOT EXISTS(SELECT 1 FROM public.supplier_order_lines line
      WHERE line.company_id=v_company AND line.id=v_line.id
        AND line.ordered_qty=v_line.ordered_qty+1
        AND line.destination_warehouse_id=v_warehouse)
    OR NOT EXISTS(SELECT 1 FROM public.supplier_order_audit audit
      WHERE audit.company_id=v_company AND audit.document_id=v_document.id
        AND audit.action='UPDATE' AND audit.before_state=v_before)
    OR NOT EXISTS(SELECT 1 FROM public.purchase_supplier_order_revision_operations operation
      WHERE operation.company_id=v_company AND operation.id=v_operation) THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical PO revision state invalid';
  END IF;
  v_result:=public.revise_purchase_supplier_order(v_document.id,v_document.master_version,
    v_operation,v_document.supplier_id,v_document.order_date+1,'Rollback-only PO revision test',
    jsonb_build_array(jsonb_build_object('lineId',v_line.id,'productId',v_line.product_id,
      'uomId',v_line.ordered_uom_id,'destinationWarehouseId',v_warehouse,
      'quantity',v_line.ordered_qty+1,'estimatedUnitPrice',v_line.estimated_unit_price+1)));
  IF COALESCE((v_result->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry not returned'; END IF;
  BEGIN
    PERFORM public.revise_purchase_supplier_order(v_document.id,v_document.master_version,
      gen_random_uuid(),v_document.supplier_id,v_document.order_date+1,NULL,
      jsonb_build_array(jsonb_build_object('lineId',v_line.id,'productId',v_line.product_id,
        'uomId',v_line.ordered_uom_id,'destinationWarehouseId',v_warehouse,
        'quantity',v_line.ordered_qty,'estimatedUnitPrice',v_line.estimated_unit_price)));
  EXCEPTION WHEN OTHERS THEN
    v_stale_rejected:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%';
  END;
  IF NOT v_stale_rejected THEN RAISE EXCEPTION 'TEST_FAILED: stale version accepted'; END IF;
  IF (SELECT count(*) FROM public.stock_movements WHERE company_id=v_company)<>v_stock
    OR (SELECT count(*) FROM public.financial_events WHERE company_id=v_company)<>v_events
    OR (SELECT count(*) FROM public.supplier_invoice_documents WHERE company_id=v_company)<>v_bills THEN
    RAISE EXCEPTION 'TEST_FAILED: revision created downstream financial or stock effects';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'purchase_order_pre_receipt_revision_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'confirmed daily PO revision','line quantity/warehouse update','audit','exact retry',
    'stale version rejection','zero Stock/Finance/Bill effect','rollback')) details;
