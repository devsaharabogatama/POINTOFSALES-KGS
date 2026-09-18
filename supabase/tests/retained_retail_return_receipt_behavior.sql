-- Authenticated rollback-only behavior for retained Retail physical receipt.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_sale uuid;v_detail uuid;v_qty numeric;
 v_warehouse uuid;v_product uuid;v_saved jsonb;v_submitted jsonb;v_approved jsonb;
 v_receipt jsonb;v_retry jsonb;v_return uuid;v_return_line uuid;v_operation uuid:=gen_random_uuid();
 v_stock_before numeric;v_event_before bigint;v_journal_before bigint;v_native_before bigint;
 v_today date;v_payload_conflict boolean:=false;v_stale_rejected boolean:=false;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260918130000') THEN
  RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: retained Retail receipt bridge required'; END IF;
 SELECT profile.id INTO STRICT v_actor FROM public.profiles profile JOIN auth.users auth_user
  ON auth_user.id=profile.id WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
 SELECT sale.company_id,sale.id,detail.id,detail.product_id,
  least(detail.qty,available.base_qty/detail.uom_factor_to_base_snapshot)
 INTO STRICT v_company,v_sale,v_detail,v_product,v_qty
 FROM public.sales_headers sale JOIN public.company_sales_process_settings setting
  ON setting.company_id=sale.company_id AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
 JOIN public.sales_details detail ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
 JOIN LATERAL(SELECT detail.quantity_base
   -COALESCE((SELECT sum(line.quantity_base) FROM public.sales_return_lines line
    JOIN public.sales_return_documents document ON document.company_id=line.company_id
     AND document.id=line.document_id WHERE line.company_id=detail.company_id
     AND line.source_sales_detail_id=detail.id AND document.status='POSTED'),0)
   -COALESCE((SELECT sum(line.requested_base_qty) FROM public.backoffice_sales_return_lines line
    JOIN public.backoffice_sales_returns document ON document.company_id=line.company_id
     AND document.id=line.return_id WHERE line.company_id=detail.company_id
     AND line.retail_sales_detail_id=detail.id AND document.status NOT IN('DRAFT','CANCELED')),0)
   base_qty) available ON true
 WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE' AND sale.document_status<>'CANCELED'
  AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED'
   OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
      AND delivery.status='DELIVERED'))
  AND available.base_qty>0 AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_items item
   JOIN public.sales_process_cutover_audit audit ON audit.company_id=item.company_id
    AND audit.cutover_item_id=item.id WHERE item.company_id=sale.company_id
    AND item.source_document_id=sale.id AND item.source_document_type='RETAIL_SALE'
    AND audit.action='APPLY_ITEM'
    AND audit.after_state->'converterResult'->>'targetDocumentType'='BACKOFFICE_SALES_ORDER'
    AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','') IS NOT NULL)
  AND (SELECT count(*) FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=detail.company_id
      AND requirement.sales_detail_id=detail.id)=1
  AND EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=detail.company_id
      AND requirement.sales_detail_id=detail.id
      AND requirement.commercial_product_id=detail.product_id
      AND requirement.stock_product_id=detail.product_id)
 ORDER BY sale.created_at DESC,detail.id LIMIT 1;
 SELECT id INTO STRICT v_warehouse FROM public.warehouses WHERE company_id=v_company
  AND is_active ORDER BY is_purchase_destination DESC,id LIMIT 1;
 SELECT (clock_timestamp() AT TIME ZONE timezone)::date INTO STRICT v_today
  FROM public.companies WHERE id=v_company AND status='ACTIVE';
 PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
 INSERT INTO public.user_active_company_contexts(user_id,company_id) VALUES(v_actor,v_company)
 ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
  selected_at=clock_timestamp(),updated_at=clock_timestamp();
 SELECT COALESCE(stock_qty,0) INTO v_stock_before FROM public.product_stocks
  WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_warehouse;
 v_stock_before:=COALESCE(v_stock_before,0);
 SELECT count(*) INTO v_event_before FROM public.financial_events;
 SELECT count(*) INTO v_journal_before FROM public.finance_journals;
 SELECT count(*) INTO v_native_before FROM public.sales_return_documents;
 v_saved:=public.save_retained_retail_backoffice_return_draft(NULL,NULL,gen_random_uuid(),v_sale,
  jsonb_build_object('reason','Retained receipt rollback-only test','lines',jsonb_build_array(
   jsonb_build_object('retailSalesDetailId',v_detail,'quantityUom',v_qty))));
 v_return:=(v_saved->'data'->>'id')::uuid;
 SELECT id INTO STRICT v_return_line FROM public.backoffice_sales_return_lines
  WHERE company_id=v_company AND return_id=v_return;
 v_submitted:=public.submit_backoffice_sales_return(v_return,
  (v_saved->'data'->>'masterVersion')::bigint,gen_random_uuid());
 v_approved:=public.approve_backoffice_sales_return(v_return,
  (v_submitted->'data'->>'masterVersion')::bigint,gen_random_uuid());
 v_receipt:=public.post_backoffice_sales_return_receipt(v_return,
  (v_approved->'data'->>'masterVersion')::bigint,v_operation,v_today,
  jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,'quantityUom',v_qty,
   'warehouseId',v_warehouse,'disposition','RESTOCK','notes','Rollback-only')),NULL);
 v_retry:=public.post_backoffice_sales_return_receipt(v_return,
  (v_approved->'data'->>'masterVersion')::bigint,v_operation,v_today,
  jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,'quantityUom',v_qty,
   'warehouseId',v_warehouse,'disposition','RESTOCK','notes','Rollback-only')),NULL);
 BEGIN
  PERFORM public.post_backoffice_sales_return_receipt(v_return,
   (v_approved->'data'->>'masterVersion')::bigint,v_operation,v_today,
   jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,'quantityUom',v_qty,
    'warehouseId',v_warehouse,'disposition','RESTOCK','notes','Changed payload')),NULL);
 EXCEPTION WHEN OTHERS THEN
  v_payload_conflict:=position('IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_REQUEST' IN SQLERRM)>0;
 END;
 BEGIN
  PERFORM public.post_backoffice_sales_return_receipt(v_return,
   (v_approved->'data'->>'masterVersion')::bigint,gen_random_uuid(),v_today,
   jsonb_build_array(jsonb_build_object('returnLineId',v_return_line,'quantityUom',v_qty,
    'warehouseId',v_warehouse,'disposition','RESTOCK','notes','Rollback-only')),NULL);
 EXCEPTION WHEN OTHERS THEN
  v_stale_rejected:=position('MASTER_VERSION_CONFLICT' IN SQLERRM)>0;
 END;
 IF v_receipt->>'costLineage'<>'LEGACY_AGGREGATE_COST'
  OR v_receipt->'data'->>'status'<>'RECEIVED'
  OR COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE
  OR NOT v_payload_conflict OR NOT v_stale_rejected THEN
  RAISE EXCEPTION 'TEST_FAILED: retained receipt result or exact retry invalid'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_return_receipt_fifo_restorations
  WHERE company_id=v_company AND receipt_id=(v_receipt->>'receiptId')::uuid
   AND cost_lineage='LEGACY_AGGREGATE_COST' AND source_retail_sales_detail_id=v_detail
   AND source_customer_receipt_fifo_allocation_id IS NULL) THEN
  RAISE EXCEPTION 'TEST_FAILED: honest legacy cost lineage missing'; END IF;
 IF (SELECT stock_qty FROM public.product_stocks WHERE company_id=v_company
   AND product_id=v_product AND warehouse_id=v_warehouse)<=v_stock_before THEN
  RAISE EXCEPTION 'TEST_FAILED: RESTOCK did not increase selected Warehouse stock'; END IF;
 IF (SELECT count(*) FROM public.financial_events)<>v_event_before
  OR (SELECT count(*) FROM public.finance_journals)<>v_journal_before
  OR (SELECT count(*) FROM public.sales_return_documents)<>v_native_before THEN
  RAISE EXCEPTION 'TEST_FAILED: physical receipt changed Finance or native Retail Return'; END IF;
END $test$;
ROLLBACK;
SELECT 'retained_retail_return_receipt_behavior' check_name,'PASS' status,
 0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
 'approved retained Retail Return receipt','RESTOCK stock increase','LEGACY_AGGREGATE_COST lineage',
 'exact retry','payload conflict','stale version rejection',
 'no Finance/native Retail Return mutation','all writes rolled back']) details;
