-- Retained Retail -> Backoffice Return bridge, commercial boundary only.
-- No Stock, FIFO, Invoice, Payment, Financial Event or Journal is posted here.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: privileged Company permission authority required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260918120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='backoffice_sales_returns' AND column_name='source_kind')
    OR to_regprocedure('public.get_retained_retail_backoffice_return_source(uuid)') IS NOT NULL
    OR to_regprocedure('public.save_retained_retail_backoffice_return_draft(uuid,bigint,uuid,uuid,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Return bridge collision';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_returns
  ADD COLUMN source_kind text NOT NULL DEFAULT 'BACKOFFICE',
  ADD COLUMN retail_sales_id uuid,
  ADD COLUMN source_document_snapshot jsonb;
ALTER TABLE public.backoffice_sales_returns ALTER COLUMN sales_order_id DROP NOT NULL;
ALTER TABLE public.backoffice_sales_returns
  ADD CONSTRAINT backoffice_sales_returns_retail_source_fk
    FOREIGN KEY(company_id,retail_sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_returns_source_shape_check CHECK(
    (source_kind='BACKOFFICE' AND sales_order_id IS NOT NULL
      AND retail_sales_id IS NULL AND source_document_snapshot IS NULL)
    OR
    (source_kind='RETAINED_RETAIL' AND sales_order_id IS NULL
      AND retail_sales_id IS NOT NULL
      AND jsonb_typeof(source_document_snapshot)='object'));
CREATE INDEX backoffice_sales_returns_retail_source_time
  ON public.backoffice_sales_returns(company_id,retail_sales_id,created_at DESC,id)
  WHERE retail_sales_id IS NOT NULL;

ALTER TABLE public.backoffice_sales_return_lines
  ADD COLUMN source_kind text NOT NULL DEFAULT 'BACKOFFICE',
  ADD COLUMN retail_sales_detail_id uuid;
ALTER TABLE public.backoffice_sales_return_lines ALTER COLUMN sales_order_line_id DROP NOT NULL;
ALTER TABLE public.backoffice_sales_return_lines
  ADD CONSTRAINT backoffice_sales_return_lines_retail_source_fk
    FOREIGN KEY(company_id,retail_sales_detail_id)
    REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_return_lines_source_shape_check CHECK(
    (source_kind='BACKOFFICE' AND sales_order_line_id IS NOT NULL
      AND retail_sales_detail_id IS NULL)
    OR
    (source_kind='RETAINED_RETAIL' AND sales_order_line_id IS NULL
      AND retail_sales_detail_id IS NOT NULL));
CREATE UNIQUE INDEX backoffice_sales_return_lines_retail_source_unique
  ON public.backoffice_sales_return_lines(company_id,return_id,retail_sales_detail_id)
  WHERE retail_sales_detail_id IS NOT NULL;
CREATE INDEX backoffice_sales_return_lines_retail_source
  ON public.backoffice_sales_return_lines(company_id,retail_sales_detail_id,return_id)
  WHERE retail_sales_detail_id IS NOT NULL;

CREATE OR REPLACE FUNCTION private.backoffice_sales_return_snapshot(
  p_company_id uuid,p_return_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT jsonb_build_object(
    'id',document.id,'returnNo',document.return_no,'sourceKind',document.source_kind,
    'salesOrderId',document.sales_order_id,'retailSalesId',document.retail_sales_id,
    'salesOrderNo',CASE WHEN document.source_kind='BACKOFFICE' THEN sales_order.order_no
      ELSE document.source_document_snapshot->>'documentNo' END,
    'quotationNo',sales_order.quotation_no,'customerId',document.customer_id,
    'customerSnapshot',CASE WHEN document.source_kind='BACKOFFICE'
      THEN sales_order.customer_snapshot
      ELSE document.source_document_snapshot->'customerSnapshot' END,
    'sourceDocumentSnapshot',document.source_document_snapshot,
    'status',document.status,'reason',document.reason,'notes',document.notes,
    'totalRequestedBaseQty',document.total_requested_base_qty,
    'totalReceivedBaseQty',document.total_received_base_qty,
    'totalRestockedBaseQty',document.total_restocked_base_qty,
    'totalDestroyedBaseQty',document.total_destroyed_base_qty,
    'goodsStatus',CASE
      WHEN document.total_received_base_qty=0 THEN 'NOT_RECEIVED'
      WHEN document.total_received_base_qty<document.total_requested_base_qty THEN 'PARTIALLY_RECEIVED'
      ELSE 'RECEIVED' END,
    'masterVersion',document.master_version,'createdAt',document.created_at,
    'updatedAt',document.updated_at,'submittedAt',document.submitted_at,
    'approvedAt',document.approved_at,'canceledAt',document.canceled_at,
    'cancelReason',document.cancel_reason,
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'lineNo',line.line_no,'sourceKind',line.source_kind,
      'salesOrderLineId',line.sales_order_line_id,
      'retailSalesDetailId',line.retail_sales_detail_id,
      'productId',line.product_id,'uomId',line.uom_id,
      'requestedQtyUom',line.requested_qty_uom,'baseQtyPerUom',line.base_qty_per_uom,
      'requestedBaseQty',line.requested_base_qty,'lineReason',line.line_reason,
      'productCode',line.product_code_snapshot,'productName',line.product_name_snapshot,
      'uomCode',line.uom_code_snapshot,'uomName',line.uom_name_snapshot,
      'receivedBaseQty',COALESCE((SELECT sum(receipt_line.received_base_qty)
        FROM public.backoffice_sales_return_receipt_lines receipt_line
        WHERE receipt_line.company_id=line.company_id
          AND receipt_line.return_line_id=line.id),0)
    ) ORDER BY line.line_no) FROM public.backoffice_sales_return_lines line
      WHERE line.company_id=document.company_id AND line.return_id=document.id),'[]'::jsonb)
  )
  FROM public.backoffice_sales_returns document
  LEFT JOIN public.backoffice_sales_orders sales_order
    ON sales_order.company_id=document.company_id AND sales_order.id=document.sales_order_id
  WHERE document.company_id=p_company_id AND document.id=p_return_id
