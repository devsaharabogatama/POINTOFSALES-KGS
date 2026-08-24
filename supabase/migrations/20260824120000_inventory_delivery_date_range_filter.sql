-- Inventory Delivery Documents: optional Company-timezone date range filter.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260824110000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: distributor Pricelist forward fix required';
  END IF;
  IF EXISTS(
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260824120000'
  ) THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260824120000';
  END IF;
  IF to_regprocedure('public.get_inventory_delivery_documents()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Inventory Delivery runtime required';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_inventory_delivery_documents(
  p_date_from DATE,p_date_to DATE
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_timezone TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  IF p_date_from IS NOT NULL AND p_date_to IS NOT NULL
     AND p_date_from>p_date_to THEN
    RAISE EXCEPTION 'INVALID_DELIVERY_DATE_RANGE';
  END IF;
  SELECT company.timezone INTO v_timezone
  FROM public.companies company WHERE company.id=v_company;
  v_timezone:=COALESCE(v_timezone,'Asia/Jakarta');

  RETURN jsonb_build_object('companyId',v_company,'dateFrom',p_date_from,
    'dateTo',p_date_to,'timezone',v_timezone,'data',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'salesId',delivery.sales_id,'deliveryDocumentId',delivery.id,
      'deliveryNo',delivery.delivery_no,'status',delivery.status,
      'masterVersion',delivery.master_version,
      'invoiceNo',invoice.invoice_no,
      'createdAt',delivery.created_at,'scheduledAt',delivery.scheduled_at,
      'recipientName',delivery.recipient_name,
      'recipientPhone',delivery.recipient_phone,
      'deliveryAddress',delivery.delivery_address,
      'customerName',COALESCE(customer.name,'Walk-In Customer'),
      'storeName',COALESCE(store.store_name,'Store'),
      'warehouseName',COALESCE(warehouse.name,'Gudang'))
      ORDER BY delivery.created_at DESC,delivery.id)
    FROM (SELECT candidate.* FROM public.sales_delivery_documents candidate
      WHERE candidate.company_id=v_company
        AND (p_date_from IS NULL OR
          (COALESCE(candidate.scheduled_at,candidate.created_at)
            AT TIME ZONE v_timezone)::DATE>=p_date_from)
        AND (p_date_to IS NULL OR
          (COALESCE(candidate.scheduled_at,candidate.created_at)
            AT TIME ZONE v_timezone)::DATE<=p_date_to)
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) delivery
    JOIN public.sales_headers sale ON sale.company_id=delivery.company_id
      AND sale.id=delivery.sales_id
    JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=delivery.company_id
      AND invoice.sales_id=delivery.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    LEFT JOIN public.warehouses warehouse
      ON warehouse.company_id=delivery.company_id
      AND warehouse.id=delivery.warehouse_id
  ),'[]'::JSONB));
END
$$;

REVOKE ALL ON FUNCTION public.get_inventory_delivery_documents(DATE,DATE)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_delivery_documents(DATE,DATE)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260824120000','inventory_delivery_date_range_filter',
  'Company-timezone inclusive date range filter for Inventory Delivery Documents while preserving the no-argument compatibility RPC');

COMMIT;
