-- DEVELOPMENT CANDIDATE ONLY. Loaded inside the rollback-only staging harness.
-- Not a production migration, endpoint, revision writer or posting authority.
-- Source: exported runtime effective_line_amounts and price correction calculator.
CREATE FUNCTION private.backoffice_invoice_revision_amount_preview(
  p_company_id uuid, p_invoice_id uuid, p_expected_version bigint,
  p_expected_price_revision bigint, p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path=pg_catalog,public,pg_temp AS $preview$
DECLARE
  v_invoice public.backoffice_sales_invoices%rowtype;
  v_line public.backoffice_sales_invoice_lines%rowtype;
  v_item jsonb; v_old jsonb; v_new jsonb; v_tax_result jsonb; v_tax_line jsonb;
  v_rows jsonb := '[]'::jsonb; v_seen uuid[] := ARRAY[]::uuid[];
  v_line_id uuid; v_price numeric(24,4); v_discount numeric(24,4);
  v_inclusive numeric(24,4); v_dpp numeric(24,4); v_tax numeric(24,4);
  v_gross_delta numeric(24,4) := 0; v_discount_delta numeric(24,4) := 0;
  v_tax_delta numeric(24,4) := 0; v_net_delta numeric(24,4) := 0;
  v_before numeric(24,4); v_changed integer := 0; v_count integer;
  v_unified_revision_count bigint := 0;
BEGIN
  IF p_company_id IS NULL OR p_invoice_id IS NULL
    OR p_expected_version IS NULL OR p_expected_version<1
    OR p_expected_price_revision IS NULL OR p_expected_price_revision<0
    OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'INVOICE_REVISION_PREVIEW_PAYLOAD_INVALID';
  END IF;
  IF jsonb_array_length(p_lines)<1 OR jsonb_array_length(p_lines)>500 THEN
    RAISE EXCEPTION 'INVOICE_REVISION_PREVIEW_PAYLOAD_INVALID';
  END IF;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=p_company_id AND i.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'POSTED' OR v_invoice.invoice_type<>'REGULAR' THEN
    RAISE EXCEPTION 'POSTED_REGULAR_INVOICE_REQUIRED';
  END IF;
  IF v_invoice.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF to_regclass('private.backoffice_invoice_revisions') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM private.backoffice_invoice_revisions WHERE company_id=$1 AND invoice_id=$2'
      INTO v_unified_revision_count USING p_company_id,p_invoice_id;
  END IF;
  IF (SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections c
    WHERE c.company_id=p_company_id AND c.source_invoice_id=p_invoice_id
      AND c.status='POSTED')+v_unified_revision_count<>p_expected_price_revision THEN
    RAISE EXCEPTION 'INVOICE_PRICE_REVISION_CONFLICT';
  END IF;
  IF v_invoice.return_adjustment_pending_confirmation OR EXISTS(
    SELECT 1 FROM public.backoffice_sales_credit_notes n
    WHERE n.company_id=p_company_id AND n.source_invoice_id=p_invoice_id
      AND n.status IN('DRAFT','POSTED')) THEN
    RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_AFTER_RETURN_NOT_ALLOWED';
  END IF;
  SELECT count(*) INTO v_count FROM public.backoffice_sales_invoice_lines l
    WHERE l.company_id=p_company_id AND l.invoice_id=p_invoice_id
      AND l.line_type='PRODUCT' AND l.source_kind='SALES_ORDER'
      AND l.sales_order_line_id IS NOT NULL;
  IF v_count<>jsonb_array_length(p_lines) THEN
    RAISE EXCEPTION 'INVOICE_REVISION_LINE_SET_MISMATCH';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines) ORDER BY value->>'invoiceLineId' LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'INVOICE_REVISION_LINE_INVALID';
    END IF;
    IF EXISTS(SELECT 1 FROM jsonb_object_keys(v_item) k
        WHERE k NOT IN('invoiceLineId','unitPrice','discountAmount'))
      OR jsonb_typeof(v_item->'invoiceLineId') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_item->'unitPrice') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_item->'discountAmount') IS DISTINCT FROM 'string'
      OR (v_item->>'invoiceLineId') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR (v_item->>'unitPrice') !~ '^(0|[1-9][0-9]{0,19})(\.[0-9]{1,4})?$'
      OR (v_item->>'discountAmount') !~ '^(0|[1-9][0-9]{0,19})(\.[0-9]{1,4})?$' THEN
      RAISE EXCEPTION 'INVOICE_REVISION_LINE_INVALID';
    END IF;
    v_line_id := (v_item->>'invoiceLineId')::uuid;
    IF v_line_id=ANY(v_seen) THEN RAISE EXCEPTION 'INVOICE_REVISION_DUPLICATE_LINE'; END IF;
    v_seen := array_append(v_seen,v_line_id);
    SELECT * INTO v_line FROM public.backoffice_sales_invoice_lines l
      WHERE l.company_id=p_company_id AND l.invoice_id=p_invoice_id
        AND l.id=v_line_id AND l.line_type='PRODUCT' AND l.source_kind='SALES_ORDER'
        AND l.sales_order_line_id IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_LINE_OWNERSHIP_INVALID'; END IF;
    IF v_line.quantity_uom IS NULL OR v_line.quantity_uom<=0 THEN
      RAISE EXCEPTION 'INVOICE_REVISION_SOURCE_QUANTITY_INVALID';
    END IF;
    v_price := (v_item->>'unitPrice')::numeric;
    v_discount := (v_item->>'discountAmount')::numeric;
    v_old := private.backoffice_invoice_effective_line_amounts(p_company_id,v_line_id);
    IF v_old IS NULL OR (v_old->>'enteredUnitPrice') IS NULL
      OR (v_old->>'chargeAmount') IS NULL OR (v_old->>'discountAmount') IS NULL
      OR (v_old->>'lineAmount') IS NULL OR (v_old->>'taxAmount') IS NULL THEN
      RAISE EXCEPTION 'INVOICE_REVISION_EFFECTIVE_SOURCE_INVALID';
    END IF;
    v_inclusive := round(v_line.quantity_uom*v_price-v_discount,4);
    IF v_inclusive<0 THEN RAISE EXCEPTION 'INVOICE_DISCOUNT_EXCEEDS_CORRECTED_LINE_TOTAL'; END IF;
    v_dpp := v_inclusive; v_tax := 0;
    IF COALESCE((v_line.source_snapshot->>'taxApplied')::boolean,false) THEN
      IF (v_line.source_snapshot->>'taxPriceMode') IS DISTINCT FROM 'INCLUSIVE'
        OR NULLIF(v_line.source_snapshot->>'taxRatePercent','') IS NULL
        OR NULLIF(v_line.source_snapshot->>'taxCalculationScope','') IS NULL
        OR NULLIF(v_line.source_snapshot->>'taxAccountId','') IS NULL THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID';
      END IF;
      v_tax_result := private.calculate_tax_group(jsonb_build_array(
        jsonb_build_object('lineKey',v_line.id::text,'amount',v_inclusive)),
        (v_line.source_snapshot->>'taxRatePercent')::numeric,'SALES',
        v_line.source_snapshot->>'taxPriceMode',v_line.source_snapshot->>'taxCalculationScope');
      v_tax_line := v_tax_result->'lines'->0;
      v_dpp := round((v_tax_line->>'taxBase')::numeric,4);
      v_tax := round((v_tax_line->>'taxAmount')::numeric,4);
      IF v_dpp IS NULL OR v_tax IS NULL OR round(v_dpp+v_tax,4)<>v_inclusive THEN
        RAISE EXCEPTION 'INVOICE_REVISION_TAX_ARITHMETIC_INVALID';
      END IF;
    END IF;
    v_new := jsonb_build_object('enteredUnitPrice',v_price,'discountAmount',v_discount,
      'chargeAmount',round(v_dpp+v_discount,4),'lineAmount',v_dpp,'taxAmount',v_tax);
    IF v_price<>(v_old->>'enteredUnitPrice')::numeric
      OR v_discount<>(v_old->>'discountAmount')::numeric THEN v_changed:=v_changed+1; END IF;
    v_gross_delta:=v_gross_delta+(v_new->>'chargeAmount')::numeric-(v_old->>'chargeAmount')::numeric;
    v_discount_delta:=v_discount_delta+v_discount-(v_old->>'discountAmount')::numeric;
    v_tax_delta:=v_tax_delta+v_tax-(v_old->>'taxAmount')::numeric;
    v_net_delta:=v_net_delta+v_dpp+v_tax-(v_old->>'lineAmount')::numeric-(v_old->>'taxAmount')::numeric;
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object('invoiceLineId',v_line_id,
      'salesOrderLineId',v_line.sales_order_line_id,'productId',v_line.product_id,
      'uomId',v_line.uom_id,'quantityUom',v_line.quantity_uom,'quantityBase',v_line.quantity_base,
      'taxAccountId',NULLIF(v_line.source_snapshot->>'taxAccountId','')::uuid,
      'before',v_old,'after',v_new));
  END LOOP;
  IF v_gross_delta-v_discount_delta+v_tax_delta<>v_net_delta THEN
    RAISE EXCEPTION 'INVOICE_REVISION_DELTA_ARITHMETIC_INVALID';
  END IF;
  v_before:=private.backoffice_invoice_effective_total(p_company_id,p_invoice_id,NULL);
  IF v_before IS NULL THEN RAISE EXCEPTION 'INVOICE_REVISION_EFFECTIVE_SOURCE_INVALID'; END IF;
  RETURN jsonb_build_object('calculationOnly',true,'invoiceId',p_invoice_id,
    'masterVersion',v_invoice.master_version,'priceRevision',p_expected_price_revision,
    'changedLines',v_changed,'lines',v_rows,'beforeTotal',v_before,
    'afterTotal',v_before+v_net_delta,'grossRevenueDelta',v_gross_delta,
    'salesDiscountDelta',v_discount_delta,'taxDelta',v_tax_delta,'payableDelta',v_net_delta);
