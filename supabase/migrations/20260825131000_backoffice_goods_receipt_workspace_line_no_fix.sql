-- Forward-fix: draftLines ordering requires line_no in the composed row.
BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Goods Receipt required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260825131000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_backoffice_goods_receipt_workspace()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.goods_receipts','VIEW');
  RETURN jsonb_build_object(
    'orders',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.expected_date NULLS LAST,row_data.order_no),'[]'::JSONB)
      FROM (SELECT document.id,document.order_no,document.store_id,
          document.supplier_id,supplier.supplier_name,
          document.destination_warehouse_id,warehouse.name warehouse_name,
          document.status,document.expected_date
        FROM public.supplier_order_documents document
        JOIN public.suppliers supplier ON supplier.company_id=document.company_id
          AND supplier.id=document.supplier_id
        JOIN public.warehouses warehouse
          ON warehouse.company_id=document.company_id
         AND warehouse.id=document.destination_warehouse_id
        WHERE document.company_id=v_company
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')) row_data),
    'orderLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.document_id,row_data.line_no),'[]'::JSONB)
      FROM (SELECT line.id,line.document_id,line.line_no,line.product_id,
          line.ordered_uom_id,line.ordered_qty,line.ordered_base_qty,
          line.product_name_snapshot,line.ordered_uom_name_snapshot,
          GREATEST(line.ordered_base_qty-COALESCE((SELECT sum(
              receipt_line.received_base_qty)
            FROM public.goods_receipt_lines receipt_line
            JOIN public.goods_receipt_documents receipt
              ON receipt.company_id=receipt_line.company_id
             AND receipt.id=receipt_line.document_id
             AND receipt.status='POSTED'
            WHERE receipt_line.company_id=v_company
              AND receipt_line.supplier_order_line_id=line.id),0),0)
            remaining_base_qty
        FROM public.supplier_order_lines line
        JOIN public.supplier_order_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company
          AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED')) row_data),
    'productUoms',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'product_id',product_uom.product_id,'uom_id',product_uom.uom_id,
        'factor_to_base',product_uom.factor_to_base,'uom_name',uom.name,
        'allow_decimal',uom.allow_decimal,
        'decimal_precision',uom.decimal_precision)
      ORDER BY product_uom.product_id,product_uom.factor_to_base DESC,uom.name),
      '[]'::JSONB)
      FROM public.product_uoms product_uom
      JOIN public.uoms uom ON uom.company_id=product_uom.company_id
        AND uom.id=product_uom.uom_id
      WHERE product_uom.company_id=v_company AND product_uom.is_active
        AND product_uom.purchase_allowed AND uom.is_active
        AND EXISTS(SELECT 1 FROM public.supplier_order_lines line
          JOIN public.supplier_order_documents document
            ON document.company_id=line.company_id AND document.id=line.document_id
          WHERE line.company_id=v_company
            AND line.product_id=product_uom.product_id
            AND document.status IN('CONFIRMED','PARTIALLY_RECEIVED'))),
    'drafts',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.received_at DESC,row_data.id),'[]'::JSONB)
      FROM (SELECT document.id,document.receipt_no,document.supplier_order_id,
          document.supplier_delivery_no,document.notes,document.master_version,
          document.received_at
        FROM public.goods_receipt_documents document
        WHERE document.company_id=v_company AND document.status='DRAFT'
          AND document.source_channel='BACKOFFICE'
          AND document.received_by=auth.uid()) row_data),
    'draftLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.document_id,row_data.line_no),'[]'::JSONB)
      FROM (SELECT line.document_id,line.line_no,line.client_line_key,
          line.supplier_order_line_id,line.received_uom_id,
          line.received_qty,line.accepted_good_qty,line.damaged_qty,
          line.rejected_qty
        FROM public.goods_receipt_lines line
        JOIN public.goods_receipt_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
        WHERE line.company_id=v_company AND document.status='DRAFT'
          AND document.source_channel='BACKOFFICE'
          AND document.received_by=auth.uid()) row_data));
END $$;

REVOKE ALL ON FUNCTION public.get_backoffice_goods_receipt_workspace()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_goods_receipt_workspace()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260825131000','backoffice_goods_receipt_workspace_line_no_fix',
  'Adds line_no to the draftLines composed row so deterministic JSON ordering is valid');
NOTIFY pgrst,'reload schema';
COMMIT;
