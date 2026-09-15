-- Step 5/6.3: Odoo-aligned Delivered Not Invoiced current exposure by SO line.
-- Read-only report: no Stock, Reservation, FIFO, Invoice, Payment, Journal or history mutation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912137000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage ledger split 137000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912138000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912138000';
  END IF;
  IF to_regprocedure('private.classify_backoffice_sales_dni(numeric,numeric,numeric)') IS NOT NULL
    OR to_regprocedure('public.get_finance_delivered_not_invoiced(date,integer,integer)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Delivered Not Invoiced routine collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.access_permission_catalog permission
    WHERE permission.permission_key='finance.journals_reports'
      AND permission.is_customizable
      AND ARRAY['VIEW','EXPORT']::text[]<@permission.supported_capabilities) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance report permission contract missing';
  END IF;
END
$guard$;

CREATE FUNCTION private.classify_backoffice_sales_dni(
  p_delivered numeric,p_draft numeric,p_posted numeric
) RETURNS text LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE v_outstanding numeric;v_draft numeric;
BEGIN
  IF p_delivered IS NULL OR p_draft IS NULL OR p_posted IS NULL
    OR p_delivered<0 OR p_draft<0 OR p_posted<0 OR p_posted>p_delivered
    OR p_draft>p_delivered-p_posted THEN
    RAISE EXCEPTION 'DELIVERED_NOT_INVOICED_QUANTITY_INVALID';
  END IF;
  v_outstanding:=p_delivered-p_posted;v_draft:=least(p_draft,v_outstanding);
  IF v_outstanding=0 THEN RETURN 'FULLY_POSTED'; END IF;
  IF v_draft=0 THEN RETURN 'NOT_DRAFTED'; END IF;
  IF v_draft=v_outstanding THEN RETURN 'FULLY_DRAFTED'; END IF;
  RETURN 'PARTIALLY_DRAFTED';
END
$$;