$$;

CREATE OR REPLACE FUNCTION private.assert_backoffice_sales_return_quantities(
  p_company_id uuid,p_return_id uuid,p_sales_order_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_document public.backoffice_sales_returns%rowtype;v_invalid bigint;
BEGIN
  SELECT * INTO STRICT v_document FROM public.backoffice_sales_returns
  WHERE company_id=p_company_id AND id=p_return_id;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_company_id::text||
    ':backoffice-return:'||COALESCE(v_document.sales_order_id,v_document.retail_sales_id)::text,0));
  IF v_document.source_kind='BACKOFFICE' THEN
    SELECT count(*) INTO v_invalid
    FROM public.backoffice_sales_return_lines candidate
    JOIN public.backoffice_sales_order_lines source
      ON source.company_id=candidate.company_id AND source.id=candidate.sales_order_line_id
    WHERE candidate.company_id=p_company_id AND candidate.return_id=p_return_id
      AND candidate.requested_base_qty > greatest(0,
        source.accepted_base_qty-source.returned_before_invoice_base_qty
        -COALESCE((SELECT sum(other_line.requested_base_qty)
          FROM public.backoffice_sales_return_lines other_line
          JOIN public.backoffice_sales_returns other_return
            ON other_return.company_id=other_line.company_id AND other_return.id=other_line.return_id
          WHERE other_line.company_id=candidate.company_id
            AND other_line.sales_order_line_id=candidate.sales_order_line_id
            AND other_return.id<>p_return_id
            AND other_return.status NOT IN('DRAFT','CANCELED')),0));
  ELSE
    SELECT count(*) INTO v_invalid
    FROM public.backoffice_sales_return_lines candidate
    JOIN public.sales_details source ON source.company_id=candidate.company_id
      AND source.id=candidate.retail_sales_detail_id
    WHERE candidate.company_id=p_company_id AND candidate.return_id=p_return_id
      AND candidate.requested_base_qty>greatest(0,source.quantity_base
        -COALESCE((SELECT sum(retail_line.quantity_base)
          FROM public.sales_return_lines retail_line
          JOIN public.sales_return_documents retail_return
            ON retail_return.company_id=retail_line.company_id
           AND retail_return.id=retail_line.document_id
          WHERE retail_line.company_id=source.company_id
            AND retail_line.source_sales_detail_id=source.id
            AND retail_return.status='POSTED'),0)
        -COALESCE((SELECT sum(other_line.requested_base_qty)
          FROM public.backoffice_sales_return_lines other_line
          JOIN public.backoffice_sales_returns other_return
            ON other_return.company_id=other_line.company_id AND other_return.id=other_line.return_id
          WHERE other_line.company_id=candidate.company_id
            AND other_line.retail_sales_detail_id=candidate.retail_sales_detail_id
            AND other_return.id<>p_return_id
            AND other_return.status NOT IN('DRAFT','CANCELED')),0));
  END IF;
  IF v_invalid>0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_QUANTITY_EXCEEDS_RETURNABLE';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_returns(
  p_status text DEFAULT NULL,p_search text DEFAULT NULL,p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_status text;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns','VIEW');
  v_status:=nullif(upper(btrim(COALESCE(p_status,''))), '');
  IF v_status IS NOT NULL AND v_status NOT IN('DRAFT','SUBMITTED','APPROVED',
    'PARTIALLY_RECEIVED','RECEIVED','CREDIT_PENDING','REFUND_PENDING','COMPLETED','CANCELED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_STATUS_INVALID';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_LIMIT_INVALID';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((SELECT jsonb_agg(
    private.backoffice_sales_return_snapshot(v_company,row_data.id)
    ORDER BY row_data.updated_at DESC,row_data.id)
    FROM (SELECT document.id,document.updated_at
      FROM public.backoffice_sales_returns document
      LEFT JOIN public.backoffice_sales_orders sales_order
        ON sales_order.company_id=document.company_id AND sales_order.id=document.sales_order_id
      WHERE document.company_id=v_company AND (v_status IS NULL OR document.status=v_status)
        AND (nullif(btrim(COALESCE(p_search,'')),'') IS NULL
          OR document.return_no ILIKE '%'||btrim(p_search)||'%'
          OR COALESCE(sales_order.order_no,sales_order.quotation_no,
            document.source_document_snapshot->>'documentNo') ILIKE '%'||btrim(p_search)||'%'
          OR COALESCE(sales_order.customer_snapshot->>'name',
            document.source_document_snapshot->'customerSnapshot'->>'name')
              ILIKE '%'||btrim(p_search)||'%')
      ORDER BY document.updated_at DESC,document.id LIMIT p_limit) row_data),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.get_retained_retail_backoffice_return_source(p_sales_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_sale public.sales_headers%rowtype;
  v_document_no text;v_customer jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns','VIEW');
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting ON setting.company_id=sale.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE sale.company_id=v_company AND sale.id=p_sales_id
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status<>'CANCELED'
    AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED'
      OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
          AND delivery.status='DELIVERED'))
    AND NOT EXISTS(SELECT 1 FROM public.sales_process_cutover_items item
      JOIN public.sales_process_cutover_audit audit
        ON audit.company_id=item.company_id AND audit.cutover_item_id=item.id
      WHERE item.company_id=sale.company_id AND item.source_document_id=sale.id
        AND item.source_document_type='RETAIL_SALE' AND audit.action='APPLY_ITEM'
        AND audit.after_state->'converterResult'->>'targetDocumentType'='BACKOFFICE_SALES_ORDER'
        AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','') IS NOT NULL);
  IF NOT FOUND THEN RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_SOURCE_NOT_FOUND'; END IF;
  v_document_no:=COALESCE(v_sale.draft_no,v_sale.invoice_no);
  SELECT jsonb_build_object('id',customer.id,'name',customer.name)
    INTO v_customer FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=v_sale.customer_id;
  RETURN jsonb_build_object('companyId',v_company,'data',jsonb_build_object(
    'sourceKind','RETAINED_RETAIL','retailSalesId',v_sale.id,
    'salesOrderNo',v_document_no,'customerId',v_sale.customer_id,
    'customerSnapshot',COALESCE(v_customer,'{}'::jsonb),'lines',COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'retailSalesDetailId',detail.id,'productId',detail.product_id,
        'uomId',detail.sale_uom_id,'productCode',detail.product_sku_snapshot,
        'productName',detail.product_name_snapshot,'uomName',detail.sale_uom_name_snapshot,
        'baseQtyPerUom',detail.uom_factor_to_base_snapshot,
        'returnableBaseQty',greatest(0,detail.quantity_base
          -COALESCE((SELECT sum(native_line.quantity_base)
            FROM public.sales_return_lines native_line
            JOIN public.sales_return_documents native_return
              ON native_return.company_id=native_line.company_id
             AND native_return.id=native_line.document_id
            WHERE native_line.company_id=detail.company_id
              AND native_line.source_sales_detail_id=detail.id
              AND native_return.status='POSTED'),0)
          -COALESCE((SELECT sum(bridge_line.requested_base_qty)
            FROM public.backoffice_sales_return_lines bridge_line
            JOIN public.backoffice_sales_returns bridge_return
              ON bridge_return.company_id=bridge_line.company_id
             AND bridge_return.id=bridge_line.return_id
            WHERE bridge_line.company_id=detail.company_id
              AND bridge_line.retail_sales_detail_id=detail.id
              AND bridge_return.status NOT IN('DRAFT','CANCELED')),0))
      ) ORDER BY detail.id)
      FROM public.sales_details detail WHERE detail.company_id=v_company
        AND detail.sales_id=v_sale.id AND detail.quantity_base>COALESCE((
          SELECT sum(native_line.quantity_base) FROM public.sales_return_lines native_line
          JOIN public.sales_return_documents native_return
            ON native_return.company_id=native_line.company_id
           AND native_return.id=native_line.document_id
          WHERE native_line.company_id=detail.company_id
            AND native_line.source_sales_detail_id=detail.id
            AND native_return.status='POSTED'),0)+COALESCE((
          SELECT sum(bridge_line.requested_base_qty)
          FROM public.backoffice_sales_return_lines bridge_line
          JOIN public.backoffice_sales_returns bridge_return
            ON bridge_return.company_id=bridge_line.company_id
           AND bridge_return.id=bridge_line.return_id
          WHERE bridge_line.company_id=detail.company_id
            AND bridge_line.retail_sales_detail_id=detail.id
            AND bridge_return.status NOT IN('DRAFT','CANCELED')),0)),'[]'::jsonb)));
