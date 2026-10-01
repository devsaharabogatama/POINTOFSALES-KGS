BEGIN;

DO $guard$
BEGIN
  IF to_regclass('public.sales_delivery_documents') IS NULL
    OR to_regclass('public.backoffice_sales_delivery_orders') IS NULL
    OR to_regclass('public.backoffice_sales_returns') IS NULL
    OR to_regclass('public.backoffice_sales_return_receipts') IS NULL
    OR to_regprocedure('public.private_active_company_id()') IS NULL
    OR to_regprocedure(
      'private.acp_require_permission_capability(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: canonical Delivery/Return runtime missing';
  END IF;
  IF to_regprocedure(
      'public.get_inventory_delivery_return_overlays(date,date)') IS NOT NULL THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Delivery Return overlay collision';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_inventory_delivery_return_overlays(
  p_date_from date DEFAULT NULL,p_date_to date DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_timezone text;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  IF p_date_from IS NOT NULL AND p_date_to IS NOT NULL
    AND p_date_from>p_date_to THEN
    RAISE EXCEPTION 'INVALID_DELIVERY_DATE_RANGE';
  END IF;
  SELECT company.timezone INTO v_timezone
  FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;

  RETURN jsonb_build_object(
    'workspaceVersion',1,
    'companyId',v_company,
    'data',COALESCE((
      WITH delivery_scope AS (
        SELECT 'POS'::text source_channel,delivery.id delivery_document_id,
          delivery.sales_id source_document_id,'EXACT_DELIVERY'::text attribution
        FROM (SELECT candidate.*
          FROM public.sales_delivery_documents candidate
          WHERE candidate.company_id=v_company
          AND (p_date_from IS NULL OR
            (COALESCE(candidate.scheduled_at,candidate.created_at)
              AT TIME ZONE v_timezone)::date>=p_date_from)
          AND (p_date_to IS NULL OR
            (COALESCE(candidate.scheduled_at,candidate.created_at)
              AT TIME ZONE v_timezone)::date<=p_date_to)
          ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) delivery
        UNION ALL
        SELECT 'BACKOFFICE_SALES',delivery.id,delivery.sales_order_id,
          'SALES_ORDER'
        FROM (SELECT candidate.*
          FROM public.backoffice_sales_delivery_orders candidate
          WHERE candidate.company_id=v_company
          AND (p_date_from IS NULL OR candidate.scheduled_date>=p_date_from)
          AND (p_date_to IS NULL OR candidate.scheduled_date<=p_date_to)
          ORDER BY candidate.scheduled_date DESC,candidate.created_at DESC,
            candidate.id LIMIT 500) delivery
      ), linked_return AS (
        SELECT scope.source_channel,scope.delivery_document_id,
          scope.attribution,document.*
        FROM delivery_scope scope
        JOIN public.backoffice_sales_returns document
          ON document.company_id=v_company
          AND ((scope.source_channel='POS'
              AND document.source_kind='RETAINED_RETAIL'
              AND document.retail_sales_id=scope.source_document_id)
            OR (scope.source_channel='BACKOFFICE_SALES'
              AND document.source_kind='BACKOFFICE'
              AND document.sales_order_id=scope.source_document_id))
      )
      SELECT jsonb_agg(jsonb_build_object(
        'sourceChannel',grouped.source_channel,
        'deliveryDocumentId',grouped.delivery_document_id,
        'attribution',grouped.attribution,
        'returns',grouped.return_documents
      ) ORDER BY grouped.source_channel,grouped.delivery_document_id)
      FROM (
        SELECT linked.source_channel,linked.delivery_document_id,
          linked.attribution,jsonb_agg(jsonb_build_object(
            'returnId',linked.id,
            'returnNo',linked.return_no,
            'status',linked.status,
            'reason',linked.reason,
            'requestedBaseQty',linked.total_requested_base_qty,
            'receivedBaseQty',linked.total_received_base_qty,
            'restockedBaseQty',linked.total_restocked_base_qty,
            'destroyedBaseQty',linked.total_destroyed_base_qty,
            'goodsStatus',CASE
              WHEN linked.status='CANCELED' THEN 'CANCELED'
              WHEN linked.total_received_base_qty=0 THEN 'NOT_RECEIVED'
              WHEN linked.total_received_base_qty<linked.total_requested_base_qty
                THEN 'PARTIALLY_RECEIVED'
              ELSE 'RECEIVED' END,
            'receiptCount',(SELECT count(*)
              FROM public.backoffice_sales_return_receipts receipt
              WHERE receipt.company_id=linked.company_id
                AND receipt.return_id=linked.id),
            'updatedAt',linked.updated_at
          ) ORDER BY linked.updated_at DESC,linked.id) return_documents
        FROM linked_return linked
        GROUP BY linked.source_channel,linked.delivery_document_id,
          linked.attribution
      ) grouped
    ),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION
  public.get_inventory_delivery_return_overlays(date,date)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_inventory_delivery_return_overlays(date,date)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261001110000','delivery_return_status_overlay',
  'Adds an Inventory VIEW-scoped read-only Return overlay for Retail and Backoffice Delivery lists/details; Delivery/Return/Receipt/Stock/FIFO/Invoice/Payment/Finance data remains immutable');

NOTIFY pgrst,'reload schema';
COMMIT;

