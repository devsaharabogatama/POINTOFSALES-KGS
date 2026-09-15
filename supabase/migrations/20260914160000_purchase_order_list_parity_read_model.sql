BEGIN;

DO $guard$
DECLARE v_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260806100000','20260807150000','20260831110000','20260914150000'))<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Order, Receipt, Supplier Invoice and client workspace chain required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914160000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914160000';
  END IF;
  IF to_regprocedure('public.get_purchase_supplier_orders()') IS NULL
     OR to_regprocedure('private.purchase_order_list_v1_base()') IS NOT NULL
     OR to_regprocedure('private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase list routine shape changed';
  END IF;
  SELECT pg_get_functiondef('public.get_purchase_supplier_orders()'::regprocedure)
  INTO v_definition;
  IF v_definition !~ 'supplierOrderReceiptProgressVersion' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Receipt progress reader required';
  END IF;
END
$guard$;

ALTER FUNCTION public.get_purchase_supplier_orders()
  RENAME TO purchase_order_list_v1_base;
ALTER FUNCTION public.purchase_order_list_v1_base()
  SET SCHEMA private;

CREATE FUNCTION private.classify_purchase_order_bill_status(
  p_billable_base_qty numeric,
  p_validated_base_qty numeric,
  p_draft_count integer,
  p_hold_count integer,
  p_supplier_ready boolean
) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path=public,pg_temp AS $$
  SELECT CASE
    WHEN NOT COALESCE(p_supplier_ready,false) THEN 'NOT_READY'
    WHEN greatest(COALESCE(p_billable_base_qty,0),0)=0 THEN 'NOT_READY'
    WHEN greatest(COALESCE(p_validated_base_qty,0),0)
      >=greatest(COALESCE(p_billable_base_qty,0),0) THEN 'BILLED'
    WHEN greatest(COALESCE(p_validated_base_qty,0),0)>0 THEN 'PARTIALLY_BILLED'
    WHEN COALESCE(p_hold_count,0)>0 THEN 'HOLD'
    WHEN COALESCE(p_draft_count,0)>0 THEN 'DRAFT'
    ELSE 'READY'
  END
$$;

CREATE FUNCTION public.get_purchase_supplier_orders()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_base jsonb;
  v_summaries jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  v_base:=private.purchase_order_list_v1_base();

  WITH order_scope AS (
    SELECT document.id,document.supplier_id
    FROM public.supplier_order_documents document
    WHERE document.company_id=v_company
    ORDER BY document.created_at DESC,document.id DESC LIMIT 500
  ), received AS (
    SELECT line.document_id supplier_order_id,
      sum(receipt_line.accepted_good_base_qty+receipt_line.damaged_base_qty)
        received_base_qty
    FROM order_scope scope
    JOIN public.supplier_order_lines line ON line.company_id=v_company
      AND line.document_id=scope.id
    JOIN public.goods_receipt_lines receipt_line ON receipt_line.company_id=line.company_id
      AND receipt_line.supplier_order_line_id=line.id
    JOIN public.goods_receipt_documents receipt ON receipt.company_id=receipt_line.company_id
      AND receipt.id=receipt_line.document_id AND receipt.status='POSTED'
    GROUP BY line.document_id
  ), returned AS (
    SELECT return_document.supplier_order_id,
      sum(return_line.return_base_qty) returned_base_qty
    FROM order_scope scope
    JOIN public.purchase_return_documents return_document
      ON return_document.company_id=v_company
      AND return_document.supplier_order_id=scope.id
      AND return_document.status='POSTED'
    JOIN public.purchase_return_lines return_line
      ON return_line.company_id=return_document.company_id
      AND return_line.document_id=return_document.id
    GROUP BY return_document.supplier_order_id
  ), invoice_totals AS (
    SELECT line.document_id supplier_order_id,
      sum(allocation.allocated_base_qty) FILTER(
        WHERE invoice.status='VALIDATED') validated_base_qty,
      count(DISTINCT invoice.id) FILTER(WHERE invoice.status='DRAFT') draft_count,
      count(DISTINCT invoice.id) FILTER(WHERE invoice.status='HOLD') hold_count
    FROM order_scope scope
    JOIN public.supplier_order_lines line ON line.company_id=v_company
      AND line.document_id=scope.id
    JOIN public.supplier_invoice_allocations allocation
      ON allocation.company_id=line.company_id
      AND allocation.supplier_order_line_id=line.id
    JOIN public.supplier_invoice_documents invoice
      ON invoice.company_id=allocation.company_id
      AND invoice.id=allocation.document_id AND invoice.status<>'CANCELED'
    GROUP BY line.document_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'supplierOrderId',scope.id,
      'billStatus',private.classify_purchase_order_bill_status(
        greatest(COALESCE(received.received_base_qty,0)
          -COALESCE(returned.returned_base_qty,0),0),
        COALESCE(invoice_totals.validated_base_qty,0),
        COALESCE(invoice_totals.draft_count,0)::integer,
        COALESCE(invoice_totals.hold_count,0)::integer,
        scope.supplier_id IS NOT NULL),
      'billableBaseQty',greatest(COALESCE(received.received_base_qty,0)
        -COALESCE(returned.returned_base_qty,0),0),
      'validatedBilledBaseQty',COALESCE(invoice_totals.validated_base_qty,0),
      'bills',COALESCE((SELECT jsonb_agg(to_jsonb(bill_row)
          ORDER BY bill_row.invoice_date DESC,bill_row.invoice_no DESC)
        FROM (SELECT DISTINCT invoice.id,invoice.invoice_no,
            invoice.supplier_invoice_no,invoice.invoice_date,invoice.due_date,
            invoice.status,invoice.matching_status
          FROM public.supplier_order_lines source_line
          JOIN public.supplier_invoice_allocations allocation
            ON allocation.company_id=source_line.company_id
            AND allocation.supplier_order_line_id=source_line.id
          JOIN public.supplier_invoice_documents invoice
            ON invoice.company_id=allocation.company_id
            AND invoice.id=allocation.document_id
            AND invoice.status<>'CANCELED'
          WHERE source_line.company_id=v_company
            AND source_line.document_id=scope.id) bill_row),'[]'::jsonb)
    ) ORDER BY scope.id),'[]'::jsonb)
  INTO v_summaries
  FROM order_scope scope
  LEFT JOIN received ON received.supplier_order_id=scope.id
  LEFT JOIN returned ON returned.supplier_order_id=scope.id
  LEFT JOIN invoice_totals ON invoice_totals.supplier_order_id=scope.id;

  RETURN v_base||jsonb_build_object(
    'supplierOrderListVersion',2,
    'supplierOrderBillSummaries',v_summaries);
END
$$;

REVOKE ALL ON FUNCTION
  private.purchase_order_list_v1_base(),
  private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.purchase_order_list_v1_base(),
  private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)
TO service_role;
REVOKE ALL ON FUNCTION public.get_purchase_supplier_orders() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_supplier_orders()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914160000','purchase_order_list_parity_read_model',
  'Add tenant-scoped PO Receipt and Supplier Bill list status/link projection; no Purchase, Receipt, Stock, AP, Payment or Finance mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
