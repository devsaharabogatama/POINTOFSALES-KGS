-- Generated only from the captured active staging export definition and exact anchors.
CREATE OR REPLACE FUNCTION public.export_sales_documents(p_date_from date, p_date_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET statement_timeout TO '30s'
AS $function$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_company_row public.companies%ROWTYPE;
BEGIN
  IF p_date_from IS NULL OR p_date_to IS NULL OR p_date_from>p_date_to THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','EXPORT');
  SELECT company.* INTO STRICT v_company_row
  FROM public.companies company WHERE company.id=v_company;

  RETURN (
    WITH retail_base AS (
      SELECT invoice.id invoice_id,invoice.sales_id,invoice.invoice_no,
        invoice.snapshot_provenance,invoice.created_at,
        invoice.snapshot_payload payload,sale.document_status,
        sale.order_runtime_status,sale.source_channel,sale.fulfillment_mode,
        sale.is_tempo,sale.due_date,sale.grand_total_after_rounding,
        sale.delivery_fee_amount,sale.paid_amount,sale.sisa_piutang,
        sale.canceled_at,sale.cancel_reason,cancel_actor.name canceled_by_name,
        private.resolve_sales_invoice_display_date(invoice.snapshot_payload,
          to_jsonb(sale),invoice.created_at,v_company_row.timezone) invoice_date,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{customer,code}',''),customer.code,'') customer_code,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{customer,name}',''),customer.name,'Walk-In Customer') customer_name,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{store,name}',''),store.store_name,'Store') store_name
      FROM public.sales_invoice_snapshots invoice
      JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
        AND sale.id=invoice.sales_id
      LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
        AND customer.id=sale.customer_id
      LEFT JOIN public.stores store ON store.company_id=sale.company_id
        AND store.id=sale.store_id
      LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=sale.canceled_by
      WHERE invoice.company_id=v_company
    ), retail_scoped AS (
      SELECT * FROM retail_base WHERE invoice_date BETWEEN p_date_from AND p_date_to
    ), backoffice_scoped AS (
      SELECT invoice.*,document.order_no,document.fulfillment_status,document.is_tempo,
        (identity.value->>'invoiceDate')::date effective_invoice_date,
        store.store_name,customer.code customer_code,customer.name customer_name,
        cancel_actor.name canceled_by_name,
        (SELECT min(schedule.due_date)
         FROM public.backoffice_sales_invoice_receivable_schedules schedule
         WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id) due_date,
        COALESCE((SELECT sum(allocation.allocated_amount)
          FROM public.customer_receipt_backoffice_invoice_allocations allocation
          JOIN public.customer_receipt_documents receipt
            ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
          WHERE allocation.company_id=invoice.company_id
            AND allocation.invoice_id=invoice.id AND receipt.status='POSTED'),0) paid_amount
      FROM public.backoffice_sales_invoices invoice
      JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,NULL) value) identity ON true
      JOIN public.backoffice_sales_orders document ON document.company_id=invoice.company_id
        AND document.id=invoice.sales_order_id
      LEFT JOIN public.customers customer ON customer.company_id=invoice.company_id
        AND customer.id=(identity.value->>'customerId')::uuid
      LEFT JOIN public.stores store ON store.company_id=invoice.company_id
        AND store.id=invoice.store_id
      LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=invoice.canceled_by
      WHERE invoice.company_id=v_company
        AND (identity.value->>'invoiceDate')::date BETWEEN p_date_from AND p_date_to
    ), invoice_rows AS (
      SELECT scoped.invoice_id,scoped.sales_id,NULL::uuid sales_order_id,
        'RETAIL'::text source_kind,scoped.invoice_no::text document_no,
        scoped.invoice_no::text invoice_no,NULL::text draft_no,NULL::text sales_order_no,
        scoped.invoice_date,
        CASE WHEN scoped.order_runtime_status='CANCELED'
          OR scoped.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END invoice_status,
        scoped.customer_code,scoped.customer_name,scoped.store_name,
        scoped.source_channel::text,scoped.fulfillment_mode::text,
        COALESCE((scoped.payload->>'isTempo')::boolean,scoped.is_tempo,false) is_tempo,
        COALESCE(NULLIF(scoped.payload->>'dueDate','')::timestamptz,scoped.due_date)::date due_date,
        COALESCE((scoped.payload#>>'{totals,subtotal}')::numeric,0) subtotal,
        COALESCE((scoped.payload#>>'{totals,itemDiscount}')::numeric,0) item_discount,
        COALESCE((scoped.payload#>>'{totals,orderDiscount}')::numeric,0) order_discount,
        COALESCE((scoped.payload#>>'{totals,itemDiscount}')::numeric,0)
          +COALESCE((scoped.payload#>>'{totals,orderDiscount}')::numeric,0) total_discount,
        COALESCE((SELECT sum(COALESCE(NULLIF(line.value->>'taxAmount','')::numeric,0))
          FROM jsonb_array_elements(COALESCE(scoped.payload->'lines','[]'::jsonb)) line),0) tax_total,
        COALESCE((scoped.payload#>>'{totals,deliveryFee}')::numeric,
          scoped.delivery_fee_amount,0) delivery_fee,
        COALESCE((scoped.payload#>>'{totals,roundingAdjustment}')::numeric,0) rounding_adjustment,
        COALESCE((scoped.payload#>>'{totals,grandTotal}')::numeric,
          scoped.grand_total_after_rounding,0) grand_total,
        COALESCE((scoped.payload#>>'{totals,paidAmount}')::numeric,scoped.paid_amount,0) paid_amount,
        COALESCE((scoped.payload#>>'{totals,receivable}')::numeric,scoped.sisa_piutang,0) receivable,
        scoped.canceled_at,scoped.cancel_reason,scoped.canceled_by_name,
        scoped.snapshot_provenance::text,scoped.created_at
      FROM retail_scoped scoped
      UNION ALL
      SELECT scoped.id,scoped.id,scoped.sales_order_id,
        'BACKOFFICE',COALESCE(scoped.invoice_no,scoped.draft_no),
        scoped.invoice_no,scoped.draft_no,scoped.order_no,scoped.effective_invoice_date,
        scoped.status,COALESCE(scoped.customer_code,''),
        COALESCE(scoped.customer_name,scoped.customer_snapshot->>'name','Customer'),
        COALESCE(scoped.store_name,'Store'),'BACKOFFICE',scoped.fulfillment_status,
        scoped.is_tempo,scoped.due_date,
        scoped.charge_total-COALESCE((SELECT sum(line.line_amount+line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'chargeAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.discount_total-COALESCE((SELECT sum(line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'discountAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        0::numeric,
        scoped.discount_total-COALESCE((SELECT sum(line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'discountAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.tax_total-COALESCE((SELECT sum(line.tax_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'taxAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.delivery_fee_amount,0::numeric,
        private.backoffice_invoice_effective_total(scoped.company_id,scoped.id,NULL),scoped.paid_amount,
        greatest(private.backoffice_invoice_effective_total(scoped.company_id,scoped.id,NULL)-scoped.paid_amount,0),scoped.canceled_at,
        scoped.cancel_reason,scoped.canceled_by_name,'BACKOFFICE_CANONICAL',scoped.created_at
      FROM backoffice_scoped scoped
    ), line_rows AS (
      SELECT 'RETAIL'::text source_kind,scoped.invoice_no::text document_no,
        scoped.invoice_no::text invoice_no,NULL::text draft_no,NULL::text sales_order_no,
        scoped.invoice_date,
        CASE WHEN scoped.order_runtime_status='CANCELED'
          OR scoped.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END invoice_status,
        scoped.customer_code,scoped.customer_name,element.ordinality::bigint line_no,
        'PRODUCT'::text line_type,'CHARGE'::text effect_type,
        COALESCE(element.value->>'sku','') sku,
        COALESCE(element.value->>'productName','') product_name,
        COALESCE(element.value->>'uomName','') uom_name,
        COALESCE(NULLIF(element.value->>'quantity','')::numeric,0) quantity,
        COALESCE(NULLIF(element.value->>'factorToBase','')::numeric,0) factor_to_base,
        COALESCE(NULLIF(element.value->>'quantityBase','')::numeric,0) quantity_base,
        COALESCE(NULLIF(element.value->>'unitPrice','')::numeric,0) unit_price,
        COALESCE(NULLIF(element.value->>'discount','')::numeric,0) discount,
        COALESCE(element.value->>'taxCode','') tax_code,
        COALESCE(element.value->>'taxName','') tax_name,
        COALESCE(NULLIF(element.value->>'taxRatePercent','')::numeric,0) tax_rate_percent,
        COALESCE(NULLIF(element.value->>'taxAmount','')::numeric,0) tax_amount,
        COALESCE(NULLIF(element.value->>'lineTotal','')::numeric,0) line_total
      FROM retail_scoped scoped
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(scoped.payload->'lines','[]'::jsonb))
        WITH ORDINALITY AS element(value,ordinality)
      UNION ALL
      SELECT 'BACKOFFICE',COALESCE(invoice.invoice_no,invoice.draft_no),
        invoice.invoice_no,invoice.draft_no,invoice.order_no,invoice.effective_invoice_date,
        invoice.status,COALESCE(invoice.customer_code,''),
        COALESCE(invoice.customer_name,invoice.customer_snapshot->>'name','Customer'),
        line.line_no::bigint,line.line_type,line.effect_type,
        COALESCE(source.product_code_snapshot,product.sku,''),
        COALESCE(source.product_name_snapshot,product.name,line.description),
        COALESCE(source.uom_name_snapshot,uom.name,''),
        COALESCE(line.quantity_uom,0),COALESCE(line.base_qty_per_uom,0),
        COALESCE(line.quantity_base,0),
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'enteredUnitPrice')::numeric ELSE line.unit_price END,
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'discountAmount')::numeric ELSE line.discount_amount END,
        COALESCE(line.source_snapshot->>'taxCode',''),
        COALESCE(line.source_snapshot->>'taxName',''),
        COALESCE(NULLIF(line.source_snapshot->>'taxRatePercent','')::numeric,0),
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'taxAmount')::numeric ELSE line.tax_amount END,
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'lineAmount')::numeric ELSE line.line_amount END
      FROM backoffice_scoped invoice
      JOIN public.backoffice_sales_invoice_lines line ON line.company_id=invoice.company_id
        AND line.invoice_id=invoice.id
      LEFT JOIN LATERAL(SELECT CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'
        THEN private.backoffice_invoice_effective_line_amounts(line.company_id,line.id) END value) effective ON true
      LEFT JOIN public.backoffice_sales_order_lines source ON source.company_id=line.company_id
        AND source.id=line.sales_order_line_id
      LEFT JOIN public.products product ON product.company_id=line.company_id
        AND product.id=line.product_id
      LEFT JOIN public.uoms uom ON uom.company_id=line.company_id AND uom.id=line.uom_id
    )
    SELECT jsonb_build_object(
      'companyId',v_company,'companyCode',v_company_row.company_code,
      'companyName',v_company_row.company_name,'dateFrom',p_date_from,
      'dateTo',p_date_to,'generatedAt',statement_timestamp(),
      'invoices',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'invoiceId',row_data.invoice_id,'salesId',row_data.sales_id,
        'salesOrderId',row_data.sales_order_id,'sourceKind',row_data.source_kind,
        'documentNo',row_data.document_no,'invoiceNo',row_data.invoice_no,
        'draftNo',row_data.draft_no,'salesOrderNo',row_data.sales_order_no,
        'invoiceDate',row_data.invoice_date,'invoiceStatus',row_data.invoice_status,
        'customerCode',row_data.customer_code,'customerName',row_data.customer_name,
        'storeName',row_data.store_name,'sourceChannel',row_data.source_channel,
        'fulfillmentMode',row_data.fulfillment_mode,'isTempo',row_data.is_tempo,
        'dueDate',row_data.due_date,'subtotal',row_data.subtotal,
        'itemDiscount',row_data.item_discount,'orderDiscount',row_data.order_discount,
        'totalDiscount',row_data.total_discount,'taxTotal',row_data.tax_total,
        'deliveryFee',row_data.delivery_fee,'roundingAdjustment',row_data.rounding_adjustment,
        'grandTotal',row_data.grand_total,'paidAmount',row_data.paid_amount,
        'receivable',row_data.receivable,'canceledAt',row_data.canceled_at,
        'cancelReason',row_data.cancel_reason,'canceledByName',row_data.canceled_by_name,
        'snapshotProvenance',row_data.snapshot_provenance)
        ORDER BY row_data.invoice_date DESC,row_data.created_at DESC,row_data.invoice_id)
        FROM invoice_rows row_data),'[]'::jsonb),
      'lines',COALESCE((SELECT jsonb_agg(to_jsonb(row_data)
        ORDER BY row_data.invoice_date DESC,row_data.document_no,row_data.line_no)
        FROM line_rows row_data),'[]'::jsonb)
    )
  );
END
$function$;