CREATE FUNCTION public.get_finance_delivered_not_invoiced(
  p_as_of date,p_limit integer DEFAULT 200,p_offset integer DEFAULT 0
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_timezone text;v_today date;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF NOT private.g6_report_role_allowed(v_company) THEN
    RAISE EXCEPTION 'FINANCE_REPORT_ROLE_REQUIRED';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.journals_reports','VIEW');
  IF p_as_of IS NULL THEN RAISE EXCEPTION 'REPORT_AS_OF_INVALID'; END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>500 OR p_offset IS NULL OR p_offset<0 THEN
    RAISE EXCEPTION 'REPORT_PAGINATION_INVALID';
  END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_timezone,v_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF p_as_of>v_today THEN RAISE EXCEPTION 'REPORT_AS_OF_FUTURE'; END IF;

  RETURN (WITH
  receipt AS (
    SELECT line.sales_order_line_id,min(header.accepted_date) first_date,
      max(header.accepted_date) last_date,sum(line.received_base_qty)::numeric accepted_qty
    FROM public.backoffice_sales_delivery_receipt_lines line
    JOIN public.backoffice_sales_delivery_receipts header
      ON header.company_id=line.company_id AND header.id=line.receipt_id
    WHERE line.company_id=v_company AND header.accepted_date<=p_as_of
    GROUP BY line.sales_order_line_id
  ),
  posted AS (
    SELECT allocation.source_kind,allocation.sales_order_line_id,allocation.discrepancy_line_id,
      sum(allocation.allocated_base_qty)::numeric quantity
    FROM public.backoffice_sales_invoice_quantity_allocations allocation
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=allocation.company_id
      AND invoice.id=allocation.invoice_id
    WHERE allocation.company_id=v_company AND allocation.status='POSTED'
      AND invoice.status='POSTED'
      AND (invoice.posted_at AT TIME ZONE v_timezone)::date<=p_as_of
    GROUP BY allocation.source_kind,allocation.sales_order_line_id,allocation.discrepancy_line_id
  ),
  draft AS (
    SELECT allocation.source_kind,allocation.sales_order_line_id,allocation.discrepancy_line_id,
      sum(allocation.allocated_base_qty)::numeric quantity,
      string_agg(invoice.draft_no,', ' ORDER BY invoice.invoice_sequence) draft_numbers
    FROM public.backoffice_sales_invoice_quantity_allocations allocation
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=allocation.company_id
      AND invoice.id=allocation.invoice_id
    WHERE allocation.company_id=v_company AND allocation.status='HELD'
      AND invoice.status='DRAFT'
      AND (invoice.created_at AT TIME ZONE v_timezone)::date<=p_as_of
    GROUP BY allocation.source_kind,allocation.sales_order_line_id,allocation.discrepancy_line_id
  ),
  regular_source AS (
    SELECT 'SALES_ORDER'::text source_kind,'QUANTITY'::text measure_kind,
      line.id source_id,line.sales_order_id,
      line.id sales_order_line_id,document.order_no,document.order_date,
      document.customer_snapshot->>'name' customer_name,line.line_no,
      line.product_code_snapshot product_code,line.product_name_snapshot product_name,
      line.uom_code_snapshot uom_code,line.uom_name_snapshot uom_name,
      line.base_qty_per_uom,
      receipt.first_date,receipt.last_date,
      greatest(0,receipt.accepted_qty-least(line.returned_before_invoice_base_qty,receipt.accepted_qty)) delivered_qty,
      COALESCE(posted.quantity,0) posted_qty,COALESCE(draft.quantity,0) draft_qty,draft.draft_numbers,
      CASE WHEN line.ordered_base_qty>0 THEN line.line_total/line.ordered_base_qty ELSE 0 END gross_per_base,
      CASE WHEN line.ordered_base_qty>0 THEN line.tax_amount/line.ordered_base_qty ELSE 0 END tax_per_base
    FROM receipt
    JOIN public.backoffice_sales_order_lines line ON line.company_id=v_company AND line.id=receipt.sales_order_line_id
    JOIN public.backoffice_sales_orders document ON document.company_id=line.company_id AND document.id=line.sales_order_id
    LEFT JOIN posted ON posted.source_kind='SALES_ORDER' AND posted.sales_order_line_id=line.id
      AND posted.discrepancy_line_id IS NULL
    LEFT JOIN draft ON draft.source_kind='SALES_ORDER' AND draft.sales_order_line_id=line.id
      AND draft.discrepancy_line_id IS NULL
  ),
  overage_effect AS (
    SELECT effect.discrepancy_line_id,min((effect.created_at AT TIME ZONE v_timezone)::date) first_date,
      max((effect.created_at AT TIME ZONE v_timezone)::date) last_date
    FROM public.backoffice_sales_discrepancy_stock_effects effect
    WHERE effect.company_id=v_company AND effect.effect_type='OVERAGE_ACCEPTED_SALE'
      AND (effect.created_at AT TIME ZONE v_timezone)::date<=p_as_of
    GROUP BY effect.discrepancy_line_id
  ),
  overage_source AS (
    SELECT 'ACCEPTED_OVERAGE'::text source_kind,'QUANTITY'::text measure_kind,
      discrepancy.id source_id,
      discrepancy.sales_order_id,discrepancy.sales_order_line_id,document.order_no,document.order_date,
      document.customer_snapshot->>'name' customer_name,source.line_no,
      source.product_code_snapshot product_code,source.product_name_snapshot product_name,
      source.uom_code_snapshot uom_code,source.uom_name_snapshot uom_name,
      source.base_qty_per_uom,
      effect.first_date,effect.last_date,discrepancy.accepted_overage_base_qty delivered_qty,
      COALESCE(posted.quantity,0) posted_qty,COALESCE(draft.quantity,0) draft_qty,draft.draft_numbers,
      CASE WHEN discrepancy.accepted_overage_base_qty>0
        THEN discrepancy.approved_line_total/discrepancy.accepted_overage_base_qty ELSE 0 END gross_per_base,
      CASE WHEN discrepancy.accepted_overage_base_qty>0
        THEN discrepancy.approved_tax_amount/discrepancy.accepted_overage_base_qty ELSE 0 END tax_per_base
    FROM overage_effect effect
    JOIN public.backoffice_sales_delivery_discrepancy_lines discrepancy
      ON discrepancy.company_id=v_company AND discrepancy.id=effect.discrepancy_line_id
    JOIN public.backoffice_sales_order_lines source ON source.company_id=discrepancy.company_id
      AND source.id=discrepancy.sales_order_line_id
    JOIN public.backoffice_sales_orders document ON document.company_id=discrepancy.company_id
      AND document.id=discrepancy.sales_order_id
    LEFT JOIN posted ON posted.source_kind='ACCEPTED_OVERAGE'
      AND posted.discrepancy_line_id=discrepancy.id
    LEFT JOIN draft ON draft.source_kind='ACCEPTED_OVERAGE'
      AND draft.discrepancy_line_id=discrepancy.id
    WHERE discrepancy.accepted_overage_base_qty>0
      AND discrepancy.commercial_approval_status='APPROVED'
      AND discrepancy.warehouse_resolution_status='RESOLVED'
  ),
  acceptance AS (
    SELECT event.sales_order_id,min(event.accepted_date) first_date,max(event.accepted_date) last_date
    FROM (
      SELECT header.sales_order_id,header.accepted_date
      FROM public.backoffice_sales_delivery_receipts header
      WHERE header.company_id=v_company AND header.accepted_date<=p_as_of
      UNION ALL
      SELECT discrepancy.sales_order_id,(effect.created_at AT TIME ZONE v_timezone)::date
      FROM public.backoffice_sales_discrepancy_stock_effects effect
      JOIN public.backoffice_sales_delivery_discrepancy_lines discrepancy
        ON discrepancy.company_id=effect.company_id AND discrepancy.id=effect.discrepancy_line_id
      WHERE effect.company_id=v_company AND effect.effect_type='OVERAGE_ACCEPTED_SALE'
        AND (effect.created_at AT TIME ZONE v_timezone)::date<=p_as_of
    ) event GROUP BY event.sales_order_id
  ),
  fee_posted AS (
    SELECT invoice.sales_order_id,sum(invoice.delivery_fee_amount)::numeric amount
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.invoice_type='REGULAR'
      AND invoice.status='POSTED'
      AND (invoice.posted_at AT TIME ZONE v_timezone)::date<=p_as_of
    GROUP BY invoice.sales_order_id
  ),
  fee_draft AS (
    SELECT invoice.sales_order_id,sum(invoice.delivery_fee_amount)::numeric amount,
      string_agg(invoice.draft_no,', ' ORDER BY invoice.invoice_sequence) draft_numbers
    FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.invoice_type='REGULAR'
      AND invoice.status='DRAFT' AND invoice.delivery_fee_amount>0
      AND (invoice.created_at AT TIME ZONE v_timezone)::date<=p_as_of
    GROUP BY invoice.sales_order_id
  ),
  fee_source AS (
    SELECT 'DELIVERY_FEE'::text source_kind,'AMOUNT'::text measure_kind,
      document.id source_id,document.id sales_order_id,NULL::uuid sales_order_line_id,
      document.order_no,document.order_date,document.customer_snapshot->>'name' customer_name,
      2147483647 line_no,'DELIVERY-FEE'::text product_code,'Ongkir'::text product_name,
      NULL::text uom_code,NULL::text uom_name,1::numeric base_qty_per_uom,
      acceptance.first_date,acceptance.last_date,document.delivery_fee_amount delivered_qty,
      COALESCE(fee_posted.amount,0) posted_qty,COALESCE(fee_draft.amount,0) draft_qty,
      fee_draft.draft_numbers,1::numeric gross_per_base,0::numeric tax_per_base
    FROM acceptance
    JOIN public.backoffice_sales_orders document ON document.company_id=v_company
      AND document.id=acceptance.sales_order_id
    LEFT JOIN fee_posted ON fee_posted.sales_order_id=document.id
    LEFT JOIN fee_draft ON fee_draft.sales_order_id=document.id
    WHERE document.delivery_fee_amount>COALESCE(fee_posted.amount,0)
  ),
  combined AS (
    SELECT * FROM regular_source UNION ALL SELECT * FROM overage_source
    UNION ALL SELECT * FROM fee_source
  ),
  outstanding AS (
    SELECT *,greatest(0,delivered_qty-posted_qty) outstanding_qty,
      least(draft_qty,greatest(0,delivered_qty-posted_qty)) held_draft_qty
    FROM combined WHERE delivered_qty>posted_qty
  ),
  shaped AS (
    SELECT *,outstanding_qty-held_draft_qty not_drafted_qty,
      private.classify_backoffice_sales_dni(delivered_qty,held_draft_qty,posted_qty) invoice_status,
      round(outstanding_qty*gross_per_base,4) estimated_total,
      round(outstanding_qty*tax_per_base,4) estimated_tax
    FROM outstanding
  ),
  page AS (SELECT * FROM shaped ORDER BY first_date,order_no,line_no,source_kind,source_id
    LIMIT p_limit OFFSET p_offset)
  SELECT jsonb_build_object(
    'companyId',v_company,'timezone',v_timezone,'asOf',p_as_of,
    'reportVersion','DNI_AS_OF_V1','financialStatementIncluded',false,
    'label','DELIVERED NOT INVOICED','basis','CUSTOMER_ACCEPTED_LESS_POSTED_INVOICE',
    'totalRows',(SELECT count(*) FROM shaped),'limit',p_limit,'offset',p_offset,
    'salesOrderCount',(SELECT count(DISTINCT sales_order_id) FROM shaped),
    'draftLineCount',(SELECT count(*) FROM shaped WHERE held_draft_qty>0),
    'notDraftedLineCount',(SELECT count(*) FROM shaped WHERE not_drafted_qty>0),
    'estimatedUntaxedAmount',COALESCE((SELECT round(sum(estimated_total-estimated_tax),4) FROM shaped),0),
    'estimatedTaxAmount',COALESCE((SELECT round(sum(estimated_tax),4) FROM shaped),0),
    'estimatedTotalAmount',COALESCE((SELECT round(sum(estimated_total),4) FROM shaped),0),
    'rows',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'sourceKind',source_kind,'measureKind',measure_kind,'sourceId',source_id,
      'salesOrderId',sales_order_id,
      'salesOrderLineId',sales_order_line_id,'salesOrderNo',order_no,'orderDate',order_date,
      'customerName',customer_name,'lineNo',line_no,'productCode',product_code,
      'productName',product_name,'uomCode',uom_code,'uomName',uom_name,
      'firstAcceptedDate',first_date,'lastAcceptedDate',last_date,
      'ageDays',p_as_of-first_date,
      'deliveredBaseQty',CASE WHEN measure_kind='QUANTITY' THEN round(delivered_qty,6) END,
      'postedInvoiceBaseQty',CASE WHEN measure_kind='QUANTITY' THEN round(posted_qty,6) END,
      'draftInvoiceBaseQty',CASE WHEN measure_kind='QUANTITY' THEN round(held_draft_qty,6) END,
      'notDraftedBaseQty',CASE WHEN measure_kind='QUANTITY' THEN round(not_drafted_qty,6) END,
      'outstandingBaseQty',CASE WHEN measure_kind='QUANTITY' THEN round(outstanding_qty,6) END,
      'deliveredQty',CASE WHEN measure_kind='QUANTITY' THEN round(delivered_qty/base_qty_per_uom,6) END,
      'postedInvoiceQty',CASE WHEN measure_kind='QUANTITY' THEN round(posted_qty/base_qty_per_uom,6) END,
      'draftInvoiceQty',CASE WHEN measure_kind='QUANTITY' THEN round(held_draft_qty/base_qty_per_uom,6) END,
      'notDraftedQty',CASE WHEN measure_kind='QUANTITY' THEN round(not_drafted_qty/base_qty_per_uom,6) END,
      'outstandingQty',CASE WHEN measure_kind='QUANTITY' THEN round(outstanding_qty/base_qty_per_uom,6) END,
      'invoiceStatus',invoice_status,'draftInvoiceNumbers',draft_numbers,
      'estimatedUntaxedAmount',round(estimated_total-estimated_tax,4),
      'estimatedTaxAmount',estimated_tax,'estimatedTotalAmount',estimated_total)
      ORDER BY first_date,order_no,line_no,source_kind,source_id) FROM page),'[]'::jsonb)
  ));
END
$$;

REVOKE ALL ON FUNCTION private.classify_backoffice_sales_dni(numeric,numeric,numeric)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.classify_backoffice_sales_dni(numeric,numeric,numeric) TO service_role;
REVOKE ALL ON FUNCTION public.get_finance_delivered_not_invoiced(date,integer,integer)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_delivered_not_invoiced(date,integer,integer)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912138000','backoffice_sales_delivered_not_invoiced_report',
  'Step 5/6.3 Odoo-aligned As-of Delivered Not Invoiced report per SO component including delivery fee; Draft stays included, Posted exits; read-only and no Stock/Invoice/Finance mutation');
NOTIFY pgrst,'reload schema';
COMMIT;
