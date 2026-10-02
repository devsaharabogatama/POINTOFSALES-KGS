BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260928100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260928100000 required';
  END IF;
  IF to_regprocedure('public.export_sales_documents(date,date)') IS NULL
    OR to_regprocedure(
      'private.get_sales_export_ro_reconciliation_core(uuid,date,date)') IS NULL
    OR to_regprocedure(
      'public.export_sales_documents_with_reconciliation(date,date)') IS NULL
    OR to_regclass('public.backoffice_sales_return_invoice_allocations') IS NULL
    OR to_regclass('public.backoffice_sales_return_receipt_lines') IS NULL
    OR to_regclass('public.sales_return_lines') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Sales export/Return runtime missing';
  END IF;
  IF to_regprocedure('private.get_sales_export_net_detail_core(uuid,date,date)') IS NOT NULL
    OR EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261002100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: net Sales export collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.get_sales_export_net_detail_core(
  p_company_id uuid,p_date_from date,p_date_to date
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
WITH company_scope AS (
  SELECT company.id company_id,company.timezone
  FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE'
), retail_invoice AS (
  SELECT snapshot.id invoice_id,snapshot.sales_id,snapshot.invoice_no,
    private.resolve_sales_invoice_display_date(snapshot.snapshot_payload,
      to_jsonb(sale),snapshot.created_at,company.timezone) invoice_date,
    CASE WHEN sale.order_runtime_status='CANCELED'
      OR sale.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END invoice_status,
    COALESCE(NULLIF(snapshot.snapshot_payload#>>'{customer,code}',''),customer.code,'') customer_code,
    COALESCE(NULLIF(snapshot.snapshot_payload#>>'{customer,name}',''),customer.name,
      'Walk-In Customer') customer_name
  FROM public.sales_invoice_snapshots snapshot
  JOIN public.sales_headers sale ON sale.company_id=snapshot.company_id
    AND sale.id=snapshot.sales_id
  JOIN company_scope company ON company.company_id=snapshot.company_id
  LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
    AND customer.id=sale.customer_id
  WHERE snapshot.company_id=p_company_id
), retail_scoped AS (
  SELECT * FROM retail_invoice
  WHERE invoice_date BETWEEN p_date_from AND p_date_to
), retail_commercial AS (
  SELECT invoice.invoice_id,invoice.sales_id,invoice.invoice_no,invoice.invoice_date,
    invoice.invoice_status,invoice.customer_code,invoice.customer_name,
    detail.product_id,max(detail.product_sku_snapshot) sku,
    max(detail.product_name_snapshot) product_name,
    max(base_uom.name) base_uom_name,sum(detail.quantity_base) invoice_base_qty
  FROM retail_scoped invoice
  JOIN public.sales_details detail ON detail.company_id=p_company_id
    AND detail.sales_id=invoice.sales_id
  JOIN public.products product ON product.company_id=detail.company_id
    AND product.id=detail.product_id
  JOIN public.uoms base_uom ON base_uom.company_id=product.company_id
    AND base_uom.id=product.uom_id
  GROUP BY invoice.invoice_id,invoice.sales_id,invoice.invoice_no,invoice.invoice_date,
    invoice.invoice_status,invoice.customer_code,invoice.customer_name,detail.product_id
), native_return AS (
  SELECT document.source_sales_id sales_id,line.product_id,
    sum(line.quantity_base) returned_base_qty,
    sum(line.quantity_base) FILTER(WHERE line.return_condition<>'NO_PHYSICAL_RETURN')
      restocked_base_qty,
    0::numeric destroyed_base_qty,
    sum(line.quantity_base) FILTER(WHERE line.return_condition='NO_PHYSICAL_RETURN')
      no_physical_base_qty
  FROM public.sales_return_documents document
  JOIN public.sales_return_lines line ON line.company_id=document.company_id
    AND line.document_id=document.id
  WHERE document.company_id=p_company_id AND document.status='POSTED'
  GROUP BY document.source_sales_id,line.product_id
), retained_return AS (
  SELECT document.retail_sales_id sales_id,receipt_line.product_id,
    sum(receipt_line.received_base_qty) returned_base_qty,
    sum(receipt_line.received_base_qty) FILTER(WHERE receipt_line.disposition='RESTOCK')
      restocked_base_qty,
    sum(receipt_line.received_base_qty) FILTER(WHERE receipt_line.disposition='DESTROY')
      destroyed_base_qty,
    0::numeric no_physical_base_qty
  FROM public.backoffice_sales_returns document
  JOIN public.backoffice_sales_return_receipt_lines receipt_line
    ON receipt_line.company_id=document.company_id AND receipt_line.return_id=document.id
  WHERE document.company_id=p_company_id AND document.source_kind='RETAINED_RETAIL'
    AND document.status<>'CANCELED'
  GROUP BY document.retail_sales_id,receipt_line.product_id
), retail_return AS (
  SELECT item.sales_id,item.product_id,sum(item.returned_base_qty) returned_base_qty,
    sum(item.restocked_base_qty) restocked_base_qty,
    sum(item.destroyed_base_qty) destroyed_base_qty,
    sum(item.no_physical_base_qty) no_physical_base_qty
  FROM (
    SELECT * FROM native_return
    UNION ALL SELECT * FROM retained_return
  ) item GROUP BY item.sales_id,item.product_id
), retail_stock AS (
  SELECT movement.reference_id sales_id,movement.product_id,
    sum(-movement.qty_change) FILTER(WHERE movement.movement_type='SALE'
      AND movement.qty_change<0) outbound_base_qty,
    sum(movement.qty_change) FILTER(WHERE movement.movement_type='REVERSAL'
      AND movement.qty_change>0) reversed_base_qty
  FROM public.stock_movements movement
  JOIN retail_scoped invoice ON invoice.sales_id=movement.reference_id
  WHERE movement.company_id=p_company_id AND movement.reference_table='sales_headers'
    AND movement.movement_status='POSTED'
  GROUP BY movement.reference_id,movement.product_id
), retail_rows AS (
  SELECT 'RETAIL'::text source_kind,commercial.invoice_no document_no,
    commercial.invoice_no,commercial.invoice_date,commercial.invoice_status,
    commercial.customer_code,commercial.customer_name,commercial.sku,
    commercial.product_name,commercial.base_uom_name,
    commercial.invoice_base_qty,
    CASE WHEN commercial.invoice_status='CANCELED'
      THEN commercial.invoice_base_qty ELSE 0 END canceled_base_qty,
    COALESCE(returned.returned_base_qty,0) returned_base_qty,
    greatest(commercial.invoice_base_qty-
      CASE WHEN commercial.invoice_status='CANCELED' THEN commercial.invoice_base_qty ELSE 0 END-
      COALESCE(returned.returned_base_qty,0),0) net_sales_base_qty,
    COALESCE(stock.outbound_base_qty,0) outbound_base_qty,
    COALESCE(stock.reversed_base_qty,0) reversed_base_qty,
    COALESCE(returned.restocked_base_qty,0) restocked_base_qty,
    COALESCE(returned.destroyed_base_qty,0) destroyed_base_qty,
    COALESCE(returned.no_physical_base_qty,0) no_physical_base_qty,
    greatest(COALESCE(stock.outbound_base_qty,0)-COALESCE(stock.reversed_base_qty,0)-
      COALESCE(returned.restocked_base_qty,0),0) net_stock_out_base_qty,
    'ACTUAL_STOCK_MOVEMENT'::text stock_basis,
    CASE WHEN commercial.invoice_status='CANCELED' THEN 'BATAL'
      WHEN COALESCE(returned.returned_base_qty,0)>0 THEN 'RETUR'
      ELSE 'BERSIH' END reconciliation_status
  FROM retail_commercial commercial
  LEFT JOIN retail_return returned ON returned.sales_id=commercial.sales_id
    AND returned.product_id=commercial.product_id
  LEFT JOIN retail_stock stock ON stock.sales_id=commercial.sales_id
    AND stock.product_id=commercial.product_id
), backoffice_scoped AS (
  SELECT invoice.id invoice_id,invoice.invoice_no,invoice.draft_no,
    invoice.invoice_date,invoice.status invoice_status,invoice.sales_order_id,
    document.order_no,COALESCE(customer.code,'') customer_code,
    COALESCE(customer.name,invoice.customer_snapshot->>'name','Customer') customer_name
  FROM public.backoffice_sales_invoices invoice
  JOIN public.backoffice_sales_orders document ON document.company_id=invoice.company_id
    AND document.id=invoice.sales_order_id
  LEFT JOIN public.customers customer ON customer.company_id=invoice.company_id
    AND customer.id=invoice.customer_id
  WHERE invoice.company_id=p_company_id
    AND invoice.invoice_date BETWEEN p_date_from AND p_date_to
), backoffice_commercial AS (
  SELECT invoice.invoice_id,invoice.invoice_no,invoice.draft_no,invoice.invoice_date,
    invoice.invoice_status,invoice.sales_order_id,invoice.order_no,
    invoice.customer_code,invoice.customer_name,line.product_id,
    max(COALESCE(source.product_code_snapshot,product.sku,'')) sku,
    max(COALESCE(source.product_name_snapshot,product.name,line.description)) product_name,
    max(base_uom.name) base_uom_name,sum(line.quantity_base) invoice_base_qty
  FROM backoffice_scoped invoice
  JOIN public.backoffice_sales_invoice_lines line ON line.company_id=p_company_id
    AND line.invoice_id=invoice.invoice_id AND line.line_type='PRODUCT'
    AND line.effect_type='CHARGE'
  LEFT JOIN public.backoffice_sales_order_lines source ON source.company_id=line.company_id
    AND source.id=line.sales_order_line_id
  JOIN public.products product ON product.company_id=line.company_id
    AND product.id=line.product_id
  JOIN public.uoms base_uom ON base_uom.company_id=product.company_id
    AND base_uom.id=product.uom_id
  GROUP BY invoice.invoice_id,invoice.invoice_no,invoice.draft_no,invoice.invoice_date,
    invoice.invoice_status,invoice.sales_order_id,invoice.order_no,
    invoice.customer_code,invoice.customer_name,line.product_id
), backoffice_return AS (
  SELECT allocation.invoice_id,invoice_line.product_id,
    sum(allocation.allocated_base_qty) returned_base_qty,
    sum(allocation.allocated_base_qty) FILTER(WHERE receipt_line.disposition='RESTOCK')
      restocked_base_qty,
    sum(allocation.allocated_base_qty) FILTER(WHERE receipt_line.disposition='DESTROY')
      destroyed_base_qty
  FROM public.backoffice_sales_return_invoice_allocations allocation
  JOIN public.backoffice_sales_returns document ON document.company_id=allocation.company_id
    AND document.id=allocation.return_id AND document.status<>'CANCELED'
  JOIN public.backoffice_sales_invoice_lines invoice_line
    ON invoice_line.company_id=allocation.company_id
   AND invoice_line.id=allocation.invoice_line_id
  JOIN public.backoffice_sales_return_receipt_lines receipt_line
    ON receipt_line.company_id=allocation.company_id
   AND receipt_line.id=allocation.return_receipt_line_id
  WHERE allocation.company_id=p_company_id AND allocation.source_kind='BACKOFFICE'
    AND allocation.allocation_type='POSTED_INVOICE'
    AND allocation.invoice_id IS NOT NULL AND allocation.invoice_line_id IS NOT NULL
  GROUP BY allocation.invoice_id,invoice_line.product_id
), backoffice_rows AS (
  SELECT 'BACKOFFICE'::text source_kind,
    COALESCE(commercial.invoice_no,commercial.draft_no) document_no,
    commercial.invoice_no,commercial.invoice_date,commercial.invoice_status,
    commercial.customer_code,commercial.customer_name,commercial.sku,
    commercial.product_name,commercial.base_uom_name,
    commercial.invoice_base_qty,
    CASE WHEN commercial.invoice_status='CANCELED'
      THEN commercial.invoice_base_qty ELSE 0 END canceled_base_qty,
    COALESCE(returned.returned_base_qty,0) returned_base_qty,
    greatest(commercial.invoice_base_qty-
      CASE WHEN commercial.invoice_status='CANCELED' THEN commercial.invoice_base_qty ELSE 0 END-
      COALESCE(returned.returned_base_qty,0),0) net_sales_base_qty,
    CASE WHEN commercial.invoice_status='CANCELED' THEN 0
      ELSE commercial.invoice_base_qty END outbound_base_qty,
    0::numeric reversed_base_qty,
    COALESCE(returned.restocked_base_qty,0) restocked_base_qty,
    COALESCE(returned.destroyed_base_qty,0) destroyed_base_qty,
    0::numeric no_physical_base_qty,
    greatest(CASE WHEN commercial.invoice_status='CANCELED' THEN 0
      ELSE commercial.invoice_base_qty END-COALESCE(returned.restocked_base_qty,0),0)
      net_stock_out_base_qty,
    'INVOICE_ACCEPTED_QTY'::text stock_basis,
    CASE WHEN commercial.invoice_status='CANCELED' THEN 'BATAL'
      WHEN COALESCE(returned.returned_base_qty,0)>0 THEN 'RETUR'
      WHEN commercial.invoice_status<>'POSTED' THEN 'BELUM_FINAL'
      ELSE 'BERSIH' END reconciliation_status
  FROM backoffice_commercial commercial
  LEFT JOIN backoffice_return returned ON returned.invoice_id=commercial.invoice_id
    AND returned.product_id=commercial.product_id
), all_rows AS (
  SELECT * FROM retail_rows UNION ALL SELECT * FROM backoffice_rows
)
SELECT COALESCE(jsonb_agg(to_jsonb(item)
  ORDER BY item.invoice_date DESC,item.document_no,item.sku),'[]'::jsonb)
FROM all_rows item
$$;

CREATE OR REPLACE FUNCTION public.export_sales_documents_with_reconciliation(
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
      v_company,p_date_from,p_date_to),
    'netSalesLines',private.get_sales_export_net_detail_core(
      v_company,p_date_from,p_date_to));
END
$$;

REVOKE ALL ON FUNCTION private.get_sales_export_net_detail_core(uuid,date,date)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.get_sales_export_net_detail_core(uuid,date,date)
  TO service_role;
REVOKE ALL ON FUNCTION public.export_sales_documents_with_reconciliation(date,date)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_sales_documents_with_reconciliation(date,date)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261002100000','sales_export_net_sales_detail',
  'Add exact-lineage current net Sales detail to the authenticated Invoice workbook; immutable gross Invoice sheets and all Sales, Return, Stock, FIFO, Payment, Event, Journal and COA rows remain unchanged');

NOTIFY pgrst,'reload schema';
COMMIT;