END
$$;

CREATE FUNCTION public.save_retained_retail_backoffice_return_draft(
  p_return_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_sales_id uuid,p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_sale public.sales_headers%rowtype;v_document public.backoffice_sales_returns%rowtype;
  v_detail public.sales_details%rowtype;v_item jsonb;v_source_id uuid;v_qty numeric;
  v_total numeric:=0;v_line_no integer:=0;v_ids uuid[]:='{}';v_hash text;
  v_retry jsonb;v_before jsonb;v_after jsonb;v_response jsonb;v_customer jsonb;
  v_uom_code text;v_snapshot jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns',
    CASE WHEN p_return_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_operation_id IS NULL OR p_sales_id IS NULL OR p_payload IS NULL
    OR jsonb_typeof(p_payload)<>'object' OR jsonb_typeof(p_payload->'lines')<>'array'
    OR jsonb_array_length(p_payload->'lines')=0
    OR nullif(btrim(p_payload->>'reason'),'') IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_PAYLOAD_INVALID';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'returnId',p_return_id,'expectedVersion',p_expected_version,
    'retailSalesId',p_sales_id,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_return_operation_retry(v_company,p_operation_id,'SAVE_DRAFT',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  JOIN public.company_sales_process_settings setting ON setting.company_id=sale.company_id
    AND setting.active_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
  WHERE sale.company_id=v_company AND sale.id=p_sales_id
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status<>'CANCELED'
    AND (sale.document_status='POSTED' OR sale.order_runtime_status='DELIVERED'
      OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
          AND delivery.status='DELIVERED')) FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_SOURCE_NOT_FOUND'; END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_items item
    JOIN public.sales_process_cutover_audit audit
      ON audit.company_id=item.company_id AND audit.cutover_item_id=item.id
    WHERE item.company_id=v_company AND item.source_document_id=v_sale.id
      AND item.source_document_type='RETAIL_SALE' AND audit.action='APPLY_ITEM'
      AND audit.after_state->'converterResult'->>'targetDocumentType'='BACKOFFICE_SALES_ORDER'
      AND nullif(audit.after_state->'converterResult'->>'targetDocumentId','') IS NOT NULL) THEN
    RAISE EXCEPTION 'RETAINED_RETAIL_RETURN_SOURCE_ALREADY_CONVERTED';
  END IF;
  SELECT jsonb_build_object('id',customer.id,'name',customer.name)
    INTO v_customer FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=v_sale.customer_id;
  v_snapshot:=jsonb_build_object('documentNo',COALESCE(v_sale.draft_no,v_sale.invoice_no),
    'invoiceNo',v_sale.invoice_no,'customerSnapshot',COALESCE(v_customer,'{}'::jsonb),
    'storeId',v_sale.store_id,'warehouseId',v_sale.sales_warehouse_id,
    'sourceChannel',v_sale.source_channel,'orderRuntimeStatus',v_sale.order_runtime_status);
  IF p_return_id IS NULL THEN
    IF p_expected_version IS NOT NULL THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    INSERT INTO public.backoffice_sales_returns(company_id,return_no,source_kind,
      retail_sales_id,source_document_snapshot,customer_id,reason,notes,created_by,updated_by)
    VALUES(v_company,'RTN-'||to_char((clock_timestamp() AT TIME ZONE
      (SELECT timezone FROM public.companies WHERE id=v_company))::date,'YYYYMMDD')||'-'||
      lpad(nextval('private.backoffice_sales_return_no_seq')::text,10,'0'),
      'RETAINED_RETAIL',v_sale.id,v_snapshot,v_sale.customer_id,btrim(p_payload->>'reason'),
      nullif(btrim(p_payload->>'notes'),''),v_actor,v_actor) RETURNING * INTO v_document;
  ELSE
    SELECT * INTO v_document FROM public.backoffice_sales_returns
      WHERE company_id=v_company AND id=p_return_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_FOUND'; END IF;
    IF v_document.source_kind<>'RETAINED_RETAIL' OR v_document.retail_sales_id<>p_sales_id THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_SOURCE_IMMUTABLE';
    END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_DRAFT'; END IF;
    IF p_expected_version IS DISTINCT FROM v_document.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=private.backoffice_sales_return_snapshot(v_company,v_document.id);
    DELETE FROM public.backoffice_sales_return_lines
      WHERE company_id=v_company AND return_id=v_document.id;
    UPDATE public.backoffice_sales_returns SET reason=btrim(p_payload->>'reason'),
      notes=nullif(btrim(p_payload->>'notes'),''),total_requested_base_qty=0,
      master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'lines') LOOP
    v_line_no:=v_line_no+1;
    BEGIN v_source_id:=(v_item->>'retailSalesDetailId')::uuid;
      v_qty:=(v_item->>'quantityUom')::numeric;
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_LINE_INVALID'; END;
    IF v_source_id IS NULL OR v_qty IS NULL OR v_qty<=0 OR v_source_id=ANY(v_ids) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_LINE_INVALID';
    END IF;
    v_ids:=array_append(v_ids,v_source_id);
    SELECT * INTO v_detail FROM public.sales_details detail
      WHERE detail.company_id=v_company AND detail.id=v_source_id
        AND detail.sales_id=v_sale.id;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_LINE_INVALID'; END IF;
    SELECT code INTO v_uom_code FROM public.uoms
      WHERE company_id=v_company AND id=v_detail.sale_uom_id;
    INSERT INTO public.backoffice_sales_return_lines(company_id,return_id,source_kind,
      retail_sales_detail_id,line_no,product_id,uom_id,requested_qty_uom,
      base_qty_per_uom,line_reason,product_code_snapshot,product_name_snapshot,
      uom_code_snapshot,uom_name_snapshot)
    VALUES(v_company,v_document.id,'RETAINED_RETAIL',v_detail.id,v_line_no,
      v_detail.product_id,v_detail.sale_uom_id,v_qty,v_detail.uom_factor_to_base_snapshot,
      nullif(btrim(v_item->>'reason'),''),v_detail.product_sku_snapshot,
      v_detail.product_name_snapshot,v_uom_code,v_detail.sale_uom_name_snapshot);
    v_total:=v_total+v_qty*v_detail.uom_factor_to_base_snapshot;
  END LOOP;
  UPDATE public.backoffice_sales_returns SET total_requested_base_qty=v_total,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  PERFORM private.assert_backoffice_sales_return_quantities(v_company,v_document.id,NULL);
  v_after:=private.backoffice_sales_return_snapshot(v_company,v_document.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,'exactRetry',false);
  INSERT INTO public.backoffice_sales_return_operations(company_id,operation_id,
    operation_type,return_id,expected_version,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'SAVE_DRAFT',v_document.id,p_expected_version,v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_return_audit(company_id,return_id,operation_id,
    action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.id,p_operation_id,
    CASE WHEN v_before IS NULL THEN 'CREATE_DRAFT' ELSE 'UPDATE_DRAFT' END,
    v_actor,v_before,v_after);
  RETURN v_response;
END
$$;

REVOKE ALL ON FUNCTION public.get_retained_retail_backoffice_return_source(uuid),
  public.save_retained_retail_backoffice_return_draft(uuid,bigint,uuid,uuid,jsonb)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_retained_retail_backoffice_return_source(uuid),
  public.save_retained_retail_backoffice_return_draft(uuid,bigint,uuid,uuid,jsonb)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260918120000','retained_retail_backoffice_return_commercial_bridge',
  'Additive truthful retained-Retail source identity for Backoffice Return draft/submit/approve/cancel; no Stock, FIFO, Invoice, Payment or Finance mutation');
NOTIFY pgrst,'reload schema';
COMMIT;
