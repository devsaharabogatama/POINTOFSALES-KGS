-- Selected Supplier Order XLSX export. Existing all-order export is preserved.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260820120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260820120000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260820130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260820130000';
  END IF;
  IF to_regprocedure('public.export_purchase_supplier_orders()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Supplier Order export foundation missing';
  END IF;
END
$guard$;

CREATE FUNCTION public.export_purchase_supplier_orders(p_document_ids UUID[])
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_requested INTEGER;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','EXPORT');
  IF p_document_ids IS NULL OR cardinality(p_document_ids)<1 THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_EXPORT_SELECTION_REQUIRED';
  END IF;
  IF cardinality(p_document_ids)>100 THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_EXPORT_SELECTION_LIMIT_EXCEEDED';
  END IF;
  IF array_position(p_document_ids,NULL) IS NOT NULL
     OR cardinality(p_document_ids)<>(SELECT count(DISTINCT selected_id)
       FROM unnest(p_document_ids) AS selected(selected_id)) THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_EXPORT_SELECTION_INVALID';
  END IF;
  SELECT count(*) INTO v_requested FROM public.supplier_order_documents document
  WHERE document.company_id=v_company AND document.id=ANY(p_document_ids);
  IF v_requested<>cardinality(p_document_ids) THEN
    RAISE EXCEPTION 'SUPPLIER_ORDER_EXPORT_NOT_FOUND_OR_ACCESS_DENIED';
  END IF;

  RETURN jsonb_build_object(
    'companyId',v_company,
    'companyName',(SELECT company.company_name FROM public.companies company WHERE company.id=v_company),
    'companyCode',(SELECT company.company_code FROM public.companies company WHERE company.id=v_company),
    'selectionCount',cardinality(p_document_ids),
    'orders',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'orderId',document.id,'orderNo',document.order_no,'orderDate',document.order_date,
      'expectedDate',document.expected_date,'supplierId',document.supplier_id,
      'supplierName',supplier.supplier_name,'storeId',document.store_id,
      'storeName',store.store_name,'warehouseId',document.destination_warehouse_id,
      'warehouseName',warehouse.name,'status',document.status,'notes',document.notes,
      'lineCount',document.line_count,'totalOrderedBaseQty',document.total_ordered_base_qty,
      'estimatedTotal',document.estimated_total)
      ORDER BY document.order_date DESC,document.order_no DESC)
      FROM public.supplier_order_documents document
      JOIN public.suppliers supplier ON supplier.company_id=document.company_id
        AND supplier.id=document.supplier_id
      JOIN public.stores store ON store.company_id=document.company_id
        AND store.id=document.store_id
      JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
        AND warehouse.id=document.destination_warehouse_id
      WHERE document.company_id=v_company AND document.id=ANY(p_document_ids)),'[]'::JSONB),
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'orderId',document.id,'orderNo',document.order_no,'orderDate',document.order_date,
      'supplierId',document.supplier_id,'supplierName',supplier.supplier_name,
      'storeId',document.store_id,'storeName',store.store_name,
      'warehouseName',warehouse.name,'status',document.status,'lineNo',line.line_no,
      'sku',line.product_sku_snapshot,'productName',line.product_name_snapshot,
      'uomName',line.ordered_uom_name_snapshot,'orderedQty',line.ordered_qty,
      'orderedBaseQty',line.ordered_base_qty,'estimatedUnitPrice',line.estimated_unit_price,
      'estimatedSubtotal',line.estimated_subtotal)
      ORDER BY document.order_date DESC,document.order_no DESC,line.line_no)
      FROM public.supplier_order_lines line
      JOIN public.supplier_order_documents document ON document.company_id=line.company_id
        AND document.id=line.document_id
      JOIN public.suppliers supplier ON supplier.company_id=document.company_id
        AND supplier.id=document.supplier_id
      JOIN public.stores store ON store.company_id=document.company_id
        AND store.id=document.store_id
      JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
        AND warehouse.id=document.destination_warehouse_id
      WHERE line.company_id=v_company AND document.id=ANY(p_document_ids)),'[]'::JSONB));
END
$$;

REVOKE ALL ON FUNCTION public.export_purchase_supplier_orders(UUID[])
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.export_purchase_supplier_orders(UUID[])
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260820130000','selected_supplier_order_export',
  'Adds tenant-validated maximum-100 selected Supplier Order export while preserving the legacy all-order export signature');
NOTIFY pgrst,'reload schema';
COMMIT;
