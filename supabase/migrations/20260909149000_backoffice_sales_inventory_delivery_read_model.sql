-- Expose Backoffice Sales Delivery Orders in the Inventory Surat Jalan workspace.
-- Read-only gate: operational Dispatch/Receive/Backorder mutations remain closed.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909148000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: combined Inventory reservation read model required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909149000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909149000';
  END IF;
  IF to_regprocedure('public.get_inventory_delivery_documents(date,date)') IS NULL
    OR to_regprocedure('public.get_inventory_stock_overview()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Inventory read dependency missing';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND (
        (table_name='backoffice_sales_delivery_orders' AND column_name IN(
          'id','company_id','sales_order_id','reservation_id','delivery_no',
          'sequence_no','delivery_kind','status','scheduled_date',
          'recipient_snapshot','total_planned_base_qty','total_shipped_base_qty',
          'total_received_base_qty','master_version','created_at'))
        OR (table_name='backoffice_sales_delivery_order_lines' AND column_name IN(
          'id','company_id','delivery_order_id','line_no','product_id','uom_id',
          'product_code_snapshot','product_name_snapshot','uom_code_snapshot',
          'uom_name_snapshot','base_qty_per_uom','planned_qty_uom',
          'planned_base_qty','shipped_base_qty','received_base_qty'))))<>30 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Delivery read schema incomplete';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_inventory_backoffice_delivery_orders(
  p_date_from date,p_date_to date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  IF p_date_from IS NOT NULL AND p_date_to IS NOT NULL AND p_date_from>p_date_to THEN
    RAISE EXCEPTION 'INVALID_DELIVERY_DATE_RANGE';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'workspaceVersion',1,
    'operationsReady',false,'dateFrom',p_date_from,'dateTo',p_date_to,
    'data',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'sourceChannel','BACKOFFICE_SALES','salesId',delivery.sales_order_id,
      'salesOrderNo',document.order_no,'deliveryDocumentId',delivery.id,
      'deliveryNo',delivery.delivery_no,'deliveryKind',delivery.delivery_kind,
      'status',delivery.status,'masterVersion',delivery.master_version,
      'invoiceNo',NULL,'createdAt',delivery.created_at,
      'scheduledAt',delivery.scheduled_date,
      'recipientName',COALESCE(delivery.recipient_snapshot->>'name',
        document.customer_snapshot->>'name','Pelanggan Umum'),
      'recipientPhone',COALESCE(delivery.recipient_snapshot->>'phone',
        document.customer_snapshot->>'phone'),
      'deliveryAddress',COALESCE(delivery.recipient_snapshot->>'address',
        document.customer_snapshot->>'address'),
      'customerName',COALESCE(document.customer_snapshot->>'name','Pelanggan Umum'),
      'storeName',COALESCE(store.store_name,'-'),
      'warehouseName',warehouse.name,'fulfillmentMode','DELIVERY',
      'reservationId',delivery.reservation_id,
      'reservationStatus',reservation.status,
      'totalReservedBaseQty',reservation.total_reserved_base_qty,
      'totalDispatchedBaseQty',delivery.total_shipped_base_qty,
      'totalReceivedBaseQty',delivery.total_received_base_qty,
      'operationsReady',false)
      ORDER BY delivery.scheduled_date DESC,delivery.created_at DESC,delivery.id)
    FROM (SELECT candidate.* FROM public.backoffice_sales_delivery_orders candidate
      WHERE candidate.company_id=v_company
        AND (p_date_from IS NULL OR candidate.scheduled_date>=p_date_from)
        AND (p_date_to IS NULL OR candidate.scheduled_date<=p_date_to)
      ORDER BY candidate.scheduled_date DESC,candidate.created_at DESC,candidate.id
      LIMIT 500) delivery
    JOIN public.backoffice_sales_orders document
      ON document.company_id=delivery.company_id
     AND document.id=delivery.sales_order_id
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=delivery.company_id
     AND reservation.id=delivery.reservation_id
    LEFT JOIN public.stores store ON store.company_id=document.company_id
      AND store.id=document.store_id
    JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
      AND warehouse.id=document.warehouse_id),'[]'::jsonb),
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'delivery_document_id',line.delivery_order_id,
      'line_no',line.line_no,'product_id',line.product_id,
      'product_sku_snapshot',line.product_code_snapshot,
      'product_name_snapshot',line.product_name_snapshot,
      'sale_uom_id',line.uom_id,'sale_uom_name_snapshot',line.uom_name_snapshot,
      'quantity_uom',line.planned_qty_uom,
      'quantity_base',line.planned_base_qty,
      'remaining_quantity_uom',GREATEST(
        line.planned_base_qty-line.shipped_base_qty,0)/line.base_qty_per_uom,
      'shipped_base_qty',line.shipped_base_qty,
      'received_base_qty',line.received_base_qty)
      ORDER BY line.delivery_order_id,line.line_no)
    FROM public.backoffice_sales_delivery_order_lines line
    JOIN public.backoffice_sales_delivery_orders delivery
      ON delivery.company_id=line.company_id
     AND delivery.id=line.delivery_order_id
    WHERE line.company_id=v_company
      AND (p_date_from IS NULL OR delivery.scheduled_date>=p_date_from)
      AND (p_date_to IS NULL OR delivery.scheduled_date<=p_date_to)),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION public.get_inventory_backoffice_delivery_orders(date,date)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_backoffice_delivery_orders(date,date)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909149000','backoffice_sales_inventory_delivery_read_model',
  'Inventory Surat Jalan can read tenant-scoped Backoffice INITIAL/BACKORDER Delivery and planned/shipped/received quantities; operational mutation remains fail-closed');

NOTIFY pgrst,'reload schema';
COMMIT;
