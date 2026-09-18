-- Backoffice Sales Return Step 5/5: UI read models only.
-- Adds permission-correct Inventory workspace, SO/Invoice links and unified
-- activity. It does not mutate Return, Stock, FIFO, Invoice, Payment or Finance.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260917151000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Refund reversal guard fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260918100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260918100000';
  END IF;
  IF to_regprocedure('public.get_backoffice_sales_return_receipt_workspace()') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_return_links(uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_return_activity(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return UI read-model collision';
  END IF;
END
$guard$;

CREATE FUNCTION public.get_backoffice_sales_return_receipt_workspace()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'inventory.customer_return_receipts','VIEW');
  RETURN jsonb_build_object('companyId',v_company,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'data',COALESCE((SELECT jsonb_agg(
      private.backoffice_sales_return_snapshot(v_company,candidate.id)
      ORDER BY candidate.updated_at,candidate.id)
      FROM public.backoffice_sales_returns candidate
      WHERE candidate.company_id=v_company
        AND candidate.status IN('APPROVED','PARTIALLY_RECEIVED','RECEIVED')
        AND candidate.total_received_base_qty<candidate.total_requested_base_qty),'[]'::jsonb),
    'warehouses',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',warehouse.id,'code',warehouse.code,'name',warehouse.name)
      ORDER BY warehouse.name,warehouse.id)
      FROM public.warehouses warehouse
      WHERE warehouse.company_id=v_company AND warehouse.is_active),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.get_backoffice_sales_return_links(p_sales_order_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((SELECT jsonb_agg(
    jsonb_build_object('salesOrderId',document.sales_order_id,'returnId',document.id,
      'returnNo',document.return_no,'status',document.status,
      'totalRequestedBaseQty',document.total_requested_base_qty,
      'totalReceivedBaseQty',document.total_received_base_qty,'updatedAt',document.updated_at)
    ORDER BY document.updated_at DESC,document.id)
    FROM public.backoffice_sales_returns document
    WHERE document.company_id=v_company
      AND (p_sales_order_id IS NULL OR document.sales_order_id=p_sales_order_id)),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.get_backoffice_sales_return_activity(p_return_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_returns','VIEW');
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_returns document
    WHERE document.company_id=v_company AND document.id=p_return_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_NOT_FOUND';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'returnId',p_return_id,
    'data',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'source',activity.source,'action',activity.action,'documentId',activity.document_id,
      'documentNo',activity.document_no,'actorId',activity.actor_id,
      'actorName',COALESCE(profile.name,profile.email,'Sistem'),
      'reason',activity.reason,'createdAt',activity.created_at)
      ORDER BY activity.created_at,activity.source,activity.document_id)
    FROM (
      SELECT 'RETURN'::text source,audit.action,audit.return_id document_id,
        document.return_no document_no,audit.actor_id,audit.reason,audit.created_at
      FROM public.backoffice_sales_return_audit audit
      JOIN public.backoffice_sales_returns document ON document.company_id=audit.company_id
        AND document.id=audit.return_id
      WHERE audit.company_id=v_company AND audit.return_id=p_return_id
      UNION ALL
      SELECT 'RECEIPT','POST',audit.receipt_id,receipt.receipt_no,audit.actor_id,
        receipt.notes,audit.created_at
      FROM public.backoffice_sales_return_receipt_audit audit
      JOIN public.backoffice_sales_return_receipts receipt ON receipt.company_id=audit.company_id
        AND receipt.id=audit.receipt_id
      WHERE audit.company_id=v_company AND audit.return_id=p_return_id
      UNION ALL
      SELECT 'CREDIT_NOTE',audit.action,audit.credit_note_id,note.credit_note_no,
        audit.actor_id,note.reason,audit.created_at
      FROM public.backoffice_sales_credit_note_audit audit
      LEFT JOIN public.backoffice_sales_credit_notes note ON note.company_id=audit.company_id
        AND note.id=audit.credit_note_id
      WHERE audit.company_id=v_company AND audit.return_id=p_return_id
        AND audit.credit_note_id IS NOT NULL
      UNION ALL
      SELECT 'REFUND',audit.action,audit.refund_id,refund.refund_no,
        audit.actor_id,refund.notes,audit.created_at
      FROM public.backoffice_sales_customer_refund_audit audit
      JOIN public.backoffice_sales_credit_notes note ON note.company_id=audit.company_id
        AND note.id=audit.credit_note_id
      JOIN public.backoffice_sales_customer_refunds refund ON refund.company_id=audit.company_id
        AND refund.id=audit.refund_id
      WHERE audit.company_id=v_company AND note.return_id=p_return_id
    ) activity
    LEFT JOIN public.profiles profile ON profile.id=activity.actor_id),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION public.get_backoffice_sales_return_receipt_workspace(),
  public.get_backoffice_sales_return_links(uuid),
  public.get_backoffice_sales_return_activity(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_return_receipt_workspace(),
  public.get_backoffice_sales_return_links(uuid),
  public.get_backoffice_sales_return_activity(uuid) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260918100000','backoffice_sales_return_ui_read_models',
  'Step 5/5 permission-correct Inventory workspace, SO/Invoice return links and unified Return activity; read-only runtime only');
NOTIFY pgrst,'reload schema';
COMMIT;
