-- ACP-5E: enforce Sales Document without widening POS, Return, or Finance.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813010000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ACP-5D required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260813020000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM public.access_permission_catalog
    WHERE permission_key='sales.sales_documents'
      AND enforcement_status='SHADOW')<>1 THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_PERMISSION_NOT_SHADOW';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_headers sale
    LEFT JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    WHERE sale.document_status='POSTED' AND invoice.id IS NULL) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: invoice snapshot gap';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_sales_documents()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'salesId',invoice.sales_id,
      'invoiceSnapshotId',invoice.id,
      'invoiceNo',invoice.invoice_no,
      'snapshotProvenance',invoice.snapshot_provenance,
      'postedAt',COALESCE(sale.posted_at,invoice.created_at),
      'total',sale.grand_total_after_rounding,
      'fulfillmentMode',sale.fulfillment_mode,
      'sourceChannel',sale.source_channel,
      'customerName',COALESCE(customer.name,'Walk-In Customer'),
      'storeName',COALESCE(store.store_name,'Store'),
      'delivery',CASE WHEN delivery.id IS NULL THEN NULL ELSE
        jsonb_build_object('id',delivery.id,
          'deliveryNo',delivery.delivery_no,'status',delivery.status,
          'masterVersion',delivery.master_version,
          'recipientName',delivery.recipient_name,
          'scheduledAt',delivery.scheduled_at) END
    ) ORDER BY invoice.created_at DESC,invoice.id)
    FROM (SELECT row_value.* FROM public.sales_invoice_snapshots row_value
      WHERE row_value.company_id=v_company
      ORDER BY row_value.created_at DESC,row_value.id LIMIT 500) invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    LEFT JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
  ),'[]'::JSONB));
END
$$;

CREATE FUNCTION public.export_sales_documents()
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
    'deliveryNo',delivery.delivery_no,'deliveryStatus',delivery.status,
    'deliveryRecipient',delivery.recipient_name,
    'deliveryScheduledAt',delivery.scheduled_at,
    'snapshotProvenance',invoice.snapshot_provenance)
    ORDER BY invoice.created_at DESC,invoice.id)
    FROM public.sales_invoice_snapshots invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    LEFT JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=sale.company_id AND delivery.sales_id=sale.id
    WHERE invoice.company_id=v_company),'[]'::JSONB);
END
$$;

ALTER FUNCTION public.get_sales_invoice_document(UUID)
  RENAME TO acp5e_get_sales_invoice_document_core;
ALTER FUNCTION public.acp5e_get_sales_invoice_document_core(UUID)
  SET SCHEMA private;
ALTER FUNCTION public.get_sales_delivery_document(UUID)
  RENAME TO acp5e_get_sales_delivery_document_core;
ALTER FUNCTION public.acp5e_get_sales_delivery_document_core(UUID)
  SET SCHEMA private;
ALTER FUNCTION public.record_sales_document_print(TEXT,UUID)
  RENAME TO acp5e_record_sales_document_print_core;
ALTER FUNCTION public.acp5e_record_sales_document_print_core(TEXT,UUID)
  SET SCHEMA private;
ALTER FUNCTION public.update_sales_delivery_status(UUID,BIGINT,TEXT,TEXT)
  RENAME TO acp5e_update_sales_delivery_status_core;
ALTER FUNCTION public.acp5e_update_sales_delivery_status_core(
  UUID,BIGINT,TEXT,TEXT) SET SCHEMA private;

CREATE FUNCTION public.get_sales_invoice_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_result JSONB;
  v_snapshot UUID;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  v_result:=private.acp5e_get_sales_invoice_document_core(p_sales_id);
  SELECT invoice.id INTO v_snapshot FROM public.sales_invoice_snapshots invoice
  WHERE invoice.company_id=v_company AND invoice.sales_id=p_sales_id;
  RETURN v_result||jsonb_build_object('invoiceSnapshotId',v_snapshot);
END
$$;

CREATE FUNCTION public.get_sales_delivery_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  RETURN private.acp5e_get_sales_delivery_document_core(p_sales_id);
END
$$;

