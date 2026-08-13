-- Inventory-owned Surat Jalan authority without changing canonical Sale documents.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Company access lifecycle required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='sales.sales_documents'
      AND enforcement_status='ENFORCED')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales Document enforcement required';
  END IF;
END
$guard$;

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'inventory.delivery_documents','INVENTORY','Surat Jalan',
  'Persiapan, cetak, pengiriman, dan penerimaan Surat Jalan',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],
  '{}',ARRAY['VIEW','MANAGE'],'{}',TRUE,'ENFORCED'
);

UPDATE public.access_permission_catalog SET
  permission_label='Invoice Penjualan',
  description='Snapshot final Invoice penjualan',
  operator_roles='{}',
  supported_capabilities=ARRAY['VIEW','EXPORT'],
  catalog_version=catalog_version+1,
  updated_at=clock_timestamp()
WHERE permission_key='sales.sales_documents';

CREATE OR REPLACE FUNCTION public.get_sales_documents()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'salesId',invoice.sales_id,'invoiceSnapshotId',invoice.id,
      'invoiceNo',invoice.invoice_no,
      'snapshotProvenance',invoice.snapshot_provenance,
      'postedAt',COALESCE(sale.posted_at,invoice.created_at),
      'total',sale.grand_total_after_rounding,
      'fulfillmentMode',sale.fulfillment_mode,
      'sourceChannel',sale.source_channel,
      'customerName',COALESCE(customer.name,'Walk-In Customer'),
      'storeName',COALESCE(store.store_name,'Store'))
      ORDER BY invoice.created_at DESC,invoice.id)
    FROM (SELECT candidate.* FROM public.sales_invoice_snapshots candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
  ),'[]'::JSONB));
END
$$;

CREATE OR REPLACE FUNCTION public.export_sales_documents()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','EXPORT');
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'invoiceNo',invoice.invoice_no,'postedAt',sale.posted_at,
    'customerName',COALESCE(customer.name,'Walk-In Customer'),
    'storeName',COALESCE(store.store_name,'Store'),
    'sourceChannel',sale.source_channel,
    'fulfillmentMode',sale.fulfillment_mode,
    'grandTotal',sale.grand_total_after_rounding,
    'deliveryFee',sale.delivery_fee_amount,
    'snapshotProvenance',invoice.snapshot_provenance)
    ORDER BY invoice.created_at DESC,invoice.id)
    FROM public.sales_invoice_snapshots invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    WHERE invoice.company_id=v_company),'[]'::JSONB);
END
$$;

CREATE FUNCTION public.get_inventory_delivery_documents()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
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

CREATE FUNCTION public.get_inventory_delivery_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  RETURN private.acp5e_get_sales_delivery_document_core(p_sales_id);
END
$$;

CREATE FUNCTION public.record_inventory_delivery_print(p_delivery_document_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  IF NOT EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id) THEN
    RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND';
  END IF;
  RETURN private.acp5e_record_sales_document_print_core(
    'SALES_DELIVERY',p_delivery_document_id);
END
$$;

CREATE OR REPLACE FUNCTION public.get_sales_delivery_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RETURN public.get_inventory_delivery_document(p_sales_id);
END
$$;

CREATE OR REPLACE FUNCTION public.record_sales_document_print(
  p_document_type TEXT,p_document_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_type TEXT:=upper(btrim(COALESCE(p_document_type,'')));
BEGIN
  IF v_type='SALES_INVOICE' THEN
    PERFORM private.acp_require_permission_capability(
      v_company,'sales.sales_documents','VIEW');
  ELSIF v_type='SALES_DELIVERY' THEN
    RETURN public.record_inventory_delivery_print(p_document_id);
  ELSE
    RAISE EXCEPTION 'INVALID_SALES_DOCUMENT_TYPE';
  END IF;
  RETURN private.acp5e_record_sales_document_print_core(v_type,p_document_id);
END
$$;

CREATE OR REPLACE FUNCTION public.update_sales_delivery_status(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_action TEXT,p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.acp5e_update_sales_delivery_status_core(
    p_delivery_document_id,p_master_version,p_action,p_reason);
END
$$;

REVOKE ALL ON FUNCTION public.get_inventory_delivery_documents(),
  public.get_inventory_delivery_document(UUID),
  public.record_inventory_delivery_print(UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_delivery_documents(),
  public.get_inventory_delivery_document(UUID),
  public.record_inventory_delivery_print(UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813150000','inventory_delivery_document_authority',
  'Separates Inventory Surat Jalan VIEW/MANAGE from Sales Invoice VIEW/EXPORT while preserving POS and canonical document history');

COMMIT;
