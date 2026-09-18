-- Adds a read-only commercial lifecycle for Invoice lists.
-- Source Invoice rows remain immutable; Return/Credit Note documents provide
-- the derived status shown to users.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Retail Credit Note bridge required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260918160000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260918160000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.derive_sales_invoice_commercial_status(boolean,numeric,numeric,boolean)') IS NOT NULL
    OR to_regprocedure('public.get_sales_invoice_commercial_statuses()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice commercial status routine collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.derive_sales_invoice_commercial_status(
  p_canceled boolean,p_invoice_total numeric,p_credited_total numeric,
  p_has_non_canceled_return boolean
) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
    WHEN p_canceled THEN 'CANCELED'
    WHEN COALESCE(p_invoice_total,0)>0
      AND round(COALESCE(p_credited_total,0),4)>=round(p_invoice_total,4)
      THEN 'RETURNED'
    WHEN round(COALESCE(p_credited_total,0),4)>0 THEN 'PARTIALLY_RETURNED'
    WHEN COALESCE(p_has_non_canceled_return,false) THEN 'RETURN_IN_PROGRESS'
    ELSE 'ACTIVE'
  END
$$;

CREATE FUNCTION public.get_sales_invoice_commercial_statuses()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_retail_permission jsonb;v_backoffice_permission jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF NOT public.private_request_company_matches(v_company) THEN
    RAISE EXCEPTION 'ACTIVE_COMPANY_CONTEXT_MISMATCH';
  END IF;
  v_retail_permission:=private.acp_resolve_permission(
    v_company,v_actor,'sales.sales_documents');
  v_backoffice_permission:=private.acp_resolve_permission(
    v_company,v_actor,'sales.backoffice_orders');
  IF (v_retail_permission->>'enforced')::boolean
      AND NOT ((v_retail_permission->'effectiveCapabilities') ? 'VIEW')
    AND (v_backoffice_permission->>'enforced')::boolean
      AND NOT ((v_backoffice_permission->'effectiveCapabilities') ? 'VIEW') THEN
    RAISE EXCEPTION 'CUSTOM_PERMISSION_DENIED';
  END IF;

  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
    SELECT jsonb_agg(status_row.payload ORDER BY status_row.sort_at DESC,status_row.source_id)
    FROM (
      SELECT sale.id source_id,COALESCE(sale.posted_at,sale.confirmed_at,sale.created_at) sort_at,
        jsonb_build_object(
          'sourceKind','RETAIL','sourceId',sale.id,
          'commercialStatus',private.derive_sales_invoice_commercial_status(
            sale.order_runtime_status='CANCELED' OR sale.document_status='CANCELED',
            sale.grand_total_after_rounding,
            COALESCE(native_credit.amount,0)+COALESCE(bridge_credit.amount,0),
            COALESCE(native_credit.has_return,false)
              OR COALESCE(bridge_return.has_return,false)),
          'invoiceTotal',sale.grand_total_after_rounding,
          'creditedAmount',COALESCE(native_credit.amount,0)+COALESCE(bridge_credit.amount,0),
          'returnNo',COALESCE(bridge_return.return_no,native_credit.return_no),
          'returnStatus',COALESCE(bridge_return.return_status,native_credit.return_status),
          'creditNoteNo',bridge_credit.credit_note_no,
          'creditNoteStatus',bridge_credit.credit_note_status
        ) payload
      FROM public.sales_headers sale
      JOIN public.sales_invoice_snapshots invoice
        ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
      LEFT JOIN LATERAL(
        SELECT round(COALESCE(sum(document.refund_total)
          FILTER(WHERE document.status='POSTED'),0),4) amount,
          count(*) FILTER(WHERE document.status<>'CANCELED')>0 has_return,
          (array_agg(document.return_no ORDER BY document.created_at DESC,document.id DESC)
            FILTER(WHERE document.status<>'CANCELED'))[1] return_no,
          (array_agg(document.status ORDER BY document.created_at DESC,document.id DESC)
            FILTER(WHERE document.status<>'CANCELED'))[1] return_status
        FROM public.sales_return_documents document
        WHERE document.company_id=sale.company_id AND document.source_sales_id=sale.id
      ) native_credit ON true
      LEFT JOIN LATERAL(
        SELECT count(*)>0 has_return,
          (array_agg(document.return_no ORDER BY document.created_at DESC,document.id DESC))[1] return_no,
          (array_agg(document.status ORDER BY document.created_at DESC,document.id DESC))[1] return_status
        FROM public.backoffice_sales_returns document
        WHERE document.company_id=sale.company_id
          AND document.source_kind='RETAINED_RETAIL'
          AND document.retail_sales_id=sale.id AND document.status<>'CANCELED'
      ) bridge_return ON true
      LEFT JOIN LATERAL(
        SELECT round(COALESCE(sum(note.grand_total)
          FILTER(WHERE note.status='POSTED'),0),4) amount,
          (array_agg(note.credit_note_no ORDER BY note.created_at DESC,note.id DESC)
            FILTER(WHERE note.status<>'CANCELED'))[1] credit_note_no,
          (array_agg(note.status ORDER BY note.created_at DESC,note.id DESC)
            FILTER(WHERE note.status<>'CANCELED'))[1] credit_note_status
        FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=sale.company_id AND note.source_kind='RETAINED_RETAIL'
          AND note.source_retail_sales_id=sale.id
      ) bridge_credit ON true
      WHERE sale.company_id=v_company

      UNION ALL

      SELECT invoice.id source_id,invoice.created_at sort_at,
        jsonb_build_object(
          'sourceKind','BACKOFFICE','sourceId',invoice.id,
          'commercialStatus',private.derive_sales_invoice_commercial_status(
            invoice.status='CANCELED',invoice.grand_total,
            COALESCE(credit.amount,CASE WHEN invoice.status='REVERSED'
              THEN invoice.grand_total ELSE 0 END),
            COALESCE(credit.has_return,false) OR invoice.status='REVERSED'),
          'invoiceTotal',invoice.grand_total,
          'creditedAmount',COALESCE(credit.amount,CASE WHEN invoice.status='REVERSED'
            THEN invoice.grand_total ELSE 0 END),
          'returnNo',credit.return_no,'returnStatus',credit.return_status,
          'creditNoteNo',credit.credit_note_no,'creditNoteStatus',credit.credit_note_status
        ) payload
      FROM public.backoffice_sales_invoices invoice
      LEFT JOIN LATERAL(
        SELECT round(COALESCE(sum(note.grand_total)
          FILTER(WHERE note.status='POSTED'),0),4) amount,
          count(*) FILTER(WHERE note.status<>'CANCELED')>0 has_return,
          (array_agg(document.return_no ORDER BY note.created_at DESC,note.id DESC)
            FILTER(WHERE note.status<>'CANCELED'))[1] return_no,
          (array_agg(document.status ORDER BY note.created_at DESC,note.id DESC)
            FILTER(WHERE note.status<>'CANCELED'))[1] return_status,
          (array_agg(note.credit_note_no ORDER BY note.created_at DESC,note.id DESC)
            FILTER(WHERE note.status<>'CANCELED'))[1] credit_note_no,
          (array_agg(note.status ORDER BY note.created_at DESC,note.id DESC)
            FILTER(WHERE note.status<>'CANCELED'))[1] credit_note_status
        FROM public.backoffice_sales_credit_notes note
        JOIN public.backoffice_sales_returns document
          ON document.company_id=note.company_id AND document.id=note.return_id
        WHERE note.company_id=invoice.company_id AND note.source_kind='BACKOFFICE'
          AND note.source_invoice_id=invoice.id
      ) credit ON true
      WHERE invoice.company_id=v_company
    ) status_row
  ),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION private.derive_sales_invoice_commercial_status(
  boolean,numeric,numeric,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.derive_sales_invoice_commercial_status(
  boolean,numeric,numeric,boolean) TO service_role;
REVOKE ALL ON FUNCTION public.get_sales_invoice_commercial_statuses()
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_sales_invoice_commercial_statuses()
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260918160000','sales_invoice_return_commercial_status',
  'Read-only Retail and Backoffice Invoice commercial status derived from immutable Return and Credit Note history');
NOTIFY pgrst,'reload schema';

COMMIT;
