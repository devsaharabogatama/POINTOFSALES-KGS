-- Authenticated rollback-only behavior for retained Retail Return commercial bridge.
BEGIN;
DO $test$
DECLARE v_actor uuid;v_company uuid;v_sale uuid;v_detail uuid;v_qty numeric;
  v_saved jsonb;v_retry jsonb;v_submitted jsonb;v_approved jsonb;v_canceled jsonb;
  v_return uuid;v_operation uuid:=gen_random_uuid();v_blocked boolean;
  v_stock bigint;v_event bigint;v_journal bigint;v_retail_return bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918120000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: retained Retail Return bridge required';
  END IF;
  SELECT profile.id INTO STRICT v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role ORDER BY profile.id LIMIT 1;
  SELECT sale.company_id,sale.id,detail.id,
    least(detail.qty,available.base_qty/detail.uom_factor_to_base_snapshot)
  INTO STRICT v_company,v_sale,v_detail,v_qty
  FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting ON setting.company_id=sale.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  JOIN public.sales_details detail ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
  JOIN LATERAL(SELECT detail.quantity_base
      -COALESCE((SELECT sum(line.quantity_base)
        FROM public.sales_return_lines line JOIN public.sales_return_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=detail.company_id AND line.source_sales_detail_id=detail.id
          AND document.status='POSTED'),0)
      -COALESCE((SELECT sum(line.requested_base_qty)
        FROM public.backoffice_sales_return_lines line
        JOIN public.backoffice_sales_returns document
          ON document.company_id=line.company_id AND document.id=line.return_id
        WHERE line.company_id=detail.company_id AND line.retail_sales_detail_id=detail.id
          AND document.status NOT IN('DRAFT','CANCELED')),0) base_qty) available ON true
  WHERE sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status<>'CANCELED'
    AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED')
    AND detail.qty>0
    AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_items item
      JOIN public.sales_process_cutover_audit audit
        ON audit.company_id=item.company_id AND audit.cutover_item_id=item.id
      WHERE item.company_id=sale.company_id AND item.source_document_id=sale.id
        AND item.source_document_type='RETAIL_SALE' AND audit.action='APPLY_ITEM'
        AND audit.after_state->'converterResult'->>'targetDocumentType'='BACKOFFICE_SALES_ORDER'
        AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','') IS NOT NULL)
    AND available.base_qty>0
  ORDER BY sale.created_at DESC,detail.id LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub',v_actor::text,true);
  INSERT INTO public.user_active_company_contexts(user_id,company_id)
  VALUES(v_actor,v_company) ON CONFLICT(user_id) DO UPDATE SET company_id=excluded.company_id,
    selected_at=clock_timestamp(),updated_at=clock_timestamp();
  SELECT count(*) INTO v_stock FROM public.stock_movements;
  SELECT count(*) INTO v_event FROM public.financial_events;
  SELECT count(*) INTO v_journal FROM public.finance_journals;
  SELECT count(*) INTO v_retail_return FROM public.sales_return_documents;
  PERFORM public.get_retained_retail_backoffice_return_source(v_sale);
  v_saved:=public.save_retained_retail_backoffice_return_draft(NULL,NULL,v_operation,v_sale,
    jsonb_build_object('reason','Retained Retail rollback-only test','notes','No business write survives',
      'lines',jsonb_build_array(jsonb_build_object(
        'retailSalesDetailId',v_detail,'quantityUom',v_qty))));
  v_return:=(v_saved->'data'->>'id')::uuid;
  IF v_saved->'data'->>'sourceKind'<>'RETAINED_RETAIL'
    OR v_saved->'data'->>'retailSalesId'<>v_sale::text
    OR v_saved->'data'->>'status'<>'DRAFT'
    OR v_saved->'data'->'lines'->0->>'retailSalesDetailId'<>v_detail::text THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Retail Draft identity invalid';
  END IF;
  v_retry:=public.save_retained_retail_backoffice_return_draft(
    NULL,NULL,v_operation,v_sale,jsonb_build_object(
      'reason','Retained Retail rollback-only test','notes','No business write survives',
      'lines',jsonb_build_array(jsonb_build_object(
        'retailSalesDetailId',v_detail,'quantityUom',v_qty))));
  IF COALESCE((v_retry->>'exactRetry')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry invalid';
  END IF;
  v_submitted:=public.submit_backoffice_sales_return(v_return,
    (v_saved->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_blocked:=false;
  BEGIN
    PERFORM public.approve_backoffice_sales_return(v_return,
      (v_saved->'data'->>'masterVersion')::bigint,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_blocked:=SQLERRM LIKE '%MASTER_VERSION_CONFLICT%'; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'TEST_FAILED: stale approval accepted'; END IF;
  v_approved:=public.approve_backoffice_sales_return(v_return,
    (v_submitted->'data'->>'masterVersion')::bigint,gen_random_uuid());
  v_canceled:=public.cancel_backoffice_sales_return(v_return,
    (v_approved->'data'->>'masterVersion')::bigint,gen_random_uuid(),'Rollback-only cancel');
  IF v_canceled->'data'->>'status'<>'CANCELED' THEN
    RAISE EXCEPTION 'TEST_FAILED: retained Retail cancellation invalid';
  END IF;
  IF (SELECT count(*) FROM public.stock_movements)<>v_stock
    OR (SELECT count(*) FROM public.financial_events)<>v_event
    OR (SELECT count(*) FROM public.finance_journals)<>v_journal
    OR (SELECT count(*) FROM public.sales_return_documents)<>v_retail_return THEN
    RAISE EXCEPTION 'TEST_FAILED: commercial bridge changed Stock, Finance or native Retail Return';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'retained_retail_backoffice_return_commercial_behavior' check_name,
  'PASS' status,0::bigint violation_rows,
  jsonb_build_object('tested',ARRAY['truthful retained Retail identity','Draft/Submit/Approve/Cancel',
    'exact retry','stale version rejection','no Stock/Finance/native Retail Return mutation',
    'all fixture writes rolled back']) details;