CREATE FUNCTION public.record_sales_document_print(
  p_document_type TEXT,p_document_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  RETURN private.acp5e_record_sales_document_print_core(
    p_document_type,p_document_id);
END
$$;

CREATE FUNCTION public.update_sales_delivery_status(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_action TEXT,p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','MANAGE');
  RETURN private.acp5e_update_sales_delivery_status_core(
    p_delivery_document_id,p_master_version,p_action,p_reason);
END
$$;

CREATE FUNCTION public.get_pos_sales_invoice_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_result JSONB;
  v_snapshot UUID;
BEGIN
  IF NOT public.private_sales_document_visible(p_sales_id) THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND';
  END IF;
  v_result:=private.acp5e_get_sales_invoice_document_core(p_sales_id);
  SELECT invoice.id INTO v_snapshot FROM public.sales_invoice_snapshots invoice
  WHERE invoice.company_id=v_company AND invoice.sales_id=p_sales_id;
  RETURN v_result||jsonb_build_object('invoiceSnapshotId',v_snapshot);
END
$$;

CREATE FUNCTION public.get_pos_sales_delivery_document(p_sales_id UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT public.private_sales_document_visible(p_sales_id) THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND';
  END IF;
  RETURN private.acp5e_get_sales_delivery_document_core(p_sales_id);
END
$$;

CREATE FUNCTION public.record_pos_sales_document_print(
  p_document_type TEXT,p_document_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_sales UUID;v_company UUID:=public.private_active_company_id();
BEGIN
  IF upper(btrim(COALESCE(p_document_type,'')))='SALES_INVOICE' THEN
    SELECT invoice.sales_id INTO v_sales FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.id=p_document_id;
  ELSIF upper(btrim(COALESCE(p_document_type,'')))='SALES_DELIVERY' THEN
    SELECT delivery.sales_id INTO v_sales FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=v_company AND delivery.id=p_document_id;
  ELSE RAISE EXCEPTION 'INVALID_SALES_DOCUMENT_TYPE'; END IF;
  IF v_sales IS NULL OR NOT public.private_sales_document_visible(v_sales) THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND';
  END IF;
  RETURN private.acp5e_record_sales_document_print_core(
    p_document_type,p_document_id);
END
$$;

DO $enforce$
DECLARE v_rows BIGINT;
BEGIN
  UPDATE public.access_permission_catalog SET
    enforcement_status='ENFORCED',catalog_version=catalog_version+1,
    updated_at=clock_timestamp()
  WHERE permission_key='sales.sales_documents'
    AND enforcement_status='SHADOW';
  GET DIAGNOSTICS v_rows=ROW_COUNT;
  IF v_rows<>1 THEN RAISE EXCEPTION 'SALES_DOCUMENT_PERMISSION_CUTOVER_FAILED'; END IF;
END
$enforce$;

REVOKE SELECT ON public.sales_invoice_snapshots,
  public.sales_delivery_documents,public.sales_delivery_lines,
  public.sales_document_audit FROM authenticated;

REVOKE ALL ON FUNCTION
  private.acp5e_get_sales_invoice_document_core(UUID),
  private.acp5e_get_sales_delivery_document_core(UUID),
  private.acp5e_record_sales_document_print_core(TEXT,UUID),
  private.acp5e_update_sales_delivery_status_core(UUID,BIGINT,TEXT,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.acp5e_get_sales_invoice_document_core(UUID),
  private.acp5e_get_sales_delivery_document_core(UUID),
  private.acp5e_record_sales_document_print_core(TEXT,UUID),
  private.acp5e_update_sales_delivery_status_core(UUID,BIGINT,TEXT,TEXT)
TO service_role;

REVOKE ALL ON FUNCTION public.get_sales_documents(),
  public.export_sales_documents(),public.get_sales_invoice_document(UUID),
  public.get_sales_delivery_document(UUID),
  public.record_sales_document_print(TEXT,UUID),
  public.update_sales_delivery_status(UUID,BIGINT,TEXT,TEXT),
  public.get_pos_sales_invoice_document(UUID),
  public.get_pos_sales_delivery_document(UUID),
  public.record_pos_sales_document_print(TEXT,UUID)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_documents(),
  public.export_sales_documents(),public.get_sales_invoice_document(UUID),
  public.get_sales_delivery_document(UUID),
  public.record_sales_document_print(TEXT,UUID),
  public.update_sales_delivery_status(UUID,BIGINT,TEXT,TEXT),
  public.get_pos_sales_invoice_document(UUID),
  public.get_pos_sales_delivery_document(UUID),
  public.record_pos_sales_document_print(TEXT,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260813020000','acp_phase5e_sales_document_permission_enforcement',
  'Enforced Sales Document VIEW/MANAGE/EXPORT with composed Backoffice reads and independent POS posted-document access');

COMMIT;
