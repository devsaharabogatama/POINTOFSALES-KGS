-- Additive read-only Sales export reconciliation payload.
BEGIN;
SET LOCAL lock_timeout='5s';

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260919130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Invoice union export required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260918130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Retail Return receipt bridge required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260918120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Retail Return commercial bridge required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260924100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical active RO/PO coverage required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260928100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260928100000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.get_sales_export_ro_reconciliation_core(uuid,date,date)') IS NOT NULL
    OR to_regprocedure('public.export_sales_stock_reconciliation(date,date)') IS NOT NULL
    OR to_regprocedure(
      'public.export_sales_documents_with_reconciliation(date,date)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: reconciliation routine collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.get_sales_export_ro_reconciliation_core(
  p_company_id uuid,p_date_from date,p_date_to date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
WITH company_scope AS (
  SELECT company.id company_id,company.company_name,company.company_code,
    company.timezone
  FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE'
), posted_receipt AS (
  SELECT line.company_id,line.supplier_order_line_id,
    sum(line.received_base_qty) received_base_qty
  FROM public.goods_receipt_lines line
  JOIN public.goods_receipt_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  WHERE line.company_id=p_company_id AND document.status='POSTED'
  GROUP BY line.company_id,line.supplier_order_line_id
), po_line AS (
  SELECT line.company_id,line.product_id,
    coalesce(line.source_warehouse_id,line.destination_warehouse_id,
      document.destination_warehouse_id) warehouse_id,
    line.id coverage_line_id,'PURCHASE_ORDER'::text coverage_type,
    document.order_no coverage_no,document.order_date coverage_date,
    document.created_at,
    greatest(line.ordered_base_qty-coalesce(receipt.received_base_qty,0),0)
      coverage_base_qty
  FROM public.supplier_order_lines line
  JOIN public.supplier_order_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  LEFT JOIN posted_receipt receipt ON receipt.company_id=line.company_id
    AND receipt.supplier_order_line_id=line.id
  WHERE line.company_id=p_company_id
    AND document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')
    AND line.ordered_base_qty>coalesce(receipt.received_base_qty,0)
), active_po_request_allocation AS (
  SELECT allocation.company_id,allocation.stock_request_line_id,
    sum(allocation.allocated_base_qty) allocated_base_qty
  FROM public.supplier_order_request_allocations allocation
  JOIN public.supplier_order_lines order_line
    ON order_line.company_id=allocation.company_id
   AND order_line.id=allocation.supplier_order_line_id
  JOIN public.supplier_order_documents order_document
    ON order_document.company_id=order_line.company_id
   AND order_document.id=order_line.document_id
  WHERE allocation.company_id=p_company_id
    AND order_document.status IN('DRAFT','CONFIRMED','PARTIALLY_RECEIVED')
  GROUP BY allocation.company_id,allocation.stock_request_line_id
), request_line AS (
  SELECT line.company_id,line.product_id,
    coalesce(line.source_warehouse_id,demand.warehouse_id) warehouse_id,
    line.id coverage_line_id,'STOCK_REQUEST'::text coverage_type,
    document.request_no coverage_no,
    (document.requested_at AT TIME ZONE company.timezone)::date coverage_date,
    document.created_at,
    greatest(line.requested_base_qty-coalesce(allocation.allocated_base_qty,0),0)
      coverage_base_qty
  FROM public.stock_request_lines line
  JOIN public.stock_request_documents document
    ON document.company_id=line.company_id AND document.id=line.document_id
  JOIN company_scope company ON company.company_id=line.company_id
  LEFT JOIN public.sales_order_procurement_demand_lines demand
    ON demand.company_id=line.company_id AND demand.stock_request_line_id=line.id
  LEFT JOIN active_po_request_allocation allocation
    ON allocation.company_id=line.company_id
   AND allocation.stock_request_line_id=line.id
  WHERE line.company_id=p_company_id AND line.is_active
    AND document.status IN('DRAFT','SUBMITTED','ORDERED','PARTIALLY_RECEIVED')
    AND line.requested_base_qty>coalesce(allocation.allocated_base_qty,0)
), daily_line AS (
  SELECT line.company_id,line.product_id,line.warehouse_id,
    line.id coverage_line_id,
    CASE WHEN batch.mode_snapshot='AUTO_RO' THEN 'DAILY_AUTO_RO'
      ELSE 'DAILY_AUTO_PO_BATCH' END coverage_type,
    batch.batch_no coverage_no,batch.business_date coverage_date,batch.created_at,
    line.requested_base_qty coverage_base_qty
  FROM public.purchase_daily_batch_lines line
  JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
    AND batch.id=line.batch_id
  WHERE line.company_id=p_company_id AND batch.status='DRAFT'
    AND line.readiness_status<>'ORDERED'
), coverage AS (
  SELECT * FROM po_line WHERE warehouse_id IS NOT NULL AND coverage_base_qty>0
  UNION ALL SELECT * FROM request_line
    WHERE warehouse_id IS NOT NULL AND coverage_base_qty>0
  UNION ALL SELECT * FROM daily_line
    WHERE warehouse_id IS NOT NULL AND coverage_base_qty>0
), open_source AS (
  SELECT allocation.company_id,allocation.product_id,
    allocation.source_warehouse_id warehouse_id,
    'BACKOFFICE_SO'::text source_type,allocation.id source_allocation_id,
    document.order_no source_document_no,document.order_date source_date,
    allocation.created_at,allocation.shortage_base_qty original_base_qty,
    allocation.replenished_base_qty,
    allocation.shortage_base_qty-allocation.replenished_base_qty open_base_qty
  FROM public.backoffice_negative_stock_allocations allocation
  JOIN public.backoffice_sales_orders document
    ON document.company_id=allocation.company_id
   AND document.id=allocation.sales_order_id
  WHERE allocation.company_id=p_company_id
    AND allocation.shortage_base_qty>allocation.replenished_base_qty
    AND allocation.reconciled_at IS NULL
  UNION ALL
  SELECT allocation.company_id,allocation.stock_product_id,allocation.warehouse_id,
    'RETAIL_INVOICE',allocation.id,sale.invoice_no,
    (sale.transaction_date AT TIME ZONE company.timezone)::date,
    allocation.created_at,allocation.shortage_base_qty,
    allocation.replenished_base_qty,
    allocation.shortage_base_qty-allocation.replenished_base_qty
  FROM public.negative_stock_sale_allocations allocation
  JOIN public.sales_headers sale ON sale.company_id=allocation.company_id
    AND sale.id=allocation.sales_id
  JOIN company_scope company ON company.company_id=allocation.company_id
  WHERE allocation.company_id=p_company_id
    AND allocation.shortage_base_qty>allocation.replenished_base_qty
    AND allocation.reconciled_at IS NULL AND allocation.reversed_at IS NULL
), source_range AS (
  SELECT source.*,
    coalesce(sum(open_base_qty) OVER(PARTITION BY company_id,product_id,warehouse_id
      ORDER BY created_at,source_type,source_document_no,source_allocation_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) range_start,
    sum(open_base_qty) OVER(PARTITION BY company_id,product_id,warehouse_id
      ORDER BY created_at,source_type,source_document_no,source_allocation_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) range_end
  FROM open_source source
), coverage_range AS (
  SELECT item.*,
    coalesce(sum(coverage_base_qty) OVER(
      PARTITION BY company_id,product_id,warehouse_id
      ORDER BY CASE coverage_type WHEN 'PURCHASE_ORDER' THEN 1
        WHEN 'STOCK_REQUEST' THEN 2 ELSE 3 END,
        coverage_date,created_at,coverage_no,coverage_line_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) range_start,
    sum(coverage_base_qty) OVER(
      PARTITION BY company_id,product_id,warehouse_id
      ORDER BY CASE coverage_type WHEN 'PURCHASE_ORDER' THEN 1
        WHEN 'STOCK_REQUEST' THEN 2 ELSE 3 END,
        coverage_date,created_at,coverage_no,coverage_line_id
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) range_end
  FROM coverage item
), source_match AS (
  SELECT source.company_id,source.source_type,source.source_allocation_id,
    coverage.coverage_type,coverage.coverage_no,coverage.coverage_date,
    greatest(least(source.range_end,coverage.range_end)-
      greatest(source.range_start,coverage.range_start),0) matched_base_qty
  FROM source_range source
  JOIN coverage_range coverage ON coverage.company_id=source.company_id
    AND coverage.product_id=source.product_id
    AND coverage.warehouse_id=source.warehouse_id
    AND least(source.range_end,coverage.range_end)>
      greatest(source.range_start,coverage.range_start)
), source_match_summary AS (
  SELECT source.company_id,source.source_type,source.source_allocation_id,
    sum(source.matched_base_qty) coverage_base_qty,
    jsonb_agg(jsonb_build_object('type',source.coverage_type,
      'documentNo',source.coverage_no,'documentDate',source.coverage_date,
      'quantityBase',source.matched_base_qty)
      ORDER BY source.coverage_date,source.coverage_no) coverage_documents
  FROM source_match source
  GROUP BY source.company_id,source.source_type,source.source_allocation_id
), ro_requirement_rows AS (
  SELECT source.source_type,source.source_document_no,source.source_date,
    product.sku,product.name product_name,warehouse.name warehouse_name,
    uom.name base_uom_name,source.original_base_qty,
    source.replenished_base_qty,source.open_base_qty,
    coalesce(stock.stock_qty,0) current_on_hand_base_qty,
    coalesce(match.coverage_base_qty,0) coverage_base_qty,
    greatest(source.open_base_qty-coalesce(match.coverage_base_qty,0),0)
      uncovered_base_qty,
    coalesce(match.coverage_documents,'[]'::jsonb) coverage_documents
  FROM open_source source
  JOIN public.products product ON product.company_id=source.company_id
    AND product.id=source.product_id
  JOIN public.uoms uom ON uom.company_id=product.company_id
    AND uom.id=product.uom_id
  JOIN public.warehouses warehouse ON warehouse.company_id=source.company_id
    AND warehouse.id=source.warehouse_id
  LEFT JOIN public.product_stocks stock ON stock.company_id=source.company_id
    AND stock.product_id=source.product_id
    AND stock.warehouse_id=source.warehouse_id
  LEFT JOIN source_match_summary match ON match.company_id=source.company_id
    AND match.source_type=source.source_type
    AND match.source_allocation_id=source.source_allocation_id
), retail_cancel_effect AS (
  SELECT sale.id source_id,'RETAIL'::text source_kind,sale.invoice_no document_no,
    (sale.canceled_at AT TIME ZONE company.timezone)::date effect_date,
    sale.cancel_reason,product.sku,product.name product_name,
    uom.name base_uom_name,
    coalesce(sum(-movement.qty_change) FILTER(WHERE
      movement.movement_type='SALE'::public.stock_movement_type
      AND movement.qty_change<0),0) outbound_base_qty,
    coalesce(sum(movement.qty_change) FILTER(WHERE
      movement.movement_type='REVERSAL'::public.stock_movement_type
      AND movement.qty_change>0),0) reversed_base_qty
  FROM public.sales_headers sale
  JOIN company_scope company ON company.company_id=sale.company_id
  JOIN public.stock_movements movement ON movement.company_id=sale.company_id
    AND movement.reference_id=sale.id AND movement.reference_table='sales_headers'
    AND movement.movement_status='POSTED'
  JOIN public.products product ON product.company_id=movement.company_id
    AND product.id=movement.product_id
  JOIN public.uoms uom ON uom.company_id=product.company_id AND uom.id=product.uom_id
  WHERE sale.company_id=p_company_id AND sale.document_status='CANCELED'
    AND (sale.canceled_at AT TIME ZONE company.timezone)::date
      BETWEEN p_date_from AND p_date_to
  GROUP BY sale.id,sale.invoice_no,effect_date,sale.cancel_reason,
    product.sku,product.name,uom.name
), backoffice_cancel_effect AS (
  SELECT document.id source_id,'BACKOFFICE'::text source_kind,
    coalesce(document.order_no,document.quotation_no) document_no,
    (document.canceled_at AT TIME ZONE company.timezone)::date effect_date,
    document.cancel_reason,product.sku,product.name product_name,
    uom.name base_uom_name,
    coalesce(sum(dispatch_line.quantity_base)
      FILTER(WHERE delivery_line.id IS NOT NULL),0) outbound_base_qty,
    0::numeric reversed_base_qty
  FROM public.backoffice_sales_orders document
  JOIN company_scope company ON company.company_id=document.company_id
  JOIN public.backoffice_sales_order_lines line ON line.company_id=document.company_id
    AND line.sales_order_id=document.id
  JOIN public.products product ON product.company_id=line.company_id
    AND product.id=line.product_id
  JOIN public.uoms uom ON uom.company_id=line.company_id AND uom.id=line.uom_id
  LEFT JOIN public.backoffice_sales_delivery_dispatches dispatch
    ON dispatch.company_id=document.company_id AND dispatch.sales_order_id=document.id
  LEFT JOIN public.backoffice_sales_delivery_dispatch_lines dispatch_line
    ON dispatch_line.company_id=dispatch.company_id
   AND dispatch_line.dispatch_id=dispatch.id
  LEFT JOIN public.backoffice_sales_delivery_order_lines delivery_line
    ON delivery_line.company_id=dispatch_line.company_id
   AND delivery_line.id=dispatch_line.delivery_order_line_id
   AND delivery_line.sales_order_line_id=line.id
  WHERE document.company_id=p_company_id AND document.status='CANCELED'
    AND (document.canceled_at AT TIME ZONE company.timezone)::date
      BETWEEN p_date_from AND p_date_to
  GROUP BY document.id,document.order_no,document.quotation_no,effect_date,
    document.cancel_reason,product.sku,product.name,uom.name
), cancellation_rows AS (
  SELECT effect.*,
    greatest(effect.outbound_base_qty-effect.reversed_base_qty,0) net_stock_out_base_qty,
    CASE WHEN effect.outbound_base_qty=effect.reversed_base_qty THEN 'FULLY_REVERSED'
      WHEN effect.outbound_base_qty=0 THEN 'CANCELED_BEFORE_STOCK_OUT'
      ELSE 'CANCELED_WITH_REMAINING_STOCK_EFFECT' END stock_effect_status
  FROM (
    SELECT * FROM retail_cancel_effect
    UNION ALL SELECT * FROM backoffice_cancel_effect
  ) effect
), native_return_rows AS (
  SELECT 'RETAIL_NATIVE'::text source_kind,sale.invoice_no source_document_no,
    document.return_no,NULL::text receipt_no,
    (document.posted_at AT TIME ZONE company.timezone)::date effect_date,
    line.product_sku_snapshot sku,line.product_name_snapshot product_name,
    line.sale_uom_name_snapshot uom_name,line.quantity_base returned_base_qty,
    CASE WHEN line.return_condition<>'NO_PHYSICAL_RETURN'
      THEN line.quantity_base ELSE 0 END restocked_base_qty,
    0::numeric destroyed_base_qty,
    CASE WHEN line.return_condition='NO_PHYSICAL_RETURN'
      THEN line.quantity_base ELSE 0 END no_physical_base_qty,
    line.return_condition disposition,warehouse.name warehouse_name
  FROM public.sales_return_documents document
  JOIN company_scope company ON company.company_id=document.company_id
  JOIN public.sales_headers sale ON sale.company_id=document.company_id
    AND sale.id=document.source_sales_id
  JOIN public.sales_return_lines line ON line.company_id=document.company_id
    AND line.document_id=document.id
  LEFT JOIN public.warehouses warehouse ON warehouse.company_id=line.company_id
    AND warehouse.id=line.destination_warehouse_id
  WHERE document.company_id=p_company_id AND document.status='POSTED'
    AND (document.posted_at AT TIME ZONE company.timezone)::date
      BETWEEN p_date_from AND p_date_to
  GROUP BY sale.invoice_no,document.return_no,effect_date,
    line.product_sku_snapshot,line.product_name_snapshot,
    line.sale_uom_name_snapshot,line.quantity_base,line.return_condition,warehouse.name
), received_return_rows AS (
  SELECT document.source_kind,
    CASE WHEN document.source_kind='BACKOFFICE'
      THEN sales_order.order_no ELSE retail_sale.invoice_no END source_document_no,
    document.return_no,receipt.receipt_no,receipt.receipt_date effect_date,
    line.product_code_snapshot sku,line.product_name_snapshot product_name,
    line.uom_name_snapshot uom_name,line.received_base_qty returned_base_qty,
    CASE WHEN line.disposition='RESTOCK' THEN line.received_base_qty ELSE 0 END
      restocked_base_qty,
    CASE WHEN line.disposition='DESTROY' THEN line.received_base_qty ELSE 0 END
      destroyed_base_qty,0::numeric no_physical_base_qty,
    line.disposition,line.warehouse_name_snapshot warehouse_name
  FROM public.backoffice_sales_return_receipt_lines line
  JOIN public.backoffice_sales_return_receipts receipt
    ON receipt.company_id=line.company_id AND receipt.id=line.receipt_id
  JOIN public.backoffice_sales_returns document
    ON document.company_id=line.company_id AND document.id=line.return_id
  LEFT JOIN public.backoffice_sales_orders sales_order
    ON sales_order.company_id=document.company_id AND sales_order.id=document.sales_order_id
  LEFT JOIN public.sales_headers retail_sale
    ON retail_sale.company_id=document.company_id AND retail_sale.id=document.retail_sales_id
  WHERE line.company_id=p_company_id AND receipt.status='POSTED'
    AND receipt.receipt_date BETWEEN p_date_from AND p_date_to
), return_rows AS (
  SELECT * FROM native_return_rows
  UNION ALL SELECT * FROM received_return_rows
)
SELECT jsonb_build_object(
  'companyId',company.company_id,'companyCode',company.company_code,
  'companyName',company.company_name,'generatedAt',statement_timestamp(),
  'dateFrom',p_date_from,'dateTo',p_date_to,
  'roRequirementDateBasis','CURRENT_OPEN_SHORTAGE_AT_EXPORT_TIME',
  'correctionDateBasis','EFFECT_DATE_WITHIN_SELECTED_RANGE',
  'roRequirements',coalesce((SELECT jsonb_agg(to_jsonb(row_data)
    ORDER BY row_data.source_date,row_data.source_document_no,row_data.sku)
    FROM ro_requirement_rows row_data),'[]'::jsonb),
  'cancellations',coalesce((SELECT jsonb_agg(to_jsonb(row_data)
    ORDER BY row_data.effect_date,row_data.document_no,row_data.sku)
    FROM cancellation_rows row_data),'[]'::jsonb),
  'returns',coalesce((SELECT jsonb_agg(to_jsonb(row_data)
    ORDER BY row_data.effect_date,row_data.return_no,row_data.sku)
    FROM return_rows row_data),'[]'::jsonb)
)
FROM company_scope company
$$;

CREATE FUNCTION public.export_sales_stock_reconciliation(
  p_date_from date,p_date_to date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  IF p_date_from IS NULL OR p_date_to IS NULL OR p_date_from>p_date_to THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','EXPORT');
  RETURN private.get_sales_export_ro_reconciliation_core(
    v_company,p_date_from,p_date_to);
END
$$;

CREATE FUNCTION public.export_sales_documents_with_reconciliation(
  p_date_from date,p_date_to date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='45s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  IF p_date_from IS NULL OR p_date_to IS NULL OR p_date_from>p_date_to THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','EXPORT');
  RETURN jsonb_build_object(
    'documents',public.export_sales_documents(p_date_from,p_date_to),
    'reconciliation',private.get_sales_export_ro_reconciliation_core(
      v_company,p_date_from,p_date_to));
END
$$;

REVOKE ALL ON FUNCTION
  private.get_sales_export_ro_reconciliation_core(uuid,date,date)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.get_sales_export_ro_reconciliation_core(uuid,date,date)
  TO service_role;
REVOKE ALL ON FUNCTION public.export_sales_stock_reconciliation(date,date)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_sales_stock_reconciliation(date,date)
  TO authenticated,service_role;
REVOKE ALL ON FUNCTION
  public.export_sales_documents_with_reconciliation(date,date)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.export_sales_documents_with_reconciliation(date,date)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260928100000','sales_export_ro_reconciliation',
  'Add read-only current clean RO requirement, cancellation/reversal and Customer Return datasets to Sales Invoice Data Exchange; existing Invoice export and all Stock/Finance rows unchanged');

NOTIFY pgrst,'reload schema';
COMMIT;