END
$preview$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_revision_amount_preview(uuid,uuid,bigint,bigint,jsonb)
  FROM PUBLIC,anon,authenticated,service_role;

-- KEEP_TERM planning only. Does not move any journal, payment or schedule.
-- Manual installment overrides will be authorized by the final orchestrator.
CREATE FUNCTION private.backoffice_invoice_revision_date_preview(
  p_company_id uuid,p_invoice_id uuid,p_expected_version bigint,p_invoice_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path=pg_catalog,public,pg_temp AS $dates$
DECLARE
  v_invoice public.backoffice_sales_invoices%rowtype;
  v_old_period public.accounting_periods%rowtype;
  v_new_period public.accounting_periods%rowtype;
  v_schedules jsonb;
BEGIN
  IF p_company_id IS NULL OR p_invoice_id IS NULL OR p_expected_version IS NULL
    OR p_expected_version<1 OR p_invoice_date IS NULL OR NOT isfinite(p_invoice_date)
    OR p_invoice_date<date '0001-01-01' OR p_invoice_date>date '9999-12-31' THEN
    RAISE EXCEPTION 'INVOICE_REVISION_DATE_PAYLOAD_INVALID';
  END IF;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=p_company_id AND i.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'POSTED' OR v_invoice.invoice_type<>'REGULAR' THEN
    RAISE EXCEPTION 'POSTED_REGULAR_INVOICE_REQUIRED';
  END IF;
  IF v_invoice.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  SELECT * INTO v_old_period FROM public.accounting_periods p
    WHERE p.company_id=p_company_id AND v_invoice.invoice_date BETWEEN p.start_date AND p.end_date;
  SELECT * INTO v_new_period FROM public.accounting_periods p
    WHERE p.company_id=p_company_id AND p_invoice_date BETWEEN p.start_date AND p.end_date;
  IF p_invoice_date<>v_invoice.invoice_date THEN
    IF v_old_period.id IS NULL OR v_new_period.id IS NULL THEN
      RAISE EXCEPTION 'INVOICE_REVISION_ACCOUNTING_PERIOD_MISSING';
    END IF;
    IF v_old_period.status NOT IN('OPEN','REOPENED') OR v_new_period.status NOT IN('OPEN','REOPENED') THEN
      RAISE EXCEPTION 'INVOICE_REVISION_ACCOUNTING_PERIOD_LOCKED';
    END IF;
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_receivable_schedules s
    WHERE s.company_id=p_company_id AND s.invoice_id=p_invoice_id
      AND (NOT isfinite(s.due_date) OR s.due_date<v_invoice.invoice_date
        OR p_invoice_date+(s.due_date-v_invoice.invoice_date)>date '9999-12-31')) THEN
    RAISE EXCEPTION 'INVOICE_REVISION_SOURCE_TERM_INVALID';
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('scheduleId',s.id,'installmentNo',s.installment_no,
    'previousDueDate',s.due_date,'dueDate',p_invoice_date+(s.due_date-v_invoice.invoice_date),
    'amountDue',s.amount_due,'allocatedPaymentAmount',s.allocated_payment_amount,
    'creditedAmount',s.credited_amount) ORDER BY s.installment_no,s.id),'[]'::jsonb)
    INTO v_schedules FROM public.backoffice_sales_invoice_receivable_schedules s
    WHERE s.company_id=p_company_id AND s.invoice_id=p_invoice_id;
  RETURN jsonb_build_object('calculationOnly',true,'invoiceId',p_invoice_id,
    'previousInvoiceDate',v_invoice.invoice_date,'invoiceDate',p_invoice_date,
    'dateChanged',p_invoice_date<>v_invoice.invoice_date,
    'previousPeriodId',v_old_period.id,'periodId',v_new_period.id,
    'previousPeriodVersion',v_old_period.master_version,'periodVersion',v_new_period.master_version,
    'schedules',v_schedules,'requiresPostingRecheck',true);
END
$dates$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_revision_date_preview(uuid,uuid,bigint,date)
  FROM PUBLIC,anon,authenticated,service_role;
