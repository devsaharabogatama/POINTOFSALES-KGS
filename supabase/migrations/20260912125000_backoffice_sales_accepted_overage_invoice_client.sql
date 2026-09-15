-- Step 4/6.5C2C: expose accepted overage through the existing Invoice workspace.
BEGIN;
DO $guard$
DECLARE v_snapshot text;v_workspace text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912124000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C2B accepted-overage Invoice runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912125000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912125000';
  END IF;
  SELECT pg_get_functiondef('private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)'::regprocedure)
    INTO v_snapshot;
  SELECT pg_get_functiondef('public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer)'::regprocedure)
    INTO v_workspace;
  IF position('''sourceKind''' in v_snapshot)>0 OR position('''acceptedOverageLines''' in v_workspace)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice client read-model drift';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.backoffice_sales_invoice_ui_snapshot(p_company_id uuid,p_invoice_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.backoffice_sales_invoice_snapshot(p_company_id,p_invoice_id)
    ||jsonb_build_object(
      'salesOrderNo',document.order_no,'quotationNo',document.quotation_no,
      'orderDate',document.order_date,'salesOrderDueDate',document.due_date,
      'fulfillmentStatus',document.fulfillment_status,
      'storeName',store.store_name,'warehouseName',warehouse.name,
      'dueDate',(SELECT min(schedule.due_date) FROM public.backoffice_sales_invoice_receivable_schedules schedule
        WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),
      'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',line.id,'lineNo',line.line_no,'lineType',line.line_type,'effectType',line.effect_type,
        'sourceKind',line.source_kind,'salesOrderLineId',line.sales_order_line_id,
        'discrepancyLineId',line.discrepancy_line_id,'productId',line.product_id,'uomId',line.uom_id,
        'productCode',source.product_code_snapshot,'productName',source.product_name_snapshot,
        'uomCode',source.uom_code_snapshot,'uomName',source.uom_name_snapshot,
        'orderedQty',CASE WHEN line.source_kind='ACCEPTED_OVERAGE' THEN 0 ELSE source.ordered_qty END,
        'acceptedQty',round(CASE WHEN line.source_kind='ACCEPTED_OVERAGE'
          THEN discrepancy.accepted_overage_base_qty ELSE source.accepted_base_qty END/source.base_qty_per_uom,6),
        'invoicedBeforeQty',round(greatest(0,CASE WHEN line.source_kind='ACCEPTED_OVERAGE'
          THEN discrepancy.invoiced_overage_base_qty ELSE source.invoiced_base_qty END-line.quantity_base)
          /source.base_qty_per_uom,6),
        'quantityUom',line.quantity_uom,'baseQtyPerUom',line.base_qty_per_uom,
        'quantityBase',line.quantity_base,'unitPrice',line.unit_price,
        'discountAmount',line.discount_amount,'taxAmount',line.tax_amount,
        'lineAmount',line.line_amount,'description',line.description,
        'sourceSnapshot',line.source_snapshot) ORDER BY line.line_no)
        FROM public.backoffice_sales_invoice_lines line
        LEFT JOIN public.backoffice_sales_order_lines source ON source.company_id=line.company_id
          AND source.id=line.sales_order_line_id
        LEFT JOIN public.backoffice_sales_delivery_discrepancy_lines discrepancy
          ON discrepancy.company_id=line.company_id AND discrepancy.id=line.discrepancy_line_id
        WHERE line.company_id=invoice.company_id AND line.invoice_id=invoice.id),'[]'::jsonb),
      'activity',COALESCE((SELECT jsonb_agg(jsonb_build_object('action',audit.action,
        'reason',audit.reason,'actorId',audit.actor_id,'createdAt',audit.created_at)
        ORDER BY audit.created_at,audit.id)
        FROM public.backoffice_sales_invoice_audit audit
        WHERE audit.company_id=invoice.company_id AND audit.invoice_id=invoice.id),'[]'::jsonb))
  FROM public.backoffice_sales_invoices invoice
  JOIN public.backoffice_sales_orders document ON document.company_id=invoice.company_id
    AND document.id=invoice.sales_order_id
  JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
  JOIN public.warehouses warehouse ON warehouse.company_id=invoice.company_id AND warehouse.id=invoice.warehouse_id
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_invoice_workspace(
  p_sales_order_id uuid DEFAULT NULL,p_status text DEFAULT NULL,p_search text DEFAULT NULL,
  p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_status text:=upper(NULLIF(btrim(p_status),''));
  v_search text:=NULLIF(btrim(p_search),'');v_source jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  IF v_status IS NOT NULL AND v_status NOT IN('DRAFT','POSTED','CANCELED','REVERSED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_STATUS_INVALID';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>200 THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_FILTER_INVALID'; END IF;
  IF p_sales_order_id IS NOT NULL THEN
    SELECT jsonb_build_object('id',document.id,'salesOrderNo',document.order_no,
      'quotationNo',document.quotation_no,'status',document.status,
      'fulfillmentStatus',document.fulfillment_status,'orderDate',document.order_date,
      'plannedDeliveryDate',document.planned_delivery_date,'isTempo',document.is_tempo,
      'dueDate',document.due_date,'customerId',document.customer_id,
      'customerSnapshot',document.customer_snapshot,'storeId',document.store_id,
      'warehouseId',document.warehouse_id,'currencyCode',document.currency_code,
      'deliveryFeeAmount',document.delivery_fee_amount,
      'deliveryFeeRemaining',greatest(0,document.delivery_fee_amount-COALESCE((SELECT sum(item.delivery_fee_amount)
        FROM public.backoffice_sales_invoices item WHERE item.company_id=document.company_id
          AND item.sales_order_id=document.id AND item.invoice_type='REGULAR'
          AND item.status IN('DRAFT','POSTED')),0)),
      'totalToInvoiceBaseQty',COALESCE((SELECT sum(line.to_invoice_base_qty)
        FROM public.backoffice_sales_order_lines line WHERE line.company_id=document.company_id
          AND line.sales_order_id=document.id),0)+COALESCE((SELECT sum(discrepancy.overage_to_invoice_base_qty)
        FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
        WHERE discrepancy.company_id=document.company_id AND discrepancy.sales_order_id=document.id
          AND discrepancy.requested_resolution='ACCEPT_OVERAGE'
          AND discrepancy.commercial_approval_status='APPROVED'
          AND discrepancy.warehouse_resolution_status='RESOLVED'),0),
      'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',line.id,'sourceKind','SALES_ORDER',
        'salesOrderLineId',line.id,'lineNo',line.line_no,'productId',line.product_id,'uomId',line.uom_id,
        'productCode',line.product_code_snapshot,'productName',line.product_name_snapshot,
        'uomCode',line.uom_code_snapshot,'uomName',line.uom_name_snapshot,'orderedQty',line.ordered_qty,
        'acceptedQty',round(line.accepted_base_qty/line.base_qty_per_uom,6),
        'invoicedQty',round(line.invoiced_base_qty/line.base_qty_per_uom,6),
        'draftAllocatedQty',round(line.draft_invoice_allocated_base_qty/line.base_qty_per_uom,6),
        'toInvoiceQty',round(line.to_invoice_base_qty/line.base_qty_per_uom,6),
        'baseQtyPerUom',line.base_qty_per_uom,'unitPrice',line.unit_price,
        'discountAmount',line.discount_amount,'taxApplied',line.tax_rule_id IS NOT NULL,
        'taxName',line.tax_name_snapshot,'taxRatePercent',line.tax_rate_percent_snapshot)
        ORDER BY line.line_no) FROM public.backoffice_sales_order_lines line
        WHERE line.company_id=document.company_id AND line.sales_order_id=document.id),'[]'::jsonb),
      'acceptedOverageLines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id',discrepancy.id,'sourceKind','ACCEPTED_OVERAGE','discrepancyLineId',discrepancy.id,
        'salesOrderLineId',source.id,'lineNo',source.line_no,'productId',source.product_id,'uomId',source.uom_id,
        'productCode',source.product_code_snapshot,'productName',source.product_name_snapshot,
        'uomCode',source.uom_code_snapshot,'uomName',source.uom_name_snapshot,'orderedQty',0,
        'acceptedQty',round(discrepancy.accepted_overage_base_qty/source.base_qty_per_uom,6),
        'invoicedQty',round(discrepancy.invoiced_overage_base_qty/source.base_qty_per_uom,6),
        'draftAllocatedQty',round(discrepancy.draft_overage_invoice_allocated_base_qty/source.base_qty_per_uom,6),
        'toInvoiceQty',round(discrepancy.overage_to_invoice_base_qty/source.base_qty_per_uom,6),
        'baseQtyPerUom',source.base_qty_per_uom,'unitPrice',discrepancy.approved_unit_price,
        'discountAmount',discrepancy.approved_discount_amount,
        'approvedDiscountAmount',discrepancy.approved_discount_amount,
        'approvedTaxAmount',discrepancy.approved_tax_amount,
        'taxApplied',COALESCE((discrepancy.commercial_snapshot->'tax'->>'taxApplied')::boolean,false),
        'taxName',discrepancy.commercial_snapshot->'tax'->>'taxName',
        'taxRatePercent',NULLIF(discrepancy.commercial_snapshot->'tax'->>'ratePercent','')::numeric)
        ORDER BY discrepancy.created_at,discrepancy.id)
        FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
        JOIN public.backoffice_sales_order_lines source ON source.company_id=discrepancy.company_id
          AND source.id=discrepancy.sales_order_line_id
        WHERE discrepancy.company_id=document.company_id AND discrepancy.sales_order_id=document.id
          AND discrepancy.requested_resolution='ACCEPT_OVERAGE'
          AND discrepancy.commercial_approval_status='APPROVED'
          AND discrepancy.warehouse_resolution_status='RESOLVED'
          AND discrepancy.accepted_overage_base_qty>0),'[]'::jsonb))
      INTO v_source FROM public.backoffice_sales_orders document
      WHERE document.company_id=v_company AND document.id=p_sales_order_id;
    IF v_source IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
  END IF;
  RETURN jsonb_build_object('companyId',v_company,
    'companyDate',current_timestamp AT TIME ZONE company.timezone::text,
    'sourceOrder',v_source,
    'paymentTerms',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',term.id,'code',term.term_code,
      'name',term.term_name,'showInstallmentDates',term.show_installment_dates) ORDER BY term.term_name)
      FROM public.backoffice_sales_payment_terms term WHERE term.company_id=v_company AND term.is_active),'[]'::jsonb),
    'invoices',COALESCE((SELECT jsonb_agg(private.backoffice_sales_invoice_ui_snapshot(v_company,item.id)
      ORDER BY item.created_at DESC,item.id DESC)
      FROM (SELECT invoice.id,invoice.created_at FROM public.backoffice_sales_invoices invoice
        WHERE invoice.company_id=v_company AND (p_sales_order_id IS NULL OR invoice.sales_order_id=p_sales_order_id)
          AND (v_status IS NULL OR invoice.status=v_status)
          AND (v_search IS NULL OR invoice.draft_no ILIKE '%'||v_search||'%'
            OR invoice.invoice_no ILIKE '%'||v_search||'%'
            OR invoice.customer_snapshot->>'name' ILIKE '%'||v_search||'%')
        ORDER BY invoice.created_at DESC,invoice.id DESC LIMIT p_limit) item),'[]'::jsonb))
  FROM public.companies company WHERE company.id=v_company;
END
$$;

REVOKE ALL ON FUNCTION private.backoffice_sales_invoice_ui_snapshot(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.backoffice_sales_invoice_ui_snapshot(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_invoice_workspace(uuid,text,text,integer) TO authenticated,service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912125000','backoffice_sales_accepted_overage_invoice_client',
  'Step 4/6.5C2C exposes resolved accepted overage in the existing Invoice workspace/detail/template; commercial fields stay immutable and only quantity is client-editable');
NOTIFY pgrst,'reload schema';
COMMIT;
