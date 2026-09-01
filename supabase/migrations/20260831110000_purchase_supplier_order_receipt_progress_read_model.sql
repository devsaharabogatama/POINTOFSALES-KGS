-- Add read-only ordered/received/remaining progress to Supplier Order lines.
-- Receipt progress follows the existing PO lifecycle source exactly: only
-- Goods Receipt documents with POSTED status contribute received_base_qty.
BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260828190000','20260831100000'))<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR Purchasing read chain required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260831110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260831110000';
  END IF;
  IF to_regprocedure('public.get_purchase_supplier_orders()') IS NULL
     OR to_regprocedure('private.odr4d_get_purchase_supplier_orders_core()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Supplier Order read required';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_purchase_supplier_orders()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_base JSONB;
  v_request_lines JSONB;v_order_lines JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  v_base:=private.odr4d_get_purchase_supplier_orders_core();

  SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
    ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
  INTO v_request_lines FROM (SELECT line.id,line.document_id,line.line_no,
      line.product_id,line.requested_uom_id,line.requested_qty,
      line.factor_to_base_snapshot,line.requested_base_qty,
      line.product_sku_snapshot,line.product_name_snapshot,
      line.requested_uom_name_snapshot,line.notes
    FROM public.stock_request_lines line
    JOIN public.stock_request_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    WHERE line.company_id=v_company AND line.is_active
      AND document.status IN('SUBMITTED','ORDERED')
    ORDER BY line.document_id,line.line_no LIMIT 10000) line_row;

  WITH receipt_progress AS (
    SELECT receipt_line.supplier_order_line_id,
      sum(receipt_line.received_base_qty) received_base_qty,
      count(DISTINCT receipt.id) posted_receipt_count,
      max(receipt.posted_at) last_received_at
    FROM public.goods_receipt_lines receipt_line
    JOIN public.goods_receipt_documents receipt
      ON receipt.company_id=receipt_line.company_id
     AND receipt.id=receipt_line.document_id
     AND receipt.status='POSTED'
    WHERE receipt_line.company_id=v_company
    GROUP BY receipt_line.supplier_order_line_id
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
    ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
  INTO v_order_lines FROM (SELECT line.id,line.document_id,line.line_no,
      line.product_id,line.ordered_uom_id,line.ordered_qty,
      line.factor_to_base_snapshot,line.ordered_base_qty,
      line.estimated_unit_price,line.estimated_subtotal,
      line.product_sku_snapshot,line.product_name_snapshot,
      line.ordered_uom_name_snapshot,
      COALESCE(progress.received_base_qty,0) received_base_qty,
      GREATEST(line.ordered_base_qty-COALESCE(progress.received_base_qty,0),0)
        remaining_base_qty,
      COALESCE(progress.received_base_qty,0)/line.factor_to_base_snapshot
        received_ordered_qty,
      GREATEST(line.ordered_base_qty-COALESCE(progress.received_base_qty,0),0)
        /line.factor_to_base_snapshot remaining_ordered_qty,
      GREATEST(COALESCE(progress.received_base_qty,0)-line.ordered_base_qty,0)
        over_received_base_qty,
      CASE
        WHEN COALESCE(progress.received_base_qty,0)<=0 THEN 'NOT_RECEIVED'
        WHEN progress.received_base_qty<line.ordered_base_qty THEN 'PARTIAL'
        ELSE 'COMPLETE' END receipt_progress,
      COALESCE(progress.posted_receipt_count,0) posted_receipt_count,
      progress.last_received_at
    FROM public.supplier_order_lines line
    LEFT JOIN receipt_progress progress
      ON progress.supplier_order_line_id=line.id
    WHERE line.company_id=v_company
    ORDER BY line.document_id,line.line_no LIMIT 10000) line_row;

  RETURN jsonb_set(jsonb_set(v_base,'{requestLines}',v_request_lines,TRUE),
    '{orderLines}',v_order_lines,TRUE)||jsonb_build_object(
      'supplierOrderReceiptProgressVersion',1);
END
$$;

REVOKE ALL ON FUNCTION public.get_purchase_supplier_orders()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_supplier_orders()
TO authenticated,service_role;

DO $verify$
DECLARE v_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.get_purchase_supplier_orders()'::regprocedure)
  INTO v_definition;
  IF v_definition !~ 'receipt\.status[[:space:]]*=[[:space:]]*''POSTED'''
     OR v_definition !~ 'received_ordered_qty'
     OR v_definition !~ 'remaining_ordered_qty'
     OR v_definition !~ 'receipt_progress'
     OR v_definition !~ 'supplierOrderReceiptProgressVersion' THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: Supplier Order receipt progress read model';
  END IF;
END
$verify$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260831110000','purchase_supplier_order_receipt_progress_read_model',
  'Expose ordered, POSTED-received, and remaining quantity per Supplier Order line without changing PO, receipt, stock, or Finance data');

NOTIFY pgrst,'reload schema';
COMMIT;
