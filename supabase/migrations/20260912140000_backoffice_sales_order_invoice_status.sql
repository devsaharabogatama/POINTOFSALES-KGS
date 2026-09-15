-- Canonical Invoice lifecycle projection for the Backoffice Sales Order list.
-- Read-model only: no historical document, Stock, Payment or Finance mutation.
BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260909142000','20260909152000','20260910150000',
      '20260912123000','20260912137000'))<>5 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice SO Invoice read chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912140000';
  END IF;
  IF to_regprocedure('private.backoffice_sales_order_invoice_summary(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_orders_v3(text,text,text,text,date,date,text,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: SO Invoice status routine collision';
  END IF;
END
$guard$;

CREATE FUNCTION private.backoffice_sales_order_invoice_summary(
  p_company_id uuid,p_sales_order_id uuid
) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  WITH regular AS (
    SELECT COALESCE(sum(line.net_delivered_base_qty),0)::numeric delivered,
      COALESCE(sum(line.to_invoice_base_qty),0)::numeric remaining
    FROM public.backoffice_sales_order_lines line
    WHERE line.company_id=p_company_id AND line.sales_order_id=p_sales_order_id
  ), overage AS (
    SELECT COALESCE(sum(line.accepted_overage_base_qty),0)::numeric delivered,
      COALESCE(sum(line.overage_to_invoice_base_qty),0)::numeric remaining
    FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=p_company_id AND line.sales_order_id=p_sales_order_id
      AND line.requested_resolution='ACCEPT_OVERAGE'
      AND line.commercial_approval_status='APPROVED'
      AND line.warehouse_resolution_status='RESOLVED'
  ), invoice AS (
    SELECT count(*) FILTER(WHERE item.status IN('DRAFT','POSTED'))::integer active_count,
      count(*) FILTER(WHERE item.status='POSTED')::integer posted_count,
      (array_agg(item.id ORDER BY item.created_at DESC,item.id DESC)
        FILTER(WHERE item.status='DRAFT'))[1] draft_id,
      COALESCE(sum(item.delivery_fee_amount) FILTER(
        WHERE item.invoice_type='REGULAR' AND item.status IN('DRAFT','POSTED')),0)::numeric fee_allocated
    FROM public.backoffice_sales_invoices item
    WHERE item.company_id=p_company_id AND item.sales_order_id=p_sales_order_id
  ), fact AS (
    SELECT regular.delivered+overage.delivered delivered,
      regular.remaining+overage.remaining quantity_remaining,
      invoice.active_count,invoice.posted_count,invoice.draft_id,
      CASE WHEN regular.delivered+overage.delivered>0 THEN document.delivery_fee_amount ELSE 0 END fee_basis,
      CASE WHEN regular.delivered+overage.delivered>0
        THEN greatest(0,document.delivery_fee_amount-invoice.fee_allocated) ELSE 0 END fee_remaining
    FROM public.backoffice_sales_orders document
    CROSS JOIN regular CROSS JOIN overage CROSS JOIN invoice
    WHERE document.company_id=p_company_id AND document.id=p_sales_order_id
  ), classified AS (
    SELECT *,CASE
      WHEN draft_id IS NOT NULL THEN 'DRAFT'
      WHEN posted_count>0 AND delivered+fee_basis>0
        AND quantity_remaining+fee_remaining=0 THEN 'INVOICED'
      WHEN posted_count>0 THEN 'PARTIALLY_INVOICED'
      WHEN quantity_remaining+fee_remaining>0 THEN 'READY'
      ELSE 'NOT_READY' END invoice_status
    FROM fact
  )
  SELECT jsonb_build_object('invoiceStatus',invoice_status,
    'draftInvoiceId',draft_id,'activeInvoiceCount',active_count,
    'postedInvoiceCount',posted_count)
  FROM classified
$$;

CREATE FUNCTION public.get_backoffice_sales_orders_v3(
  p_document_kind text DEFAULT NULL,p_fulfillment_status text DEFAULT NULL,
  p_invoice_status text DEFAULT NULL,p_date_basis text DEFAULT 'ORDER_DATE',
  p_date_from date DEFAULT NULL,p_date_to date DEFAULT NULL,
  p_search text DEFAULT NULL,p_limit integer DEFAULT 100
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_kind text:=nullif(upper(btrim(COALESCE(p_document_kind,''))), '');
  v_fulfillment text:=nullif(upper(btrim(COALESCE(p_fulfillment_status,''))), '');
  v_invoice text:=nullif(upper(btrim(COALESCE(p_invoice_status,''))), '');
  v_basis text:=upper(btrim(COALESCE(p_date_basis,'ORDER_DATE')));
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  IF v_kind IS NOT NULL AND v_kind NOT IN('QUOTATION','SALES_ORDER') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_DOCUMENT_KIND_INVALID';
  END IF;
  IF v_fulfillment IS NOT NULL AND v_fulfillment NOT IN('QUOTATION','CONFIRMED',
    'PREPARING','PARTIALLY_SHIPPED','IN_TRANSIT','COMPLETED','CANCELED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FULFILLMENT_STATUS_INVALID';
  END IF;
  IF v_invoice IS NOT NULL AND v_invoice NOT IN(
    'NOT_READY','READY','DRAFT','PARTIALLY_INVOICED','INVOICED') THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_STATUS_INVALID';
  END IF;
  IF v_basis NOT IN('ORDER_DATE','DELIVERY_DATE','DUE_DATE')
    OR (p_date_from IS NOT NULL AND p_date_to IS NOT NULL AND p_date_to<p_date_from)
    OR p_limit IS NULL OR p_limit<1 OR p_limit>500 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FILTER_INVALID';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'data',COALESCE((
    SELECT jsonb_agg(private.backoffice_sales_order_snapshot(v_company,row_data.id)
      ||row_data.invoice_summary
      ORDER BY row_data.sort_date DESC,row_data.updated_at DESC,row_data.id)
    FROM (SELECT document.id,document.updated_at,summary.invoice_summary,
        CASE v_basis WHEN 'DELIVERY_DATE' THEN document.planned_delivery_date
          WHEN 'DUE_DATE' THEN document.due_date ELSE document.order_date END sort_date
      FROM public.backoffice_sales_orders document
      CROSS JOIN LATERAL (SELECT private.backoffice_sales_order_invoice_summary(
        document.company_id,document.id) invoice_summary) summary
      WHERE document.company_id=v_company
        AND (v_kind IS NULL OR (v_kind='QUOTATION' AND document.order_no IS NULL)
          OR (v_kind='SALES_ORDER' AND document.order_no IS NOT NULL))
        AND (v_fulfillment IS NULL OR document.fulfillment_status=v_fulfillment)
        AND (v_invoice IS NULL OR summary.invoice_summary->>'invoiceStatus'=v_invoice)
        AND (p_date_from IS NULL OR CASE v_basis
          WHEN 'DELIVERY_DATE' THEN document.planned_delivery_date
          WHEN 'DUE_DATE' THEN document.due_date ELSE document.order_date END>=p_date_from)
        AND (p_date_to IS NULL OR CASE v_basis
          WHEN 'DELIVERY_DATE' THEN document.planned_delivery_date
          WHEN 'DUE_DATE' THEN document.due_date ELSE document.order_date END<=p_date_to)
        AND (nullif(btrim(COALESCE(p_search,'')),'') IS NULL
          OR document.quotation_no ILIKE '%'||btrim(p_search)||'%'
          OR COALESCE(document.order_no,'') ILIKE '%'||btrim(p_search)||'%'
          OR document.customer_snapshot->>'name' ILIKE '%'||btrim(p_search)||'%'
          OR document.customer_snapshot->>'code' ILIKE '%'||btrim(p_search)||'%')
      ORDER BY sort_date DESC NULLS LAST,document.updated_at DESC,document.id
      LIMIT p_limit) row_data),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION private.backoffice_sales_order_invoice_summary(uuid,uuid),
  public.get_backoffice_sales_orders_v3(text,text,text,text,date,date,text,integer)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.backoffice_sales_order_invoice_summary(uuid,uuid)
FROM authenticated;
GRANT EXECUTE ON FUNCTION private.backoffice_sales_order_invoice_summary(uuid,uuid)
TO service_role;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_orders_v3(
  text,text,text,text,date,date,text,integer) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912140000','backoffice_sales_order_invoice_status',
  'Read-only canonical Invoice lifecycle status and filter on Backoffice SO list; active Draft links directly and posted multi-Invoice history stays scoped to the source SO');
NOTIFY pgrst,'reload schema';
COMMIT;
