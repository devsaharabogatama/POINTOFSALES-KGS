-- Guarded additive rollout for unified Posted Backoffice Invoice revision.
-- Production execution is user-owned. The agent may execute this only on the authorized staging project.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='120s';
SELECT pg_advisory_xact_lock(hashtextextended('20261006140000:backoffice_invoice_revision',0));
DO $guard$
DECLARE
  required_versions constant text[]:=ARRAY['20260909161000','20260911160000','20260911162000',
    '20260911163000','20260917131000','20260917150000','20260925100000',
    '20260928110000','20260929130000'];
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20261006140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_INSTALLED: 20261006140000';
  END IF;
  IF EXISTS(SELECT 1 FROM unnest(required_versions) required(version)
    WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations installed
      WHERE installed.version=required.version)) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger mismatch';
  END IF;
  IF (SELECT count(*) FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF (SELECT count(*) FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF (SELECT count(*) FROM public.companies
      WHERE id IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
        '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
        '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)
        AND status='ACTIVE')<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: target Company identity';
  END IF;
  IF to_regclass('private.backoffice_invoice_revision_preparations') IS NOT NULL
    OR to_regclass('private.backoffice_invoice_revisions') IS NOT NULL
    OR to_regclass('private.backoffice_invoice_revision_lines') IS NOT NULL
    OR to_regclass('private.backoffice_invoice_revision_settlement_attributions') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_invoice_revision(jsonb)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_invoice_revision_context(uuid)') IS NOT NULL
    OR to_regprocedure('private.backoffice_invoice_effective_total_before_unified_revision(uuid,uuid,date)') IS NOT NULL
    OR to_regprocedure('private.backoffice_invoice_effective_entered_unit_price_before_unified_revision(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.backoffice_invoice_effective_line_amounts_before_unified_revision(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: object collision';
  END IF;
  IF md5(pg_get_functiondef('private.backoffice_invoice_effective_total(uuid,uuid,date)'::regprocedure))<>'0a64be9b35ac9fba3db3abcd9ab38fad'
    OR md5(pg_get_functiondef('private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)'::regprocedure))<>'2b9cc8a191cb110e5dc31410a6896e40'
    OR md5(pg_get_functiondef('private.backoffice_invoice_effective_line_amounts(uuid,uuid)'::regprocedure))<>'82f8ce5bb1b4edf39a53cbe5f191666c'
    OR md5(pg_get_functiondef('public.get_backoffice_sales_invoice_ui(uuid)'::regprocedure))<>'835f1723cc9b19db2675f40276ef5cff'
    OR md5(pg_get_functiondef('public.get_backoffice_sales_invoice_payment_context(uuid)'::regprocedure))<>'b8145d8ca6de47227d8a740281fe5238'
    OR md5(pg_get_functiondef('public.get_finance_ar_aging(date,uuid,uuid)'::regprocedure))<>'5b5f98c00338a5aea20ca70d2a783060'
    OR md5(pg_get_functiondef('public.get_finance_customer_statement(uuid,date,date,uuid)'::regprocedure))<>'202555b9f00a53e8fd4f05bc9e77bcc8'
    OR md5(pg_get_functiondef('public.export_sales_documents(date,date)'::regprocedure))<>'66d00e34c458d0ff6dc9fd24374743a2'
    OR md5(pg_get_functiondef('private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'::regprocedure))<>'70ea76646c02618553ab2bc752ae1b33'
    OR md5(pg_get_functiondef('private.post_backoffice_sales_credit_note_before_retained(uuid,bigint,uuid)'::regprocedure))<>'a2d1fbd923bc91bbac81cb482198d46b' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Invoice/Finance runtime drift';
  END IF;
END
$guard$;

-- BEGIN supabase/staging/backoffice_invoice_revision_amount_preview.sql
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
-- END supabase/staging/backoffice_invoice_revision_amount_preview.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_preparation.sql
-- STAGING DEVELOPMENT CANDIDATE, not a migration or a posting endpoint.
-- Preparation has NO effective Invoice, settlement, revision-counter or GL effect.
CREATE TABLE private.backoffice_invoice_revision_preparations (
  company_id uuid NOT NULL REFERENCES public.companies(id),
  operation_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  request_snapshot jsonb NOT NULL CHECK(jsonb_typeof(request_snapshot)='object'),
  source_snapshot jsonb NOT NULL CHECK(jsonb_typeof(source_snapshot)='object'),
  response_snapshot jsonb NOT NULL CHECK(jsonb_typeof(response_snapshot)='object'
    AND (response_snapshot->>'status') IS NOT DISTINCT FROM 'PREPARED_NOT_POSTED'),
  PRIMARY KEY(company_id,operation_id),
  FOREIGN KEY(company_id,invoice_id) REFERENCES public.backoffice_sales_invoices(company_id,id)
);
ALTER TABLE private.backoffice_invoice_revision_preparations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.backoffice_invoice_revision_preparations FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.guard_backoffice_invoice_revision_preparation()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $guard$
BEGIN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_IMMUTABLE'; END
$guard$;
REVOKE ALL ON FUNCTION private.guard_backoffice_invoice_revision_preparation() FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER invoice_revision_preparation_immutable BEFORE UPDATE OR DELETE
  ON private.backoffice_invoice_revision_preparations FOR EACH ROW
  EXECUTE FUNCTION private.guard_backoffice_invoice_revision_preparation();
CREATE TRIGGER invoice_revision_preparation_no_truncate BEFORE TRUNCATE
  ON private.backoffice_invoice_revision_preparations FOR EACH STATEMENT
  EXECUTE FUNCTION private.guard_backoffice_invoice_revision_preparation();

CREATE FUNCTION private.backoffice_invoice_revision_source_snapshot(
  p_company_id uuid,p_invoice_id uuid,p_customer_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path=pg_catalog,public,pg_temp AS $snapshot$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;v_customer jsonb;v_revisions jsonb:='[]'::jsonb;
BEGIN
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=p_company_id AND i.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  SELECT to_jsonb(c) INTO v_customer FROM public.customers c
    WHERE c.company_id=p_company_id AND c.id=p_customer_id AND c.is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_CUSTOMER_INVALID'; END IF;
  IF to_regclass('private.backoffice_invoice_revisions') IS NOT NULL THEN
    EXECUTE 'SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.revision_no),''[]''::jsonb)
      FROM private.backoffice_invoice_revisions r WHERE r.company_id=$1 AND r.invoice_id=$2'
      INTO v_revisions USING p_company_id,p_invoice_id;
  END IF;
  RETURN jsonb_build_object('invoice',to_jsonb(v_invoice),'billingCustomer',v_customer,
    'unifiedRevisions',v_revisions,
    'lines',COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id)
      FROM public.backoffice_sales_invoice_lines l WHERE l.company_id=p_company_id AND l.invoice_id=p_invoice_id),'[]'::jsonb),
    'schedules',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.id)
      FROM public.backoffice_sales_invoice_receivable_schedules s WHERE s.company_id=p_company_id AND s.invoice_id=p_invoice_id),'[]'::jsonb),
    'priceCorrections',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id)
      FROM public.backoffice_sales_invoice_price_corrections c WHERE c.company_id=p_company_id AND c.source_invoice_id=p_invoice_id),'[]'::jsonb),
    'creditNotes',COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.id)
      FROM public.backoffice_sales_credit_notes c WHERE c.company_id=p_company_id AND c.source_invoice_id=p_invoice_id),'[]'::jsonb),
    'receipts',COALESCE((SELECT jsonb_agg(jsonb_build_object('document',to_jsonb(r),
      'targetAllocations',(SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id AND a.invoice_id=p_invoice_id),
      'otherBackofficeAllocations',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id AND a.invoice_id<>p_invoice_id),'[]'::jsonb),
      'retailAllocations',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.customer_receipt_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id),'[]'::jsonb)) ORDER BY r.id)
      FROM public.customer_receipt_documents r WHERE r.company_id=p_company_id AND EXISTS(
        SELECT 1 FROM public.customer_receipt_backoffice_invoice_allocations a
        WHERE a.company_id=p_company_id AND a.document_id=r.id AND a.invoice_id=p_invoice_id)),'[]'::jsonb),
    'downPayments',COALESCE((SELECT jsonb_agg(jsonb_build_object('invoice',to_jsonb(dp),
      'applications',COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
        FROM public.backoffice_sales_down_payment_applications a
        WHERE a.company_id=p_company_id AND a.down_payment_invoice_id=dp.id),'[]'::jsonb),
      'taxBreakdowns',COALESCE((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.id)
        FROM public.backoffice_sales_down_payment_application_tax_breakdowns t
        WHERE t.company_id=p_company_id AND t.down_payment_invoice_id=dp.id),'[]'::jsonb)) ORDER BY dp.id)
      FROM public.backoffice_sales_invoices dp WHERE dp.company_id=p_company_id AND EXISTS(
        SELECT 1 FROM public.backoffice_sales_down_payment_applications a
        WHERE a.company_id=p_company_id AND a.regular_invoice_id=p_invoice_id AND a.down_payment_invoice_id=dp.id)),'[]'::jsonb));
END
$snapshot$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_revision_source_snapshot(uuid,uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.prepare_backoffice_invoice_revision(p_command jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $prepare$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice_id uuid;v_operation uuid;v_customer uuid;v_date date;v_version bigint;v_revision bigint;
  v_payload jsonb;v_source jsonb;v_response jsonb;v_amounts jsonb;v_dates jsonb;v_lines jsonb;
  v_existing private.backoffice_invoice_revision_preparations%rowtype;v_notes text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL OR v_company NOT IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
    '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMPANY_NOT_ENABLED';
  END IF;
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','EDIT_DRAFT');
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  IF jsonb_typeof(p_command) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_command) k WHERE k NOT IN(
      'kind','invoiceId','operationId','masterVersion','revision','notes','customerId','invoiceDate','dueDate','lines'))
    OR p_command->>'kind' IS DISTINCT FROM 'INVOICE_REVISION'
    OR jsonb_typeof(p_command->'invoiceId') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'operationId') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'customerId') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'invoiceDate') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_command->'masterVersion') IS DISTINCT FROM 'number'
    OR jsonb_typeof(p_command->'revision') IS DISTINCT FROM 'number'
    OR p_command->>'invoiceId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR p_command->>'operationId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR p_command->>'customerId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    OR p_command->>'masterVersion' !~ '^[1-9][0-9]*$' OR p_command->>'revision' !~ '^(0|[1-9][0-9]*)$'
    OR p_command->>'invoiceDate' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    OR jsonb_typeof(p_command->'lines') IS DISTINCT FROM 'array'
    OR COALESCE(jsonb_typeof(p_command->'notes'),'null') NOT IN('string','null') THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID';
  END IF;
  -- Unsupported paths stay closed until the unified posting orchestrator exists.
  IF p_command->'dueDate' IS DISTINCT FROM '{"mode":"KEEP_TERM"}'::jsonb THEN
    RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_KEEP_TERM_REQUIRED';
  END IF;
  BEGIN
    v_invoice_id:=(p_command->>'invoiceId')::uuid;v_operation:=(p_command->>'operationId')::uuid;
    v_customer:=(p_command->>'customerId')::uuid;v_date:=(p_command->>'invoiceDate')::date;
    v_version:=(p_command->>'masterVersion')::bigint;v_revision:=(p_command->>'revision')::bigint;
  EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow OR numeric_value_out_of_range THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END;
  IF '00000000-0000-0000-0000-000000000000'::uuid IN(v_invoice_id,v_operation,v_customer)
    OR v_version>9007199254740991 OR v_revision>9007199254740991 THEN
    RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID';
  END IF;
  IF length(p_command->>'notes')>1000 THEN RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END IF;
  v_notes:=NULLIF(btrim(p_command->>'notes'),'');
  -- Validate raw lines BEFORE normalizing so extra/immutable fields cannot disappear.
  -- The replay path below must reject malformed payloads too.
  IF jsonb_array_length(p_command->'lines') NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'INVOICE_REVISION_COMMAND_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_command->'lines') l
      WHERE jsonb_typeof(l) IS DISTINCT FROM 'object') THEN RAISE EXCEPTION 'INVOICE_REVISION_LINE_INVALID'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_command->'lines') l
    WHERE EXISTS(SELECT 1 FROM jsonb_object_keys(l) k WHERE k NOT IN('invoiceLineId','unitPrice','discountAmount'))
      OR jsonb_typeof(l->'invoiceLineId') IS DISTINCT FROM 'string'
      OR l->>'invoiceLineId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR jsonb_typeof(l->'unitPrice') IS DISTINCT FROM 'string'
      OR jsonb_typeof(l->'discountAmount') IS DISTINCT FROM 'string'
      OR l->>'unitPrice' !~ '^(0|[1-9][0-9]{0,19})(\.[0-9]{1,4})?$'
      OR l->>'discountAmount' !~ '^(0|[1-9][0-9]{0,19})(\.[0-9]{1,4})?$') THEN
    RAISE EXCEPTION 'INVOICE_REVISION_LINE_INVALID'; END IF;
  SELECT jsonb_agg(jsonb_build_object('invoiceLineId',(l->>'invoiceLineId')::uuid,
    'unitPrice',((l->>'unitPrice')::numeric(24,4))::text,
    'discountAmount',((l->>'discountAmount')::numeric(24,4))::text) ORDER BY (l->>'invoiceLineId')::uuid)
    INTO v_lines FROM jsonb_array_elements(p_command->'lines') l;
  v_payload:=jsonb_build_object('kind','INVOICE_REVISION','invoiceId',v_invoice_id,
    'masterVersion',v_version,'revision',v_revision,'customerId',v_customer,
    'invoiceDate',v_date,'dueDate',p_command->'dueDate','notes',v_notes,'lines',v_lines);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company||':INVOICE_REVISION_PREPARE:'||v_operation,0));
  SELECT * INTO v_existing FROM private.backoffice_invoice_revision_preparations
    WHERE company_id=v_company AND operation_id=v_operation;
  IF FOUND THEN
    IF v_existing.request_snapshot IS DISTINCT FROM v_payload THEN RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT'; END IF;
    RETURN v_existing.response_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  PERFORM 1 FROM public.backoffice_sales_invoices WHERE company_id=v_company AND id=v_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  v_source:=private.backoffice_invoice_revision_source_snapshot(v_company,v_invoice_id,v_customer);
  v_amounts:=private.backoffice_invoice_revision_amount_preview(v_company,v_invoice_id,v_version,v_revision,v_lines);
  v_dates:=private.backoffice_invoice_revision_date_preview(v_company,v_invoice_id,v_version,v_date);
  v_response:=jsonb_build_object('status','PREPARED_NOT_POSTED','operationId',v_operation,
    'invoiceId',v_invoice_id,'exactRetry',false,'amounts',v_amounts,'dates',v_dates,
    'sourceFingerprint',md5(v_source::text),'requiresPostingRecheck',true);
  INSERT INTO private.backoffice_invoice_revision_preparations(company_id,operation_id,invoice_id,
    actor_id,request_snapshot,source_snapshot,response_snapshot)
    VALUES(v_company,v_operation,v_invoice_id,v_actor,v_payload,v_source,v_response);
  RETURN v_response;
END
$prepare$;
REVOKE ALL ON FUNCTION private.prepare_backoffice_invoice_revision(jsonb) FROM PUBLIC,anon,authenticated,service_role;

-- Full snapshot equality, not a checksum-based permission or concurrency token.
CREATE FUNCTION private.assert_backoffice_invoice_revision_preparation_fresh(p_operation_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $fresh$
DECLARE v_company uuid:=public.private_active_company_id();v_row private.backoffice_invoice_revision_preparations%rowtype;v_dates jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','EDIT_DRAFT');
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  SELECT * INTO v_row FROM private.backoffice_invoice_revision_preparations
    WHERE company_id=v_company AND operation_id=p_operation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_NOT_FOUND'; END IF;
  IF private.backoffice_invoice_revision_source_snapshot(v_company,v_row.invoice_id,
      (v_row.request_snapshot->>'customerId')::uuid) IS DISTINCT FROM v_row.source_snapshot THEN
    RAISE EXCEPTION 'INVOICE_REVISION_DEPENDENCIES_CHANGED';
  END IF;
  v_dates:=private.backoffice_invoice_revision_date_preview(v_company,v_row.invoice_id,
    (v_row.request_snapshot->>'masterVersion')::bigint,(v_row.request_snapshot->>'invoiceDate')::date);
  IF v_dates IS DISTINCT FROM v_row.response_snapshot->'dates' THEN
    RAISE EXCEPTION 'INVOICE_REVISION_DEPENDENCIES_CHANGED';
  END IF;
END
$fresh$;
REVOKE ALL ON FUNCTION private.assert_backoffice_invoice_revision_preparation_fresh(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
-- END supabase/staging/backoffice_invoice_revision_preparation.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_execution_plan.sql
-- STAGING DEVELOPMENT CANDIDATE. This routine locks and revalidates the exact
-- dependencies needed by a future writer, but deliberately performs no write.
CREATE FUNCTION private.plan_backoffice_invoice_revision_execution(p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $plan$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_preparation private.backoffice_invoice_revision_preparations%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;v_customer uuid;v_date date;
  v_old_period public.accounting_periods%rowtype;v_new_period public.accounting_periods%rowtype;
  v_receipts jsonb;v_dp jsonb;v_journal jsonb;v_receipt_id uuid;v_dp_id uuid;
  v_posted_receipt numeric(24,4);v_advance numeric(24,4);v_draft_receipt numeric(24,4);
  v_dp_total numeric(24,4);v_source_journal uuid;
  v_missing_receipt_period bigint;v_missing_receipt_accounts bigint;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'INVOICE_REVISION_OPERATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','EDIT_DRAFT');
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  SELECT * INTO v_preparation FROM private.backoffice_invoice_revision_preparations p
    WHERE p.company_id=v_company AND p.operation_id=p_operation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_NOT_FOUND'; END IF;
  IF v_preparation.actor_id<>v_actor THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_ACTOR_MISMATCH'; END IF;
  v_customer:=(v_preparation.request_snapshot->>'customerId')::uuid;
  v_date:=(v_preparation.request_snapshot->>'invoiceDate')::date;

  -- Canonical Receipt writers lock Receipt before Invoice. Match that order and
  -- sort IDs so multiple shared documents cannot invert each other.
  FOR v_receipt_id IN
    SELECT DISTINCT a.document_id
    FROM public.customer_receipt_backoffice_invoice_allocations a
    WHERE a.company_id=v_company AND a.invoice_id=v_preparation.invoice_id
    ORDER BY a.document_id
  LOOP
    PERFORM 1 FROM public.customer_receipt_documents r
      WHERE r.company_id=v_company AND r.id=v_receipt_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_RECEIPT_DEPENDENCY_MISSING'; END IF;
  END LOOP;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=v_company AND i.id=v_preparation.invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  FOR v_dp_id IN
    SELECT DISTINCT a.down_payment_invoice_id
    FROM public.backoffice_sales_down_payment_applications a
    WHERE a.company_id=v_company AND a.regular_invoice_id=v_invoice.id
    ORDER BY a.down_payment_invoice_id
  LOOP
    PERFORM 1 FROM public.backoffice_sales_invoices i
      WHERE i.company_id=v_company AND i.id=v_dp_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_DP_DEPENDENCY_MISSING'; END IF;
  END LOOP;
  SELECT * INTO v_old_period FROM public.accounting_periods p
    WHERE p.company_id=v_company AND v_invoice.invoice_date BETWEEN p.start_date AND p.end_date
    ORDER BY p.start_date DESC,p.id LIMIT 1 FOR UPDATE;
  SELECT * INTO v_new_period FROM public.accounting_periods p
    WHERE p.company_id=v_company AND v_date BETWEEN p.start_date AND p.end_date
    ORDER BY p.start_date DESC,p.id LIMIT 1 FOR UPDATE;
  IF v_old_period.id IS NULL OR v_new_period.id IS NULL
    OR v_old_period.status NOT IN('OPEN','REOPENED') OR v_new_period.status NOT IN('OPEN','REOPENED') THEN
    RAISE EXCEPTION 'INVOICE_REVISION_ACCOUNTING_PERIOD_LOCKED';
  END IF;
  PERFORM private.assert_backoffice_invoice_revision_preparation_fresh(p_operation_id);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'receiptId',r.id,'receiptNo',r.receipt_no,'status',r.status,
      'receiptCustomerId',r.customer_id,'receiptDate',r.receipt_date,
      'allocationId',a.id,'allocatedAmount',a.allocated_amount,
      'fromCustomerId',v_invoice.customer_id,'toCustomerId',v_customer,
      'action',CASE WHEN r.status='DRAFT' THEN 'REWRITE_DRAFT_TARGET_SHARE'
        WHEN r.status='POSTED' AND r.receipt_date<v_date THEN 'TRANSFER_TO_ADVANCE_THEN_APPLY'
        WHEN r.status='POSTED' THEN 'TRANSFER_POSTED_AR_ATTRIBUTION'
        ELSE 'NO_EFFECT_CANCELED' END,
      'otherBackofficeAllocationCount',(SELECT count(*) FROM public.customer_receipt_backoffice_invoice_allocations x
        WHERE x.company_id=v_company AND x.document_id=r.id AND x.invoice_id<>v_invoice.id),
      'retailAllocationCount',(SELECT count(*) FROM public.customer_receipt_allocations x
        WHERE x.company_id=v_company AND x.document_id=r.id)) ORDER BY r.id),'[]'::jsonb),
    round(COALESCE(sum(a.allocated_amount) FILTER(WHERE r.status='POSTED'),0),4),
    round(COALESCE(sum(a.allocated_amount) FILTER(WHERE r.status='POSTED' AND r.receipt_date<v_date),0),4),
    round(COALESCE(sum(a.allocated_amount) FILTER(WHERE r.status='DRAFT'),0),4)
  INTO v_receipts,v_posted_receipt,v_advance,v_draft_receipt
  FROM public.customer_receipt_backoffice_invoice_allocations a
  JOIN public.customer_receipt_documents r ON r.company_id=a.company_id AND r.id=a.document_id
  WHERE a.company_id=v_company AND a.invoice_id=v_invoice.id;

  SELECT count(*) FILTER(WHERE period.id IS NULL OR period.status NOT IN('OPEN','REOPENED')),
    count(*) FILTER(WHERE r.receivable_account_id_snapshot IS NULL
      OR private.resolve_financial_event_account(event,'CUSTOMER_ADVANCE_LIABILITY') IS NULL)
  INTO v_missing_receipt_period,v_missing_receipt_accounts
  FROM public.customer_receipt_backoffice_invoice_allocations a
  JOIN public.customer_receipt_documents r ON r.company_id=a.company_id AND r.id=a.document_id
    AND r.status='POSTED' AND r.receipt_date<v_date
  JOIN public.financial_events event ON event.company_id=v_invoice.company_id
    AND event.id=v_invoice.financial_event_id
  LEFT JOIN public.accounting_periods period ON period.company_id=r.company_id
    AND r.receipt_date BETWEEN period.start_date AND period.end_date
  WHERE a.company_id=v_company AND a.invoice_id=v_invoice.id;
  IF v_missing_receipt_period<>0 THEN
    RAISE EXCEPTION 'INVOICE_REVISION_RECEIPT_PERIOD_LOCKED';
  END IF;
  IF v_missing_receipt_accounts<>0 THEN
    RAISE EXCEPTION 'INVOICE_REVISION_RECEIPT_ADVANCE_MAPPING_REQUIRED';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('applicationId',a.id,
      'downPaymentInvoiceId',a.down_payment_invoice_id,'status',a.status,
      'appliedAmount',a.applied_amount,'fromCustomerId',dp.customer_id,
      'toCustomerId',v_customer,'action',CASE WHEN a.status='POSTED'
        THEN 'TRANSFER_POSTED_DP_ATTRIBUTION' ELSE 'RECHECK_NONPOSTED_DP' END) ORDER BY a.id),'[]'::jsonb),
    round(COALESCE(sum(a.applied_amount) FILTER(WHERE a.status='POSTED'),0),4)
  INTO v_dp,v_dp_total
  FROM public.backoffice_sales_down_payment_applications a
  JOIN public.backoffice_sales_invoices dp ON dp.company_id=a.company_id AND dp.id=a.down_payment_invoice_id
  WHERE a.company_id=v_company AND a.regular_invoice_id=v_invoice.id;

  SELECT j.id INTO v_source_journal FROM public.finance_journals j
    WHERE j.company_id=v_company AND j.financial_event_id=v_invoice.financial_event_id
      AND j.status='POSTED' ORDER BY j.id LIMIT 1;
  IF v_source_journal IS NULL THEN RAISE EXCEPTION 'INVOICE_REVISION_SOURCE_JOURNAL_REQUIRED'; END IF;
  SELECT jsonb_build_object('sourceJournalId',j.id,'sourceJournalNo',j.journal_no,
      'sourceAccountingDate',j.accounting_date,'sourcePeriodId',j.accounting_period_id,
      'replacementAccountingDate',v_date,'replacementPeriodId',v_new_period.id,
      'requiresRelocation',j.accounting_date<>v_date OR v_invoice.customer_id<>v_customer,
      'lineCount',(SELECT count(*) FROM public.finance_journal_lines l
        WHERE l.company_id=v_company AND l.journal_id=j.id),
      'totalDebit',j.total_debit,'totalCredit',j.total_credit)
    INTO v_journal FROM public.finance_journals j
    WHERE j.company_id=v_company AND j.id=v_source_journal;
  IF (v_journal->>'lineCount')::integer<2
    OR (v_journal->>'totalDebit')::numeric<>(v_journal->>'totalCredit')::numeric THEN
    RAISE EXCEPTION 'INVOICE_REVISION_SOURCE_JOURNAL_INVALID';
  END IF;
  RETURN jsonb_build_object('status','EXECUTION_PLAN_NOT_POSTED','operationId',p_operation_id,
    'invoiceId',v_invoice.id,'fromCustomerId',v_invoice.customer_id,'toCustomerId',v_customer,
    'fromInvoiceDate',v_invoice.invoice_date,'toInvoiceDate',v_date,
    'amounts',v_preparation.response_snapshot->'amounts','dates',v_preparation.response_snapshot->'dates',
    'receipts',v_receipts,'postedReceiptAmount',v_posted_receipt,
    'receiptAdvanceAmount',v_advance,'draftReceiptAmount',v_draft_receipt,
    'downPayments',v_dp,'postedDownPaymentAmount',v_dp_total,'journal',v_journal,
    'stockEffect',false,'fifoEffect',false,'salesOrderEffect',false,'deliveryEffect',false,
    'requiresAtomicWriter',true);
END
$plan$;
REVOKE ALL ON FUNCTION private.plan_backoffice_invoice_revision_execution(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
-- END supabase/staging/backoffice_invoice_revision_execution_plan.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_journal_plan.sql
-- STAGING DEVELOPMENT CANDIDATE. Produces exact balanced journal legs only;
-- no Finance Event, Journal, revision, settlement or source document is written.
CREATE FUNCTION private.plan_backoffice_invoice_revision_journals(p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $journal_plan$
DECLARE
  v_company uuid:=public.private_active_company_id();v_execution jsonb;
  v_preparation private.backoffice_invoice_revision_preparations%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;v_event public.financial_events%rowtype;
  v_source_journal public.finance_journals%rowtype;v_new_customer uuid;v_new_date date;
  v_ar uuid;v_advance uuid;v_reversal jsonb;v_replacement jsonb;
  v_receipt_legs jsonb:='[]'::jsonb;v_dp_legs jsonb:='[]'::jsonb;
  v_amount_legs jsonb:='[]'::jsonb;v_item jsonb;v_amount numeric(24,4);
  v_debit numeric(24,4);v_credit numeric(24,4);v_group record;
  v_paid numeric(24,4);v_credited numeric(24,4);v_before_total numeric(24,4);
  v_after_total numeric(24,4);v_prior_net numeric(24,4);v_after_net numeric(24,4);
  v_ar_delta numeric(24,4);v_refund_delta numeric(24,4);v_refund uuid;
  v_current_customer uuid;v_current_date date;v_current_identity jsonb;
BEGIN
  v_execution:=private.plan_backoffice_invoice_revision_execution(p_operation_id);
  SELECT * INTO STRICT v_preparation FROM private.backoffice_invoice_revision_preparations p
    WHERE p.company_id=v_company AND p.operation_id=p_operation_id;
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices i
    WHERE i.company_id=v_company AND i.id=v_preparation.invoice_id;
  SELECT * INTO STRICT v_event FROM public.financial_events e
    WHERE e.company_id=v_company AND e.id=v_invoice.financial_event_id;
  SELECT * INTO STRICT v_source_journal FROM public.finance_journals j
    WHERE j.company_id=v_company AND j.id=(v_execution->'journal'->>'sourceJournalId')::uuid;
  v_new_customer:=(v_execution->>'toCustomerId')::uuid;
  v_new_date:=(v_execution->>'toInvoiceDate')::date;
  v_current_customer:=v_invoice.customer_id;v_current_date:=v_invoice.invoice_date;
  IF to_regprocedure('private.backoffice_invoice_effective_identity(uuid,uuid,date)') IS NOT NULL THEN
    EXECUTE 'SELECT private.backoffice_invoice_effective_identity($1,$2,NULL)'
      INTO v_current_identity USING v_company,v_invoice.id;
    v_current_customer:=(v_current_identity->>'customerId')::uuid;
    v_current_date:=(v_current_identity->>'invoiceDate')::date;
  END IF;
  v_ar:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
  v_advance:=private.resolve_financial_event_account(v_event,'CUSTOMER_ADVANCE_LIABILITY');
  SELECT round(COALESCE(sum(a.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations a
  JOIN public.customer_receipt_documents r ON r.company_id=a.company_id AND r.id=a.document_id
    AND r.status='POSTED'
  WHERE a.company_id=v_company AND a.invoice_id=v_invoice.id;
  SELECT round(COALESCE(sum(n.ar_reduction_amount),0),4) INTO v_credited
  FROM public.backoffice_sales_credit_notes n
  WHERE n.company_id=v_company AND n.source_invoice_id=v_invoice.id AND n.status='POSTED';
  v_before_total:=(v_execution->'amounts'->>'beforeTotal')::numeric;
  v_after_total:=(v_execution->'amounts'->>'afterTotal')::numeric;
  v_prior_net:=v_before_total-v_paid-v_credited;v_after_net:=v_after_total-v_paid-v_credited;
  v_ar_delta:=greatest(v_after_net,0)-greatest(v_prior_net,0);
  v_refund_delta:=greatest(-v_after_net,0)-greatest(-v_prior_net,0);
  IF round(v_ar_delta-v_refund_delta,4)<>(v_execution->'amounts'->>'payableDelta')::numeric THEN
    RAISE EXCEPTION 'INVOICE_REVISION_SETTLEMENT_SPLIT_INVALID';
  END IF;

  IF v_current_customer<>v_new_customer OR v_current_date<>v_new_date THEN
   SELECT COALESCE(jsonb_agg(jsonb_build_object('lineNo',l.line_no,'accountId',l.account_id,
      'debit',l.credit,'credit',l.debit,'customerId',l.customer_id,
      'storeId',l.store_id,'warehouseId',l.warehouse_id,
      'description',COALESCE(l.description,'')||' [INVOICE REVISION REVERSAL]') ORDER BY l.line_no),'[]'::jsonb)
  INTO v_reversal FROM public.finance_journal_lines l
  WHERE l.company_id=v_company AND l.journal_id=v_source_journal.id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('lineNo',l.line_no,'accountId',l.account_id,
      'debit',l.debit,'credit',l.credit,
      'customerId',CASE WHEN l.customer_id IS NULL THEN NULL ELSE v_new_customer END,
      'storeId',l.store_id,'warehouseId',l.warehouse_id,
      'description',COALESCE(l.description,'')||' [INVOICE REVISION REPLACEMENT]') ORDER BY l.line_no),'[]'::jsonb)
  INTO v_replacement FROM public.finance_journal_lines l
  WHERE l.company_id=v_company AND l.journal_id=v_source_journal.id;
  ELSE
   v_reversal:='[]'::jsonb;v_replacement:='[]'::jsonb;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_execution->'receipts') ORDER BY value->>'receiptId' LOOP
    IF v_item->>'action'='TRANSFER_TO_ADVANCE_THEN_APPLY'
      AND (v_current_customer<>v_new_customer OR v_current_date<>v_new_date) THEN
      v_amount:=(v_item->>'allocatedAmount')::numeric;
      v_receipt_legs:=v_receipt_legs||jsonb_build_array(
        jsonb_build_object('leg','RECEIPT_TO_ADVANCE','accountingDate',v_item->>'receiptDate',
          'sourceId',v_item->>'allocationId','lines',jsonb_build_array(
            jsonb_build_object('accountId',v_ar,'debit',v_amount,'credit',0,
              'customerId',v_current_customer,'description','Batalkan pelunasan Piutang sebelum tanggal Invoice revisi'),
            jsonb_build_object('accountId',v_advance,'debit',0,'credit',v_amount,
              'customerId',v_new_customer,'description','Pembayaran menjadi Uang Muka Customer'))),
        jsonb_build_object('leg','ADVANCE_TO_REVISED_INVOICE','accountingDate',v_new_date,
          'sourceId',v_item->>'allocationId','lines',jsonb_build_array(
            jsonb_build_object('accountId',v_advance,'debit',v_amount,'credit',0,
              'customerId',v_new_customer,'description','Aplikasi Uang Muka pada Invoice revisi'),
            jsonb_build_object('accountId',v_ar,'debit',0,'credit',v_amount,
              'customerId',v_new_customer,'description','Pelunasan Piutang Invoice revisi'))));
    ELSIF v_item->>'action'='TRANSFER_POSTED_AR_ATTRIBUTION' AND v_current_customer<>v_new_customer THEN
      v_amount:=(v_item->>'allocatedAmount')::numeric;
      v_receipt_legs:=v_receipt_legs||jsonb_build_array(jsonb_build_object(
        'leg','TRANSFER_POSTED_AR_ATTRIBUTION','accountingDate',v_item->>'receiptDate',
        'sourceId',v_item->>'allocationId','lines',jsonb_build_array(
          jsonb_build_object('accountId',v_ar,'debit',v_amount,'credit',0,
            'customerId',v_current_customer,'description','Pindahkan pelunasan dari customer lama'),
          jsonb_build_object('accountId',v_ar,'debit',0,'credit',v_amount,
            'customerId',v_new_customer,'description','Pindahkan pelunasan ke customer Invoice'))));
    END IF;
  END LOOP;
  FOR v_item IN SELECT value FROM jsonb_array_elements(v_execution->'downPayments') ORDER BY value->>'applicationId' LOOP
    IF v_item->>'action'='TRANSFER_POSTED_DP_ATTRIBUTION' AND v_current_customer<>v_new_customer THEN
      v_amount:=(v_item->>'appliedAmount')::numeric;
      v_dp_legs:=v_dp_legs||jsonb_build_array(jsonb_build_object('leg','TRANSFER_DP_ATTRIBUTION',
        'accountingDate',v_new_date,'sourceId',v_item->>'applicationId','lines',jsonb_build_array(
          jsonb_build_object('accountId',v_advance,'debit',v_amount,'credit',0,
            'customerId',(v_item->>'fromCustomerId')::uuid,'description','Pindahkan DP dari customer lama'),
          jsonb_build_object('accountId',v_advance,'debit',0,'credit',v_amount,
            'customerId',v_new_customer,'description','Pindahkan DP ke customer Invoice'))));
    END IF;
  END LOOP;

  -- Amount leg uses exact preview deltas. Tax stays on the original per-line
  -- account; gross revenue and discount use canonical Invoice-event mappings.
  IF (v_execution->'amounts'->>'grossRevenueDelta')::numeric<>0 THEN
    v_amount:=(v_execution->'amounts'->>'grossRevenueDelta')::numeric;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',
      private.resolve_financial_event_account(v_event,'SALES_REVENUE'),
      'debit',greatest(-v_amount,0),'credit',greatest(v_amount,0),'customerId',v_new_customer,
      'description','Delta Pendapatan koreksi Invoice'));
  END IF;
  IF (v_execution->'amounts'->>'salesDiscountDelta')::numeric<>0 THEN
    v_amount:=(v_execution->'amounts'->>'salesDiscountDelta')::numeric;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',
      private.resolve_financial_event_account(v_event,'SALES_DISCOUNT'),
      'debit',greatest(v_amount,0),'credit',greatest(-v_amount,0),'customerId',v_new_customer,
      'description','Delta Potongan Penjualan koreksi Invoice'));
  END IF;
  FOR v_group IN
    SELECT NULLIF(line->>'taxAccountId','')::uuid account_id,
      round(sum((line->'after'->>'taxAmount')::numeric-(line->'before'->>'taxAmount')::numeric),4) amount
    FROM jsonb_array_elements(v_execution->'amounts'->'lines') line
    GROUP BY NULLIF(line->>'taxAccountId','')::uuid
  LOOP
    IF v_group.amount<>0 THEN
      IF v_group.account_id IS NULL THEN RAISE EXCEPTION 'INVOICE_REVISION_TAX_ACCOUNT_REQUIRED'; END IF;
      v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',v_group.account_id,
        'debit',greatest(-v_group.amount,0),'credit',greatest(v_group.amount,0),
        'customerId',v_new_customer,'description','Delta Pajak Keluaran koreksi Invoice'));
    END IF;
  END LOOP;
  IF v_ar_delta<>0 THEN
    v_amount:=v_ar_delta;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',v_ar,
      'debit',greatest(v_amount,0),'credit',greatest(-v_amount,0),'customerId',v_new_customer,
      'description','Delta Piutang koreksi Invoice'));
  END IF;
  IF v_refund_delta<>0 THEN
    v_refund:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');
    v_amount:=v_refund_delta;
    v_amount_legs:=v_amount_legs||jsonb_build_array(jsonb_build_object('accountId',v_refund,
      'debit',greatest(-v_amount,0),'credit',greatest(v_amount,0),'customerId',v_new_customer,
      'description','Delta Utang Refund koreksi Invoice'));
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(jsonb_build_array(
      jsonb_build_object('lines',v_reversal),jsonb_build_object('lines',v_replacement))
      ||v_receipt_legs||v_dp_legs||jsonb_build_array(jsonb_build_object('lines',v_amount_legs))) LOOP
    SELECT round(COALESCE(sum((line->>'debit')::numeric),0),4),
      round(COALESCE(sum((line->>'credit')::numeric),0),4)
    INTO v_debit,v_credit FROM jsonb_array_elements(v_item->'lines') line;
    IF v_debit<>v_credit THEN RAISE EXCEPTION 'INVOICE_REVISION_JOURNAL_PLAN_UNBALANCED'; END IF;
  END LOOP;
  RETURN v_execution||jsonb_build_object('status','JOURNAL_PLAN_NOT_POSTED',
    'recognitionReversal',jsonb_build_object('accountingDate',v_source_journal.accounting_date,
      'periodId',v_source_journal.accounting_period_id,'sourceJournalId',v_source_journal.id,'lines',v_reversal),
    'recognitionReplacement',jsonb_build_object('accountingDate',v_new_date,
      'periodId',v_execution->'dates'->>'periodId','lines',v_replacement),
    'receiptJournalLegs',v_receipt_legs,'downPaymentJournalLegs',v_dp_legs,
    'amountJournal',jsonb_build_object('accountingDate',v_new_date,'lines',v_amount_legs,
      'paidAmount',v_paid,'creditedAmount',v_credited,'arDelta',v_ar_delta,
      'refundLiabilityDelta',v_refund_delta),
    'writerEffect',false);
END
$journal_plan$;
REVOKE ALL ON FUNCTION private.plan_backoffice_invoice_revision_journals(uuid)
  FROM PUBLIC,anon,authenticated,service_role;
-- END supabase/staging/backoffice_invoice_revision_journal_plan.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_writer.sql
-- STAGING DEVELOPMENT CANDIDATE. Loaded only inside the rollback harness.
CREATE TABLE private.backoffice_invoice_revisions(
  company_id uuid NOT NULL REFERENCES public.companies(id),id uuid NOT NULL DEFAULT gen_random_uuid(),
  operation_id uuid NOT NULL,invoice_id uuid NOT NULL,revision_no bigint NOT NULL,
  prior_customer_id uuid NOT NULL,new_customer_id uuid NOT NULL,
  prior_invoice_date date NOT NULL,new_invoice_date date NOT NULL,
  payable_delta numeric(24,4) NOT NULL,source_snapshot jsonb NOT NULL,
  execution_plan jsonb NOT NULL,journal_ids jsonb NOT NULL,response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id),revision_date date NOT NULL,
  posted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(company_id,id),UNIQUE(company_id,operation_id),UNIQUE(company_id,invoice_id,revision_no),
  FOREIGN KEY(company_id,invoice_id) REFERENCES public.backoffice_sales_invoices(company_id,id),
  CHECK(revision_no>0 AND jsonb_typeof(source_snapshot)='object' AND jsonb_typeof(execution_plan)='object'
    AND jsonb_typeof(journal_ids)='array' AND jsonb_typeof(response_snapshot)='object'));
CREATE TABLE private.backoffice_invoice_revision_lines(
  company_id uuid NOT NULL,revision_id uuid NOT NULL,invoice_id uuid NOT NULL,invoice_line_id uuid NOT NULL,
  new_unit_price numeric(24,4) NOT NULL,new_discount_amount numeric(24,4) NOT NULL,
  before_amounts jsonb NOT NULL,after_amounts jsonb NOT NULL,
  PRIMARY KEY(company_id,revision_id,invoice_line_id),
  FOREIGN KEY(company_id,revision_id) REFERENCES private.backoffice_invoice_revisions(company_id,id),
  FOREIGN KEY(company_id,invoice_line_id) REFERENCES public.backoffice_sales_invoice_lines(company_id,id));
CREATE TABLE private.backoffice_invoice_revision_settlement_attributions(
  company_id uuid NOT NULL,revision_id uuid NOT NULL,source_type text NOT NULL,source_id uuid NOT NULL,
  action text NOT NULL,amount numeric(24,4) NOT NULL,from_customer_id uuid NOT NULL,to_customer_id uuid NOT NULL,
  source_snapshot jsonb NOT NULL,PRIMARY KEY(company_id,revision_id,source_type,source_id,action),
  FOREIGN KEY(company_id,revision_id) REFERENCES private.backoffice_invoice_revisions(company_id,id),
  CHECK(source_type IN('RECEIPT_ALLOCATION','DOWN_PAYMENT_APPLICATION') AND amount>0));
ALTER TABLE private.backoffice_invoice_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.backoffice_invoice_revision_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.backoffice_invoice_revision_settlement_attributions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.backoffice_invoice_revisions,private.backoffice_invoice_revision_lines,
  private.backoffice_invoice_revision_settlement_attributions FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.guard_backoffice_invoice_revision_history() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $g$ BEGIN RAISE EXCEPTION 'INVOICE_REVISION_HISTORY_IMMUTABLE'; END $g$;
CREATE TRIGGER invoice_revision_history_immutable BEFORE UPDATE OR DELETE ON private.backoffice_invoice_revisions
FOR EACH ROW EXECUTE FUNCTION private.guard_backoffice_invoice_revision_history();
CREATE TRIGGER invoice_revision_lines_immutable BEFORE UPDATE OR DELETE ON private.backoffice_invoice_revision_lines
FOR EACH ROW EXECUTE FUNCTION private.guard_backoffice_invoice_revision_history();
CREATE TRIGGER invoice_revision_settlement_immutable BEFORE UPDATE OR DELETE ON private.backoffice_invoice_revision_settlement_attributions
FOR EACH ROW EXECUTE FUNCTION private.guard_backoffice_invoice_revision_history();
REVOKE ALL ON FUNCTION private.guard_backoffice_invoice_revision_history() FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION private.backoffice_invoice_effective_total(uuid,uuid,date)
  RENAME TO backoffice_invoice_effective_total_before_unified_revision;
CREATE FUNCTION private.backoffice_invoice_effective_total(p_company_id uuid,p_invoice_id uuid,p_as_of date DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
 SELECT round(private.backoffice_invoice_effective_total_before_unified_revision(p_company_id,p_invoice_id,p_as_of)+
   COALESCE((SELECT sum(r.payable_delta) FROM private.backoffice_invoice_revisions r
     WHERE r.company_id=p_company_id AND r.invoice_id=p_invoice_id
       AND (p_as_of IS NULL OR r.revision_date<=p_as_of)),0),4)
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_total(uuid,uuid,date) FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)
  RENAME TO backoffice_invoice_effective_entered_unit_price_before_unified_revision;
CREATE FUNCTION private.backoffice_invoice_effective_entered_unit_price(p_company_id uuid,p_invoice_line_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
 SELECT COALESCE((SELECT l.new_unit_price FROM private.backoffice_invoice_revision_lines l
   JOIN private.backoffice_invoice_revisions r ON r.company_id=l.company_id AND r.id=l.revision_id
   WHERE l.company_id=p_company_id AND l.invoice_line_id=p_invoice_line_id
   ORDER BY r.revision_no DESC LIMIT 1),
   private.backoffice_invoice_effective_entered_unit_price_before_unified_revision(p_company_id,p_invoice_line_id))
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_entered_unit_price(uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;

ALTER FUNCTION private.backoffice_invoice_effective_line_amounts(uuid,uuid)
  RENAME TO backoffice_invoice_effective_line_amounts_before_unified_revision;
CREATE FUNCTION private.backoffice_invoice_effective_line_amounts(p_company_id uuid,p_invoice_line_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
DECLARE source public.backoffice_sales_invoice_lines%rowtype;price numeric(24,4);discount numeric(24,4);
 gross numeric(24,4);dpp numeric(24,4);tax numeric(24,4);tax_result jsonb;tax_line jsonb;revision bigint;
BEGIN
 SELECT * INTO source FROM public.backoffice_sales_invoice_lines l
  WHERE l.company_id=p_company_id AND l.id=p_invoice_line_id;
 IF NOT FOUND OR source.line_type<>'PRODUCT' OR source.source_kind<>'SALES_ORDER' THEN
  RAISE EXCEPTION 'BACKOFFICE_INVOICE_EFFECTIVE_LINE_INVALID'; END IF;
 SELECT l.new_unit_price,l.new_discount_amount,r.revision_no INTO price,discount,revision
 FROM private.backoffice_invoice_revision_lines l JOIN private.backoffice_invoice_revisions r
  ON r.company_id=l.company_id AND r.id=l.revision_id
 WHERE l.company_id=p_company_id AND l.invoice_line_id=p_invoice_line_id
 ORDER BY r.revision_no DESC LIMIT 1;
 IF NOT FOUND THEN RETURN private.backoffice_invoice_effective_line_amounts_before_unified_revision(
   p_company_id,p_invoice_line_id); END IF;
 gross:=round(source.quantity_uom*price-discount,4);
 IF gross<0 THEN RAISE EXCEPTION 'INVOICE_DISCOUNT_EXCEEDS_CORRECTED_LINE_TOTAL'; END IF;
 dpp:=gross;tax:=0;
 IF COALESCE((source.source_snapshot->>'taxApplied')::boolean,false) THEN
  IF source.source_snapshot->>'taxPriceMode'<>'INCLUSIVE'
   OR NULLIF(source.source_snapshot->>'taxRatePercent','') IS NULL
   OR NULLIF(source.source_snapshot->>'taxCalculationScope','') IS NULL THEN
   RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID'; END IF;
  tax_result:=private.calculate_tax_group(jsonb_build_array(
   jsonb_build_object('lineKey',source.id::text,'amount',gross)),
   (source.source_snapshot->>'taxRatePercent')::numeric,'SALES',
   source.source_snapshot->>'taxPriceMode',source.source_snapshot->>'taxCalculationScope');
  tax_line:=tax_result->'lines'->0;dpp:=round((tax_line->>'taxBase')::numeric,4);
  tax:=round((tax_line->>'taxAmount')::numeric,4);
 END IF;
 RETURN jsonb_build_object('enteredUnitPrice',price,'chargeAmount',round(dpp+discount,4),
  'discountAmount',discount,'lineAmount',dpp,'taxAmount',tax,'priceRevision',revision);
END
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_line_amounts(uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.backoffice_invoice_effective_identity(p_company_id uuid,p_invoice_id uuid,p_as_of date DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $f$
 SELECT jsonb_build_object('customerId',COALESCE(r.new_customer_id,i.customer_id),
   'invoiceDate',COALESCE(r.new_invoice_date,i.invoice_date),'revision',COALESCE(r.revision_no,0))
 FROM public.backoffice_sales_invoices i LEFT JOIN LATERAL(
   SELECT x.* FROM private.backoffice_invoice_revisions x WHERE x.company_id=i.company_id AND x.invoice_id=i.id
     AND (p_as_of IS NULL OR x.revision_date<=p_as_of) ORDER BY x.revision_no DESC LIMIT 1) r ON true
 WHERE i.company_id=p_company_id AND i.id=p_invoice_id
$f$;
REVOKE ALL ON FUNCTION private.backoffice_invoice_effective_identity(uuid,uuid,date) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.post_backoffice_invoice_revision_journal_leg(p_invoice_id uuid,p_revision_id uuid,p_leg_no integer,
  p_leg_name text,p_leg jsonb,p_journal_type text,p_reversal_of uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $post$
DECLARE c uuid:=public.private_active_company_id();actor uuid:=auth.uid();invoice public.backoffice_sales_invoices%rowtype;
 source_event public.financial_events%rowtype;period public.accounting_periods%rowtype;event_id uuid:=gen_random_uuid();
 journal_id uuid:=gen_random_uuid();d date:=(p_leg->>'accountingDate')::date;line jsonb;n integer:=0;j public.finance_journals%rowtype;
BEGIN
 IF jsonb_array_length(p_leg->'lines')=0 THEN RETURN NULL; END IF;
 SELECT i.* INTO STRICT invoice FROM public.backoffice_sales_invoices i
   WHERE i.company_id=c AND i.id=p_invoice_id;
 SELECT * INTO STRICT source_event FROM public.financial_events e WHERE e.company_id=c AND e.id=invoice.financial_event_id;
 SELECT * INTO STRICT period FROM public.accounting_periods p WHERE p.company_id=c AND d BETWEEN p.start_date AND p.end_date
   AND p.status IN('OPEN','REOPENED') ORDER BY p.start_date DESC,p.id LIMIT 1 FOR SHARE;
 INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,event_date,event_version,
   idempotency_key,amounts,status,created_by,company_id,store_id,system_event_key,transaction_category_id,transaction_rule_version)
 VALUES(event_id,'INV-REV-'||replace(p_revision_id::text,'-','')||'-'||p_leg_no,'SALE_REVISED',
   'backoffice_invoice_revisions',p_revision_id,d::timestamptz,p_leg_no,
   'INVOICE_REVISION_EVENT|'||c||'|'||p_revision_id||'|'||p_leg_no,
   jsonb_build_object('revisionId',p_revision_id,'leg',p_leg_name),'HOLD',actor,c,invoice.store_id,
   source_event.system_event_key,source_event.transaction_category_id,source_event.transaction_rule_version);
 INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,accounting_period_id,accounting_date,
   original_event_date,source_type,source_id,source_version,financial_event_id,idempotency_key,system_event_key,
   transaction_category_id,transaction_rule_version,store_id,warehouse_id,description,status,reversal_of_journal_id,created_by)
 VALUES(journal_id,c,'IRJ-'||replace(journal_id::text,'-',''),p_journal_type,period.id,d,d,
   'backoffice_invoice_revisions',p_revision_id,p_leg_no,event_id,
   'INVOICE_REVISION_JOURNAL|'||c||'|'||p_revision_id||'|'||p_leg_no,source_event.system_event_key,
   source_event.transaction_category_id,source_event.transaction_rule_version,invoice.store_id,invoice.warehouse_id,
   'Koreksi Invoice '||invoice.invoice_no||' - '||p_leg_name,'DRAFT',p_reversal_of,actor);
 FOR line IN SELECT value FROM jsonb_array_elements(p_leg->'lines') LOOP n:=n+10;
   INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,store_id,warehouse_id,customer_id,description)
   VALUES(c,journal_id,n,(line->>'accountId')::uuid,(line->>'debit')::numeric,(line->>'credit')::numeric,
     NULLIF(line->>'storeId','')::uuid,NULLIF(line->>'warehouseId','')::uuid,
     NULLIF(line->>'customerId','')::uuid,line->>'description');
 END LOOP;
 UPDATE public.finance_journals SET status='POSTED',posted_by=actor,posted_at=clock_timestamp()
 WHERE company_id=c AND id=journal_id RETURNING * INTO j;
 IF j.total_debit<=0 OR j.total_debit<>j.total_credit THEN RAISE EXCEPTION 'INVOICE_REVISION_JOURNAL_UNBALANCED'; END IF;
 UPDATE public.financial_events SET status='POSTED',processed_at=clock_timestamp() WHERE company_id=c AND id=event_id;
 RETURN journal_id;
END
$post$;
REVOKE ALL ON FUNCTION private.post_backoffice_invoice_revision_journal_leg(uuid,uuid,integer,text,jsonb,text,uuid)
 FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.execute_backoffice_invoice_revision(p_operation_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $execute$
DECLARE c uuid:=public.private_active_company_id();actor uuid:=auth.uid();prep private.backoffice_invoice_revision_preparations%rowtype;
 existing private.backoffice_invoice_revisions%rowtype;invoice public.backoffice_sales_invoices%rowtype;
 plan jsonb;revision_id uuid:=gen_random_uuid();revision_no bigint;ids jsonb:='[]'::jsonb;
  jid uuid;leg jsonb;n integer:=0;response jsonb;item jsonb;current_identity jsonb;
BEGIN
 IF actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 SELECT * INTO prep FROM private.backoffice_invoice_revision_preparations p
  WHERE p.company_id=c AND p.operation_id=p_operation_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVOICE_REVISION_PREPARATION_NOT_FOUND'; END IF;
 SELECT * INTO existing FROM private.backoffice_invoice_revisions r
  WHERE r.company_id=c AND r.operation_id=p_operation_id;
 IF FOUND THEN RETURN existing.response_snapshot||jsonb_build_object('exactRetry',true); END IF;
 plan:=private.plan_backoffice_invoice_revision_journals(p_operation_id);
 SELECT * INTO STRICT invoice FROM public.backoffice_sales_invoices i
  WHERE i.company_id=c AND i.id=prep.invoice_id;
 SELECT COALESCE(max(r.revision_no),0)+1 INTO revision_no FROM private.backoffice_invoice_revisions r
  WHERE r.company_id=c AND r.invoice_id=invoice.id;
  current_identity:=private.backoffice_invoice_effective_identity(c,invoice.id,NULL);
  IF revision_no>1 AND ((current_identity->>'customerId')::uuid<>(prep.request_snapshot->>'customerId')::uuid
      OR (current_identity->>'invoiceDate')::date<>(prep.request_snapshot->>'invoiceDate')::date) THEN
    RAISE EXCEPTION 'INVOICE_REVISION_REPEAT_IDENTITY_OR_DATE_NOT_YET_SUPPORTED';
  END IF;
  jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,10,'RECOGNITION_REVERSAL',
    plan->'recognitionReversal','PRIOR_PERIOD_ADJUSTMENT',NULL);
  IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;n:=10;
 jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,20,'RECOGNITION_REPLACEMENT',
    plan->'recognitionReplacement','AUTOMATIC',NULL);
  IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;n:=20;
 FOR leg IN SELECT value FROM jsonb_array_elements(plan->'receiptJournalLegs') LOOP
   n:=n+10;jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,n,leg->>'leg',leg,'AUTOMATIC',NULL);
    IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;
 END LOOP;
 FOR leg IN SELECT value FROM jsonb_array_elements(plan->'downPaymentJournalLegs') LOOP
   n:=n+10;jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,n,leg->>'leg',leg,'AUTOMATIC',NULL);
    IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;
 END LOOP;
 IF jsonb_array_length(plan->'amountJournal'->'lines')>0 THEN
   n:=n+10;jid:=private.post_backoffice_invoice_revision_journal_leg(invoice.id,revision_id,n,'AMOUNT_DELTA',
      plan->'amountJournal','AUTOMATIC',NULL);
    IF jid IS NOT NULL THEN ids:=ids||jsonb_build_array(jid); END IF;
 END IF;
 response:=jsonb_build_object('status','POSTED','revisionId',revision_id,'revision',revision_no,
   'invoiceId',invoice.id,'customerId',prep.request_snapshot->>'customerId',
   'invoiceDate',prep.request_snapshot->>'invoiceDate','effectiveTotal',plan->'amounts'->>'afterTotal',
   'journalIds',ids,'exactRetry',false);
 INSERT INTO private.backoffice_invoice_revisions(company_id,id,operation_id,invoice_id,revision_no,
   prior_customer_id,new_customer_id,prior_invoice_date,new_invoice_date,payable_delta,source_snapshot,
   execution_plan,journal_ids,response_snapshot,actor_id,revision_date)
  VALUES(c,revision_id,p_operation_id,invoice.id,revision_no,(current_identity->>'customerId')::uuid,
    (prep.request_snapshot->>'customerId')::uuid,(current_identity->>'invoiceDate')::date,
   (prep.request_snapshot->>'invoiceDate')::date,(plan->'amounts'->>'payableDelta')::numeric,
    prep.source_snapshot,plan,ids,response,actor,
    (clock_timestamp() AT TIME ZONE (SELECT timezone FROM public.companies WHERE id=c))::date);
 INSERT INTO private.backoffice_invoice_revision_lines(company_id,revision_id,invoice_id,invoice_line_id,
   new_unit_price,new_discount_amount,before_amounts,after_amounts)
  SELECT c,revision_id,invoice.id,(element.value->>'invoiceLineId')::uuid,
    (element.value->'after'->>'enteredUnitPrice')::numeric,
    (element.value->'after'->>'discountAmount')::numeric,
    element.value->'before',element.value->'after'
  FROM jsonb_array_elements(plan->'amounts'->'lines') element(value);
  FOR item IN SELECT element.value FROM jsonb_array_elements(plan->'receipts') element(value) LOOP
   IF item->>'action' NOT IN('NO_EFFECT_CANCELED') THEN
    INSERT INTO private.backoffice_invoice_revision_settlement_attributions(company_id,revision_id,source_type,
      source_id,action,amount,from_customer_id,to_customer_id,source_snapshot)
    VALUES(c,revision_id,'RECEIPT_ALLOCATION',(item->>'allocationId')::uuid,item->>'action',
      (item->>'allocatedAmount')::numeric,(current_identity->>'customerId')::uuid,
      (prep.request_snapshot->>'customerId')::uuid,item);
   END IF;
 END LOOP;
  FOR item IN SELECT element.value FROM jsonb_array_elements(plan->'downPayments') element(value) LOOP
   IF item->>'action'='TRANSFER_POSTED_DP_ATTRIBUTION' THEN
    INSERT INTO private.backoffice_invoice_revision_settlement_attributions(company_id,revision_id,source_type,
      source_id,action,amount,from_customer_id,to_customer_id,source_snapshot)
    VALUES(c,revision_id,'DOWN_PAYMENT_APPLICATION',(item->>'applicationId')::uuid,item->>'action',
      (item->>'appliedAmount')::numeric,(item->>'fromCustomerId')::uuid,
      (prep.request_snapshot->>'customerId')::uuid,item);
   END IF;
 END LOOP;
 PERFORM private.reconcile_backoffice_invoice_receivable_schedule(c,invoice.id);
  FOR item IN SELECT element.value FROM jsonb_array_elements(plan->'dates'->'schedules') element(value) LOOP
   UPDATE public.backoffice_sales_invoice_receivable_schedules SET due_date=(item->>'dueDate')::date,
     updated_at=clock_timestamp() WHERE company_id=c AND id=(item->>'scheduleId')::uuid;
 END LOOP;
 RETURN response;
END
$execute$;
REVOKE ALL ON FUNCTION private.execute_backoffice_invoice_revision(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION private.guard_legacy_invoice_price_correction_after_unified_revision()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $guard$
BEGIN
 IF EXISTS(SELECT 1 FROM private.backoffice_invoice_revisions r
   WHERE r.company_id=NEW.company_id AND r.invoice_id=NEW.source_invoice_id) THEN
  RAISE EXCEPTION 'LEGACY_PRICE_CORRECTION_AFTER_UNIFIED_REVISION_NOT_ALLOWED';
 END IF;
 RETURN NEW;
END
$guard$;
CREATE TRIGGER legacy_invoice_price_correction_unified_guard
BEFORE INSERT ON public.backoffice_sales_invoice_price_corrections FOR EACH ROW
EXECUTE FUNCTION private.guard_legacy_invoice_price_correction_after_unified_revision();
REVOKE ALL ON FUNCTION private.guard_legacy_invoice_price_correction_after_unified_revision()
 FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.post_backoffice_invoice_revision(p_command jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $rpc$
DECLARE prepared jsonb;
BEGIN
 prepared:=private.prepare_backoffice_invoice_revision(p_command);
 RETURN private.execute_backoffice_invoice_revision((p_command->>'operationId')::uuid);
END
$rpc$;
REVOKE ALL ON FUNCTION public.post_backoffice_invoice_revision(jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.post_backoffice_invoice_revision(jsonb) TO authenticated;

CREATE FUNCTION public.get_backoffice_invoice_revision_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $rpc$
DECLARE c uuid:=public.private_active_company_id();actor uuid:=auth.uid();invoice public.backoffice_sales_invoices%rowtype;
 identity jsonb;customer jsonb;history jsonb;lines jsonb;revision bigint;
BEGIN
 IF actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 IF c IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
 PERFORM private.acp_require_permission_capability(c,'sales.backoffice_orders','VIEW');
 SELECT * INTO invoice FROM public.backoffice_sales_invoices i WHERE i.company_id=c AND i.id=p_invoice_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
 IF invoice.status<>'POSTED' OR invoice.invoice_type<>'REGULAR' THEN
  RAISE EXCEPTION 'POSTED_REGULAR_INVOICE_REQUIRED'; END IF;
 identity:=private.backoffice_invoice_effective_identity(c,invoice.id,NULL);
 SELECT jsonb_build_object('id',cu.id,'code',cu.code,'name',cu.name,'address',cu.address,
   'phone',cu.phone,'masterVersion',cu.master_version) INTO STRICT customer
 FROM public.customers cu WHERE cu.company_id=c AND cu.id=(identity->>'customerId')::uuid;
 SELECT count(*) INTO revision FROM public.backoffice_sales_invoice_price_corrections pc
  WHERE pc.company_id=c AND pc.source_invoice_id=invoice.id AND pc.status='POSTED';
 revision:=revision+(identity->>'revision')::bigint;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'revision',r.revision_no,
   'postedAt',r.posted_at,'revisionDate',r.revision_date,'actorId',r.actor_id,'priorCustomerId',r.prior_customer_id,
   'customerId',r.new_customer_id,'priorInvoiceDate',r.prior_invoice_date,
   'invoiceDate',r.new_invoice_date,'payableDelta',r.payable_delta,'journalIds',r.journal_ids)
   ORDER BY r.revision_no),'[]'::jsonb) INTO history
 FROM private.backoffice_invoice_revisions r WHERE r.company_id=c AND r.invoice_id=invoice.id;
 SELECT COALESCE(jsonb_agg(jsonb_build_object('invoiceLineId',l.id,'productId',l.product_id,
   'sku',p.sku,'productName',p.name,
   'quantityUom',l.quantity_uom,'uomCode',u.code,
   'effectiveAmounts',private.backoffice_invoice_effective_line_amounts(c,l.id)) ORDER BY l.line_no),'[]'::jsonb)
 INTO lines FROM public.backoffice_sales_invoice_lines l
 LEFT JOIN public.products p ON p.company_id=l.company_id AND p.id=l.product_id
 LEFT JOIN public.uoms u ON u.company_id=l.company_id AND u.id=l.uom_id
 WHERE l.company_id=c AND l.invoice_id=invoice.id
  AND l.line_type='PRODUCT' AND l.source_kind='SALES_ORDER';
 RETURN jsonb_build_object('invoiceId',invoice.id,'invoiceNo',invoice.invoice_no,
  'masterVersion',invoice.master_version,'revision',revision,'effectiveIdentity',identity,
  'customer',customer,'effectiveTotal',private.backoffice_invoice_effective_total(c,invoice.id,NULL),
  'lines',lines,'schedules',COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY s.installment_no)
    FROM public.backoffice_sales_invoice_receivable_schedules s
    WHERE s.company_id=c AND s.invoice_id=invoice.id),'[]'::jsonb),
  'history',history,'canCorrect',NOT invoice.return_adjustment_pending_confirmation AND NOT EXISTS(
    SELECT 1 FROM public.backoffice_sales_credit_notes n WHERE n.company_id=c
      AND n.source_invoice_id=invoice.id AND n.status IN('DRAFT','POSTED')),
  'repeatIdentityOrDateChangeSupported',(identity->>'revision')::bigint=0);
END
$rpc$;
REVOKE ALL ON FUNCTION public.get_backoffice_invoice_revision_context(uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_backoffice_invoice_revision_context(uuid) TO authenticated;
-- END supabase/staging/backoffice_invoice_revision_writer.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_consumers.sql
-- STAGING DEVELOPMENT CANDIDATE. Effective UI and payment consumers only.
ALTER FUNCTION public.get_backoffice_sales_invoice_ui(uuid)
  RENAME TO get_backoffice_sales_invoice_ui_before_unified_revision;
CREATE FUNCTION public.get_backoffice_sales_invoice_ui(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp SET statement_timeout='8s' AS $ui$
DECLARE c uuid:=public.private_active_company_id();base jsonb;context jsonb;customer_snapshot jsonb;
BEGIN
 base:=public.get_backoffice_sales_invoice_ui_before_unified_revision(p_invoice_id);
 context:=public.get_backoffice_invoice_revision_context(p_invoice_id);
 SELECT jsonb_build_object('id',cu.id,'code',cu.code,'name',cu.name,'phone',cu.phone,
   'email',cu.email,'address',cu.address) INTO STRICT customer_snapshot
 FROM public.customers cu WHERE cu.company_id=c AND cu.id=(context->'effectiveIdentity'->>'customerId')::uuid;
 RETURN base||jsonb_build_object('data',(base->'data')||jsonb_build_object(
   'customerId',context->'effectiveIdentity'->>'customerId','customerSnapshot',customer_snapshot,
   'invoiceDate',context->'effectiveIdentity'->>'invoiceDate',
   'dueDate',context->'schedules'->0->>'due_date','effectiveGrandTotal',context->'effectiveTotal',
   'invoiceRevision',context->'revision','revisionHistory',context->'history'));
END
$ui$;

ALTER FUNCTION public.get_backoffice_sales_invoice_payment_context(uuid)
  RENAME TO get_backoffice_sales_invoice_payment_context_before_unified_revision;
CREATE FUNCTION public.get_backoffice_sales_invoice_payment_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp SET statement_timeout='8s' AS $payment$
DECLARE c uuid:=public.private_active_company_id();base jsonb;context jsonb;unified_refund numeric(24,4);
 total_refund numeric(24,4);refunded numeric(24,4);
BEGIN
 base:=public.get_backoffice_sales_invoice_payment_context_before_unified_revision(p_invoice_id);
 context:=public.get_backoffice_invoice_revision_context(p_invoice_id);
 SELECT round(COALESCE(sum((r.execution_plan->'amountJournal'->>'refundLiabilityDelta')::numeric),0),4)
 INTO unified_refund FROM private.backoffice_invoice_revisions r
 WHERE r.company_id=c AND r.invoice_id=p_invoice_id;
 total_refund:=(base->'summary'->>'refundLiabilityAmount')::numeric+unified_refund;
 refunded:=(base->'summary'->>'refundedAmount')::numeric;
 RETURN base||jsonb_build_object('effectiveIdentity',context->'effectiveIdentity',
   'customer',context->'customer','invoiceRevision',context->'revision',
   'invoiceRevisions',context->'history','summary',(base->'summary')||jsonb_build_object(
     'unifiedRevisionRefundLiabilityAmount',unified_refund,
     'refundLiabilityAmount',total_refund,'remainingRefundLiability',greatest(0,total_refund-refunded),
     'status',CASE WHEN greatest(0,total_refund-refunded)>0 THEN 'REFUND_PENDING'
       ELSE base->'summary'->>'status' END));
END
$payment$;

REVOKE ALL ON FUNCTION public.get_backoffice_sales_invoice_ui_before_unified_revision(uuid),
 public.get_backoffice_sales_invoice_payment_context_before_unified_revision(uuid),
 public.get_backoffice_sales_invoice_ui(uuid),public.get_backoffice_sales_invoice_payment_context(uuid)
 FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_invoice_ui(uuid),
 public.get_backoffice_sales_invoice_payment_context(uuid) TO authenticated,service_role;
-- END supabase/staging/backoffice_invoice_revision_consumers.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_report_consumers.sql
-- Generated only from the captured active staging definitions and exact anchors.
CREATE OR REPLACE FUNCTION public.get_finance_ar_aging(p_as_of date DEFAULT NULL::date, p_customer_id uuid DEFAULT NULL::uuid, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_company uuid:=public.private_active_company_id();v_timezone text;
  v_company_today date;v_as_of date;v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT company.timezone,(current_timestamp AT TIME ZONE company.timezone)::date
    INTO v_timezone,v_company_today FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_as_of:=COALESCE(p_as_of,v_company_today);
  IF v_as_of>v_company_today THEN RAISE EXCEPTION 'AR_AS_OF_DATE_FUTURE'; END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.customers customer
    WHERE customer.company_id=v_company AND customer.id=p_customer_id
      AND NOT customer.is_system_customer) THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
  IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id) THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
  RETURN (WITH invoice_items AS (
    SELECT 'RETAIL_SALE'::text source_process,sale.id source_id,sale.id sales_id,
      NULL::uuid schedule_id,NULL::integer installment_no,NULL::integer installment_count,
      invoice.invoice_no,sale.customer_id,customer.code customer_code,
      customer.name customer_name,sale.store_id,store.store_name,
      CASE WHEN sale.document_status='POSTED' THEN
        (sale.transaction_date AT TIME ZONE v_timezone)::date ELSE
        (SELECT min(effect.effective_date) FROM public.sales_dispatch_financial_effects effect
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
            AND effect.effective_date<=v_as_of) END transaction_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE
        (sale.due_date AT TIME ZONE v_timezone)::date END due_date,
      private.odr6d_dispatched_receivable_before_receipts(
        sale.company_id,sale.id,v_as_of) original_receivable,
      COALESCE((SELECT sum(allocation.allocated_amount)
        FROM public.customer_receipt_allocations allocation
        JOIN public.customer_receipt_documents receipt
          ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
         AND receipt.status='POSTED' AND receipt.receipt_date<=v_as_of
        WHERE allocation.company_id=v_company AND allocation.sales_id=sale.id),0) allocated_amount,
      COALESCE((SELECT sum(note.ar_reduction_amount)
        FROM public.backoffice_sales_credit_notes note
        WHERE note.company_id=v_company AND note.source_kind='RETAINED_RETAIL'
          AND note.source_retail_sales_id=sale.id AND note.status='POSTED'
          AND note.credit_note_date<=v_as_of),0) credited_amount
    FROM public.sales_headers sale
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id
      AND invoice.sales_id=sale.id
    JOIN public.customers customer ON customer.company_id=sale.company_id AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE sale.company_id=v_company AND sale.is_tempo
      AND (sale.document_status='POSTED' OR EXISTS(SELECT 1
        FROM public.sales_dispatch_financial_effects effect
        WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
          AND effect.effective_date<=v_as_of))
      AND (p_customer_id IS NULL OR sale.customer_id=p_customer_id)
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT 'BACKOFFICE',invoice.id,NULL::uuid,schedule.id,schedule.installment_no,
      (SELECT count(*)::integer FROM public.backoffice_sales_invoice_receivable_schedules all_schedule
       WHERE all_schedule.company_id=invoice.company_id AND all_schedule.invoice_id=invoice.id),
      invoice.invoice_no,(identity.value->>'customerId')::uuid,customer.code,customer.name,
      invoice.store_id,store.store_name,
      (identity.value->>'invoiceDate')::date,schedule.due_date,
      schedule.amount_due,
      GREATEST(LEAST(COALESCE(receipt.paid,0)+COALESCE(credit.credited,0)-COALESCE(sum(schedule.amount_due) OVER(
        PARTITION BY schedule.company_id,schedule.invoice_id ORDER BY schedule.installment_no
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0),schedule.amount_due),0),
      0::numeric credited_amount
    FROM public.backoffice_sales_invoices invoice
    JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    JOIN public.customers customer ON customer.company_id=invoice.company_id
      AND customer.id=(identity.value->>'customerId')::uuid
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    LEFT JOIN LATERAL(SELECT sum(allocation.allocated_amount) paid
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents document
        ON document.company_id=allocation.company_id AND document.id=allocation.document_id
       AND document.status='POSTED' AND document.receipt_date<=v_as_of
      WHERE allocation.company_id=invoice.company_id AND allocation.invoice_id=invoice.id) receipt ON true
    LEFT JOIN LATERAL(SELECT sum(note.ar_reduction_amount) credited
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status='POSTED' AND note.credit_note_date<=v_as_of) credit ON true
    WHERE invoice.company_id=v_company AND invoice.status='POSTED'
      AND (identity.value->>'invoiceDate')::date<=v_as_of AND schedule.status IN('OPEN','PARTIALLY_PAID','PAID')
      AND (p_customer_id IS NULL OR (identity.value->>'customerId')::uuid=p_customer_id)
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),open_items AS (
    SELECT invoice.*,GREATEST(original_receivable-allocated_amount-credited_amount,0) outstanding,
      CASE WHEN due_date IS NULL THEN 'NO_DUE_DATE' WHEN due_date>=v_as_of THEN 'NOT_DUE'
        WHEN v_as_of-due_date<=30 THEN 'OVERDUE_1_30' WHEN v_as_of-due_date<=60 THEN 'OVERDUE_31_60'
        WHEN v_as_of-due_date<=90 THEN 'OVERDUE_61_90' ELSE 'OVERDUE_GT_90' END aging_bucket,
      CASE WHEN due_date IS NULL OR due_date>=v_as_of THEN 0 ELSE v_as_of-due_date END overdue_days
    FROM invoice_items invoice WHERE original_receivable-allocated_amount-credited_amount>0
  ),bucket_order(bucket,sort_order) AS (VALUES ('NOT_DUE'::text,1),('OVERDUE_1_30',2),
    ('OVERDUE_31_60',3),('OVERDUE_61_90',4),('OVERDUE_GT_90',5),('NO_DUE_DATE',6))
  SELECT jsonb_build_object('companyId',v_company,'asOf',v_as_of,
    'effectiveCapabilities',v_permission->'effectiveCapabilities','summary',jsonb_build_object(
      'invoiceCount',(SELECT count(DISTINCT source_process||'|'||source_id::text) FROM open_items),
      'itemCount',(SELECT count(*) FROM open_items),
      'customerCount',(SELECT count(DISTINCT customer_id) FROM open_items),
      'originalReceivable',COALESCE((SELECT sum(original_receivable) FROM open_items),0),
      'allocatedAmount',COALESCE((SELECT sum(allocated_amount) FROM open_items),0),
      'outstanding',COALESCE((SELECT sum(outstanding) FROM open_items),0),
      'overdue',COALESCE((SELECT sum(outstanding) FROM open_items WHERE aging_bucket LIKE 'OVERDUE%'),0)),
    'buckets',(SELECT jsonb_agg(jsonb_build_object('bucket',bucket_order.bucket,
      'invoiceCount',COALESCE(bucket.invoice_count,0),'customerCount',COALESCE(bucket.customer_count,0),
      'outstanding',COALESCE(bucket.outstanding,0)) ORDER BY bucket_order.sort_order)
      FROM bucket_order LEFT JOIN (SELECT aging_bucket,
        count(DISTINCT source_process||'|'||source_id::text) invoice_count,
        count(DISTINCT customer_id) customer_count,sum(outstanding) outstanding
        FROM open_items GROUP BY aging_bucket) bucket ON bucket.aging_bucket=bucket_order.bucket),
    'invoices',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'sourceProcess',item.source_process,'sourceId',item.source_id,'salesId',item.sales_id,
      'scheduleId',item.schedule_id,'installmentNo',item.installment_no,
      'installmentCount',item.installment_count,'invoiceNo',item.invoice_no,
      'customerId',item.customer_id,'customerCode',item.customer_code,
      'customerName',item.customer_name,'storeId',item.store_id,'storeName',item.store_name,
      'transactionDate',item.transaction_date,'dueDate',item.due_date,
      'originalReceivable',item.original_receivable,'allocatedAmount',item.allocated_amount,'creditedAmount',item.credited_amount,
      'outstanding',item.outstanding,'agingBucket',item.aging_bucket,'overdueDays',item.overdue_days)
      ORDER BY item.due_date NULLS LAST,item.transaction_date,item.invoice_no,item.installment_no),'[]'::jsonb)
      FROM open_items item)));
END
$function$;

CREATE OR REPLACE FUNCTION public.get_finance_customer_statement(p_customer_id uuid, p_date_from date DEFAULT NULL::date, p_as_of date DEFAULT NULL::date, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_company uuid:=public.private_active_company_id();v_timezone text;v_company_today date;
  v_from date;v_as_of date;v_customer public.customers%rowtype;v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT company.timezone,(current_timestamp AT TIME ZONE company.timezone)::date
    INTO v_timezone,v_company_today FROM public.companies company
    WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_as_of:=COALESCE(p_as_of,v_company_today);v_from:=COALESCE(p_date_from,(v_as_of-INTERVAL '90 days')::date);
  IF v_as_of>v_company_today THEN RAISE EXCEPTION 'AR_AS_OF_DATE_FUTURE'; END IF;
  IF v_from>v_as_of THEN RAISE EXCEPTION 'AR_DATE_RANGE_INVALID'; END IF;
  SELECT * INTO v_customer FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=p_customer_id AND NOT customer.is_system_customer;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_NOT_FOUND'; END IF;
  IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores store
    WHERE store.company_id=v_company AND store.id=p_store_id) THEN RAISE EXCEPTION 'STORE_NOT_FOUND'; END IF;
  RETURN (WITH invoice_rows AS (
    SELECT sale.id source_id,'INVOICE'::text source_type,'RETAIL'::text source_process,
      invoice.invoice_no document_no,(sale.transaction_date AT TIME ZONE v_timezone)::date business_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::date END due_date,
      sale.store_id,store.store_name,sale.sisa_piutang debit,0::numeric credit,
      'Invoice penjualan Retail tempo'::text description
    FROM public.sales_headers sale JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE sale.company_id=v_company AND sale.customer_id=p_customer_id
      AND sale.document_status='POSTED' AND sale.is_tempo
      AND (sale.transaction_date AT TIME ZONE v_timezone)::date<=v_as_of
      AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT effect.id,'INVOICE','RETAIL',invoice.invoice_no,effect.effective_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::date END,
      sale.store_id,store.store_name,effect.receivable_amount,0::numeric,
      'Piutang Retail dari Dispatch '||delivery.delivery_no
    FROM public.sales_dispatch_financial_effects effect
    JOIN public.sales_headers sale ON sale.company_id=effect.company_id AND sale.id=effect.sales_id
      AND sale.is_tempo AND sale.customer_id=p_customer_id AND sale.document_status<>'POSTED'
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    JOIN public.sales_delivery_documents delivery ON delivery.company_id=effect.company_id
      AND delivery.id=effect.delivery_document_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE effect.company_id=v_company AND effect.effective_date<=v_as_of
      AND effect.receivable_amount>0 AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT invoice.id,'INVOICE','BACKOFFICE',invoice.invoice_no,(identity.value->>'invoiceDate')::date,
      (SELECT min(schedule.due_date) FROM public.backoffice_sales_invoice_receivable_schedules schedule
       WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id),
      invoice.store_id,store.store_name,invoice.grand_total,0::numeric,
      CASE invoice.invoice_type WHEN 'DOWN_PAYMENT' THEN 'Invoice DP Backoffice'
        ELSE 'Invoice penjualan Backoffice' END
    FROM public.backoffice_sales_invoices invoice
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE invoice.company_id=v_company AND (identity.value->>'customerId')::uuid=p_customer_id
      AND invoice.status='POSTED' AND (identity.value->>'invoiceDate')::date<=v_as_of
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),receipt_rows AS (
    SELECT allocation.id source_id,'RECEIPT'::text source_type,'RETAIL'::text source_process,
      receipt.receipt_no document_no,receipt.receipt_date business_date,
      CASE WHEN allocation.due_date_snapshot IS NULL THEN NULL
        ELSE (allocation.due_date_snapshot AT TIME ZONE v_timezone)::date END due_date,
      sale.store_id,store.store_name,0::numeric debit,allocation.allocated_amount credit,
      ('Pembayaran Retail '||allocation.invoice_no_snapshot)::text description
    FROM public.customer_receipt_allocations allocation JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    JOIN public.sales_headers sale ON sale.company_id=allocation.company_id AND sale.id=allocation.sales_id
      AND sale.customer_id=p_customer_id LEFT JOIN public.stores store
      ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE allocation.company_id=v_company AND receipt.customer_id=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT request.id,'ODR_PAYMENT','RETAIL',sale.invoice_no,request.effective_date,
      CASE WHEN sale.due_date IS NULL THEN NULL ELSE (sale.due_date AT TIME ZONE v_timezone)::date END,
      sale.store_id,store.store_name,0::numeric,request.amount,'Pembayaran ODR terverifikasi'
    FROM public.sales_payment_verification_requests request JOIN public.sales_headers sale
      ON sale.company_id=request.company_id AND sale.id=request.sales_id AND sale.customer_id=p_customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
    WHERE request.company_id=v_company AND request.status='VERIFIED'
      AND request.receipt_timing='POST_DISPATCH' AND request.settlement_target='CUSTOMER_RECEIVABLE'
      AND request.effective_date<=v_as_of AND (p_store_id IS NULL OR sale.store_id=p_store_id)
    UNION ALL
    SELECT allocation.id,'RECEIPT','BACKOFFICE',receipt.receipt_no,receipt.receipt_date,
      allocation.due_date_snapshot,invoice.store_id,store.store_name,0::numeric,
      allocation.allocated_amount,('Pembayaran Backoffice '||allocation.invoice_no_snapshot)::text
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=allocation.company_id AND invoice.id=allocation.invoice_id
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE allocation.company_id=v_company AND (identity.value->>'customerId')::uuid=p_customer_id
      AND receipt.receipt_date<=v_as_of AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
    UNION ALL
    SELECT note.id,'CREDIT_NOTE',CASE note.source_kind
        WHEN 'RETAINED_RETAIL' THEN 'RETAIL' ELSE 'BACKOFFICE' END,note.credit_note_no,note.credit_note_date,
      NULL::date,note.store_id,store.store_name,0::numeric,note.grand_total,
      ('Credit Note Retur Customer untuk '||COALESCE(source.invoice_no,
        note.source_invoice_snapshot->>'invoiceNo'))::text
    FROM public.backoffice_sales_credit_notes note
    LEFT JOIN public.backoffice_sales_invoices source
      ON source.company_id=note.company_id AND source.id=note.source_invoice_id
    LEFT JOIN public.stores store ON store.company_id=note.company_id AND store.id=note.store_id
    WHERE note.company_id=v_company AND note.customer_id=p_customer_id
      AND note.status='POSTED' AND note.credit_note_date<=v_as_of
      AND (p_store_id IS NULL OR note.store_id=p_store_id)
    UNION ALL
    SELECT refund.id,'CUSTOMER_REFUND','BACKOFFICE',refund.refund_no,refund.refund_date,
      NULL::date,refund.store_id,store.store_name,
      CASE WHEN refund.document_kind='REFUND' THEN refund.amount ELSE 0::numeric END,
      CASE WHEN refund.document_kind='REVERSAL' THEN refund.amount ELSE 0::numeric END,
      (CASE WHEN refund.document_kind='REFUND' THEN 'Refund Customer untuk '
        ELSE 'Reversal Refund Customer untuk ' END||note.credit_note_no)::text
    FROM public.backoffice_sales_customer_refunds refund
    JOIN public.backoffice_sales_credit_notes note
      ON note.company_id=refund.company_id AND note.id=refund.credit_note_id
      AND note.customer_id=p_customer_id
    LEFT JOIN public.stores store
      ON store.company_id=refund.company_id AND store.id=refund.store_id
    WHERE refund.company_id=v_company AND refund.status='POSTED'
      AND refund.refund_date<=v_as_of
      AND (p_store_id IS NULL OR refund.store_id=p_store_id)
    UNION ALL
    SELECT correction.id,'PRICE_CORRECTION','BACKOFFICE',correction.correction_no,
      correction.correction_date,NULL::date,invoice.store_id,store.store_name,
      CASE WHEN correction.total_delta>0 THEN correction.total_delta ELSE 0::numeric END,
      CASE WHEN correction.total_delta<0 THEN -correction.total_delta ELSE 0::numeric END,
      (CASE correction.correction_kind WHEN 'DEBIT_NOTE' THEN 'Debit Note koreksi harga untuk '
        ELSE 'Credit Note koreksi harga untuk ' END||invoice.invoice_no)::text
    FROM public.backoffice_sales_invoice_price_corrections correction
    JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=correction.company_id AND invoice.id=correction.source_invoice_id
    JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,v_as_of) value) identity ON true
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE correction.company_id=v_company AND correction.status='POSTED'
      AND correction.correction_date<=v_as_of
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
    UNION ALL
    SELECT revision.id,'INVOICE_REVISION','BACKOFFICE',
      invoice.invoice_no||'-R'||revision.revision_no,revision.revision_date,NULL::date,
      invoice.store_id,store.store_name,greatest(revision.payable_delta,0),
      greatest(-revision.payable_delta,0),'Koreksi Invoice posted'
    FROM private.backoffice_invoice_revisions revision
    JOIN public.backoffice_sales_invoices invoice ON invoice.company_id=revision.company_id
      AND invoice.id=revision.invoice_id
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE revision.company_id=v_company AND revision.new_customer_id=p_customer_id
      AND revision.revision_date<=v_as_of AND revision.payable_delta<>0
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows),
  opening AS (SELECT COALESCE(sum(debit-credit),0) amount FROM all_rows WHERE business_date<v_from),
  period_rows AS (SELECT row_data.*,row_number() OVER(ORDER BY business_date,
    CASE source_type WHEN 'INVOICE' THEN 1 ELSE 2 END,source_process,source_id) sequence_no
    FROM all_rows row_data WHERE business_date BETWEEN v_from AND v_as_of),
  running AS (SELECT period_rows.*,opening.amount+sum(debit-credit) OVER(ORDER BY sequence_no
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) running_balance FROM period_rows CROSS JOIN opening)
  SELECT jsonb_build_object('companyId',v_company,'customer',jsonb_build_object('id',v_customer.id,
    'code',v_customer.code,'name',v_customer.name),'dateFrom',v_from,'asOf',v_as_of,
    'effectiveCapabilities',v_permission->'effectiveCapabilities','openingBalance',(SELECT amount FROM opening),
    'periodDebit',COALESCE((SELECT sum(debit) FROM period_rows),0),
    'periodCredit',COALESCE((SELECT sum(credit) FROM period_rows),0),
    'endingBalance',(SELECT amount FROM opening)+COALESCE((SELECT sum(debit-credit) FROM period_rows),0),
    'rows',(SELECT COALESCE(jsonb_agg(jsonb_build_object('sequence',row_data.sequence_no,
      'sourceId',row_data.source_id,'sourceType',row_data.source_type,
      'sourceProcess',row_data.source_process,'documentNo',row_data.document_no,
      'businessDate',row_data.business_date,'dueDate',row_data.due_date,'storeId',row_data.store_id,
      'storeName',row_data.store_name,'description',row_data.description,'debit',row_data.debit,
      'credit',row_data.credit,'runningBalance',row_data.running_balance)
      ORDER BY row_data.sequence_no),'[]'::jsonb) FROM running row_data)));
END
$function$;
-- END supabase/staging/backoffice_invoice_revision_report_consumers.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_export_consumer.sql
-- Generated only from the captured active staging export definition and exact anchors.
CREATE OR REPLACE FUNCTION public.export_sales_documents(p_date_from date, p_date_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET statement_timeout TO '30s'
AS $function$
DECLARE
  v_company uuid:=public.private_active_company_id();
  v_company_row public.companies%ROWTYPE;
BEGIN
  IF p_date_from IS NULL OR p_date_to IS NULL OR p_date_from>p_date_to THEN
    RAISE EXCEPTION 'SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID';
  END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','EXPORT');
  SELECT company.* INTO STRICT v_company_row
  FROM public.companies company WHERE company.id=v_company;

  RETURN (
    WITH retail_base AS (
      SELECT invoice.id invoice_id,invoice.sales_id,invoice.invoice_no,
        invoice.snapshot_provenance,invoice.created_at,
        invoice.snapshot_payload payload,sale.document_status,
        sale.order_runtime_status,sale.source_channel,sale.fulfillment_mode,
        sale.is_tempo,sale.due_date,sale.grand_total_after_rounding,
        sale.delivery_fee_amount,sale.paid_amount,sale.sisa_piutang,
        sale.canceled_at,sale.cancel_reason,cancel_actor.name canceled_by_name,
        private.resolve_sales_invoice_display_date(invoice.snapshot_payload,
          to_jsonb(sale),invoice.created_at,v_company_row.timezone) invoice_date,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{customer,code}',''),customer.code,'') customer_code,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{customer,name}',''),customer.name,'Walk-In Customer') customer_name,
        COALESCE(NULLIF(invoice.snapshot_payload#>>'{store,name}',''),store.store_name,'Store') store_name
      FROM public.sales_invoice_snapshots invoice
      JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
        AND sale.id=invoice.sales_id
      LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
        AND customer.id=sale.customer_id
      LEFT JOIN public.stores store ON store.company_id=sale.company_id
        AND store.id=sale.store_id
      LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=sale.canceled_by
      WHERE invoice.company_id=v_company
    ), retail_scoped AS (
      SELECT * FROM retail_base WHERE invoice_date BETWEEN p_date_from AND p_date_to
    ), backoffice_scoped AS (
      SELECT invoice.*,document.order_no,document.fulfillment_status,document.is_tempo,
        (identity.value->>'invoiceDate')::date effective_invoice_date,
        store.store_name,customer.code customer_code,customer.name customer_name,
        cancel_actor.name canceled_by_name,
        (SELECT min(schedule.due_date)
         FROM public.backoffice_sales_invoice_receivable_schedules schedule
         WHERE schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id) due_date,
        COALESCE((SELECT sum(allocation.allocated_amount)
          FROM public.customer_receipt_backoffice_invoice_allocations allocation
          JOIN public.customer_receipt_documents receipt
            ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
          WHERE allocation.company_id=invoice.company_id
            AND allocation.invoice_id=invoice.id AND receipt.status='POSTED'),0) paid_amount
      FROM public.backoffice_sales_invoices invoice
      JOIN LATERAL(SELECT private.backoffice_invoice_effective_identity(invoice.company_id,invoice.id,NULL) value) identity ON true
      JOIN public.backoffice_sales_orders document ON document.company_id=invoice.company_id
        AND document.id=invoice.sales_order_id
      LEFT JOIN public.customers customer ON customer.company_id=invoice.company_id
        AND customer.id=(identity.value->>'customerId')::uuid
      LEFT JOIN public.stores store ON store.company_id=invoice.company_id
        AND store.id=invoice.store_id
      LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=invoice.canceled_by
      WHERE invoice.company_id=v_company
        AND (identity.value->>'invoiceDate')::date BETWEEN p_date_from AND p_date_to
    ), invoice_rows AS (
      SELECT scoped.invoice_id,scoped.sales_id,NULL::uuid sales_order_id,
        'RETAIL'::text source_kind,scoped.invoice_no::text document_no,
        scoped.invoice_no::text invoice_no,NULL::text draft_no,NULL::text sales_order_no,
        scoped.invoice_date,
        CASE WHEN scoped.order_runtime_status='CANCELED'
          OR scoped.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END invoice_status,
        scoped.customer_code,scoped.customer_name,scoped.store_name,
        scoped.source_channel::text,scoped.fulfillment_mode::text,
        COALESCE((scoped.payload->>'isTempo')::boolean,scoped.is_tempo,false) is_tempo,
        COALESCE(NULLIF(scoped.payload->>'dueDate','')::timestamptz,scoped.due_date)::date due_date,
        COALESCE((scoped.payload#>>'{totals,subtotal}')::numeric,0) subtotal,
        COALESCE((scoped.payload#>>'{totals,itemDiscount}')::numeric,0) item_discount,
        COALESCE((scoped.payload#>>'{totals,orderDiscount}')::numeric,0) order_discount,
        COALESCE((scoped.payload#>>'{totals,itemDiscount}')::numeric,0)
          +COALESCE((scoped.payload#>>'{totals,orderDiscount}')::numeric,0) total_discount,
        COALESCE((SELECT sum(COALESCE(NULLIF(line.value->>'taxAmount','')::numeric,0))
          FROM jsonb_array_elements(COALESCE(scoped.payload->'lines','[]'::jsonb)) line),0) tax_total,
        COALESCE((scoped.payload#>>'{totals,deliveryFee}')::numeric,
          scoped.delivery_fee_amount,0) delivery_fee,
        COALESCE((scoped.payload#>>'{totals,roundingAdjustment}')::numeric,0) rounding_adjustment,
        COALESCE((scoped.payload#>>'{totals,grandTotal}')::numeric,
          scoped.grand_total_after_rounding,0) grand_total,
        COALESCE((scoped.payload#>>'{totals,paidAmount}')::numeric,scoped.paid_amount,0) paid_amount,
        COALESCE((scoped.payload#>>'{totals,receivable}')::numeric,scoped.sisa_piutang,0) receivable,
        scoped.canceled_at,scoped.cancel_reason,scoped.canceled_by_name,
        scoped.snapshot_provenance::text,scoped.created_at
      FROM retail_scoped scoped
      UNION ALL
      SELECT scoped.id,scoped.id,scoped.sales_order_id,
        'BACKOFFICE',COALESCE(scoped.invoice_no,scoped.draft_no),
        scoped.invoice_no,scoped.draft_no,scoped.order_no,scoped.effective_invoice_date,
        scoped.status,COALESCE(scoped.customer_code,''),
        COALESCE(scoped.customer_name,scoped.customer_snapshot->>'name','Customer'),
        COALESCE(scoped.store_name,'Store'),'BACKOFFICE',scoped.fulfillment_status,
        scoped.is_tempo,scoped.due_date,
        scoped.charge_total-COALESCE((SELECT sum(line.line_amount+line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'chargeAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.discount_total-COALESCE((SELECT sum(line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'discountAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        0::numeric,
        scoped.discount_total-COALESCE((SELECT sum(line.discount_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'discountAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.tax_total-COALESCE((SELECT sum(line.tax_amount) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'),0)+COALESCE((SELECT sum(CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (private.backoffice_invoice_effective_line_amounts(scoped.company_id,line.id)->>'taxAmount')::numeric ELSE 0 END) FROM public.backoffice_sales_invoice_lines line WHERE line.company_id=scoped.company_id AND line.invoice_id=scoped.id),0),
        scoped.delivery_fee_amount,0::numeric,
        private.backoffice_invoice_effective_total(scoped.company_id,scoped.id,NULL),scoped.paid_amount,
        greatest(private.backoffice_invoice_effective_total(scoped.company_id,scoped.id,NULL)-scoped.paid_amount,0),scoped.canceled_at,
        scoped.cancel_reason,scoped.canceled_by_name,'BACKOFFICE_CANONICAL',scoped.created_at
      FROM backoffice_scoped scoped
    ), line_rows AS (
      SELECT 'RETAIL'::text source_kind,scoped.invoice_no::text document_no,
        scoped.invoice_no::text invoice_no,NULL::text draft_no,NULL::text sales_order_no,
        scoped.invoice_date,
        CASE WHEN scoped.order_runtime_status='CANCELED'
          OR scoped.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END invoice_status,
        scoped.customer_code,scoped.customer_name,element.ordinality::bigint line_no,
        'PRODUCT'::text line_type,'CHARGE'::text effect_type,
        COALESCE(element.value->>'sku','') sku,
        COALESCE(element.value->>'productName','') product_name,
        COALESCE(element.value->>'uomName','') uom_name,
        COALESCE(NULLIF(element.value->>'quantity','')::numeric,0) quantity,
        COALESCE(NULLIF(element.value->>'factorToBase','')::numeric,0) factor_to_base,
        COALESCE(NULLIF(element.value->>'quantityBase','')::numeric,0) quantity_base,
        COALESCE(NULLIF(element.value->>'unitPrice','')::numeric,0) unit_price,
        COALESCE(NULLIF(element.value->>'discount','')::numeric,0) discount,
        COALESCE(element.value->>'taxCode','') tax_code,
        COALESCE(element.value->>'taxName','') tax_name,
        COALESCE(NULLIF(element.value->>'taxRatePercent','')::numeric,0) tax_rate_percent,
        COALESCE(NULLIF(element.value->>'taxAmount','')::numeric,0) tax_amount,
        COALESCE(NULLIF(element.value->>'lineTotal','')::numeric,0) line_total
      FROM retail_scoped scoped
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(scoped.payload->'lines','[]'::jsonb))
        WITH ORDINALITY AS element(value,ordinality)
      UNION ALL
      SELECT 'BACKOFFICE',COALESCE(invoice.invoice_no,invoice.draft_no),
        invoice.invoice_no,invoice.draft_no,invoice.order_no,invoice.effective_invoice_date,
        invoice.status,COALESCE(invoice.customer_code,''),
        COALESCE(invoice.customer_name,invoice.customer_snapshot->>'name','Customer'),
        line.line_no::bigint,line.line_type,line.effect_type,
        COALESCE(source.product_code_snapshot,product.sku,''),
        COALESCE(source.product_name_snapshot,product.name,line.description),
        COALESCE(source.uom_name_snapshot,uom.name,''),
        COALESCE(line.quantity_uom,0),COALESCE(line.base_qty_per_uom,0),
        COALESCE(line.quantity_base,0),
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'enteredUnitPrice')::numeric ELSE line.unit_price END,
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'discountAmount')::numeric ELSE line.discount_amount END,
        COALESCE(line.source_snapshot->>'taxCode',''),
        COALESCE(line.source_snapshot->>'taxName',''),
        COALESCE(NULLIF(line.source_snapshot->>'taxRatePercent','')::numeric,0),
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'taxAmount')::numeric ELSE line.tax_amount END,
        CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER' THEN (effective.value->>'lineAmount')::numeric ELSE line.line_amount END
      FROM backoffice_scoped invoice
      JOIN public.backoffice_sales_invoice_lines line ON line.company_id=invoice.company_id
        AND line.invoice_id=invoice.id
      LEFT JOIN LATERAL(SELECT CASE WHEN line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'
        THEN private.backoffice_invoice_effective_line_amounts(line.company_id,line.id) END value) effective ON true
      LEFT JOIN public.backoffice_sales_order_lines source ON source.company_id=line.company_id
        AND source.id=line.sales_order_line_id
      LEFT JOIN public.products product ON product.company_id=line.company_id
        AND product.id=line.product_id
      LEFT JOIN public.uoms uom ON uom.company_id=line.company_id AND uom.id=line.uom_id
    )
    SELECT jsonb_build_object(
      'companyId',v_company,'companyCode',v_company_row.company_code,
      'companyName',v_company_row.company_name,'dateFrom',p_date_from,
      'dateTo',p_date_to,'generatedAt',statement_timestamp(),
      'invoices',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'invoiceId',row_data.invoice_id,'salesId',row_data.sales_id,
        'salesOrderId',row_data.sales_order_id,'sourceKind',row_data.source_kind,
        'documentNo',row_data.document_no,'invoiceNo',row_data.invoice_no,
        'draftNo',row_data.draft_no,'salesOrderNo',row_data.sales_order_no,
        'invoiceDate',row_data.invoice_date,'invoiceStatus',row_data.invoice_status,
        'customerCode',row_data.customer_code,'customerName',row_data.customer_name,
        'storeName',row_data.store_name,'sourceChannel',row_data.source_channel,
        'fulfillmentMode',row_data.fulfillment_mode,'isTempo',row_data.is_tempo,
        'dueDate',row_data.due_date,'subtotal',row_data.subtotal,
        'itemDiscount',row_data.item_discount,'orderDiscount',row_data.order_discount,
        'totalDiscount',row_data.total_discount,'taxTotal',row_data.tax_total,
        'deliveryFee',row_data.delivery_fee,'roundingAdjustment',row_data.rounding_adjustment,
        'grandTotal',row_data.grand_total,'paidAmount',row_data.paid_amount,
        'receivable',row_data.receivable,'canceledAt',row_data.canceled_at,
        'cancelReason',row_data.cancel_reason,'canceledByName',row_data.canceled_by_name,
        'snapshotProvenance',row_data.snapshot_provenance)
        ORDER BY row_data.invoice_date DESC,row_data.created_at DESC,row_data.invoice_id)
        FROM invoice_rows row_data),'[]'::jsonb),
      'lines',COALESCE((SELECT jsonb_agg(to_jsonb(row_data)
        ORDER BY row_data.invoice_date DESC,row_data.document_no,row_data.line_no)
        FROM line_rows row_data),'[]'::jsonb)
    )
  );
END
$function$;
-- END supabase/staging/backoffice_invoice_revision_export_consumer.sql

-- BEGIN supabase/staging/backoffice_invoice_revision_return_consumers.sql
-- Generated only from captured active staging Return/Credit Note core definitions.
CREATE OR REPLACE FUNCTION private.allocate_backoffice_sales_return_invoices_before_retained(p_return_id uuid, p_expected_version bigint, p_operation_id uuid, p_allocations jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET statement_timeout TO '15s'
AS $function$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_return public.backoffice_sales_returns%rowtype;v_item jsonb;v_type text;
  v_receipt_line public.backoffice_sales_return_receipt_lines%rowtype;
  v_order_line public.backoffice_sales_order_lines%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;
  v_invoice_line public.backoffice_sales_invoice_lines%rowtype;
  v_qty_uom numeric(24,6);v_qty_base numeric(24,6);v_used numeric(24,6);
  v_alloc public.backoffice_sales_invoice_quantity_allocations%rowtype;
  v_note public.backoffice_sales_credit_notes%rowtype;v_note_id uuid;v_line_no integer;
  v_ratio numeric;v_charge numeric(24,4);v_discount numeric(24,4);
  v_tax numeric(24,4);v_line_amount numeric(24,4);v_prior numeric(24,4);
  v_hash text;v_retry jsonb;v_response jsonb;v_invoice_op uuid;
  v_before jsonb;v_after jsonb;v_all_received boolean;v_has_draft_notes boolean;
  v_effective_line jsonb;v_effective_identity jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','CREATE_DRAFT');
  IF p_return_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL
    OR jsonb_typeof(p_allocations)<>'array' OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_REQUIRED: pilih tujuan untuk setiap qty Retur yang sudah diterima';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'returnId',p_return_id,'expectedVersion',p_expected_version,
    'allocations',p_allocations)::text,'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':RETURN_CREDIT:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_credit_note_operation_retry(
    v_company,p_operation_id,'ALLOCATE_RETURN',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_return FROM public.backoffice_sales_returns document
  WHERE document.company_id=v_company AND document.id=p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RETURN_NOT_FOUND: dokumen Retur tidak ditemukan pada Company aktif'; END IF;
  IF v_return.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: dokumen Retur sudah berubah, muat ulang sebelum melanjutkan';
  END IF;
  IF v_return.status NOT IN('APPROVED','PARTIALLY_RECEIVED','RECEIVED','CREDIT_PENDING')
    OR v_return.total_received_base_qty<=0 THEN
    RAISE EXCEPTION 'RETURN_NOT_READY_FOR_INVOICE_RECONCILIATION: Gudang harus mem-posting penerimaan Retur terlebih dahulu';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_INVOICE_ORDER:'||v_return.sales_order_id::text,0));
  PERFORM 1 FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=v_return.sales_order_id
  ORDER BY line.line_no FOR UPDATE;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    BEGIN
      v_type:=upper(btrim(v_item->>'allocationType'));
      v_qty_uom:=round((v_item->>'quantityUom')::numeric,6);
      SELECT * INTO STRICT v_receipt_line
      FROM public.backoffice_sales_return_receipt_lines line
      WHERE line.company_id=v_company AND line.id=(v_item->>'returnReceiptLineId')::uuid
        AND line.return_id=p_return_id;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_LINE_INVALID: pilih baris penerimaan Retur dan qty yang valid';
    END;
    IF v_type NOT IN('UNINVOICED','DRAFT_INVOICE','POSTED_INVOICE')
      OR v_qty_uom<=0 THEN
      RAISE EXCEPTION 'RETURN_INVOICE_ALLOCATION_TYPE_INVALID: pilih Belum Ditagih, Draft Invoice, atau Posted Invoice';
    END IF;
    v_qty_base:=round(v_qty_uom*v_receipt_line.base_qty_per_uom,6);
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_used
    FROM public.backoffice_sales_return_invoice_allocations allocation
    WHERE allocation.company_id=v_company
      AND allocation.return_receipt_line_id=v_receipt_line.id;
    IF v_used+v_qty_base>v_receipt_line.received_base_qty THEN
      RAISE EXCEPTION 'RETURN_RECEIPT_QUANTITY_ALREADY_ALLOCATED: jumlah pembagian melebihi qty yang diterima Gudang';
    END IF;
    -- receipt.return_line_id points to Return line, resolve canonical SO line.
    SELECT source.* INTO STRICT v_order_line
    FROM public.backoffice_sales_return_lines return_line
    JOIN public.backoffice_sales_order_lines source
      ON source.company_id=return_line.company_id AND source.id=return_line.sales_order_line_id
    WHERE return_line.company_id=v_company AND return_line.id=v_receipt_line.return_line_id;

    IF v_type='UNINVOICED' THEN
      IF v_qty_base>v_order_line.to_invoice_base_qty THEN
        RAISE EXCEPTION 'UNINVOICED_RETURN_QUANTITY_NOT_AVAILABLE: qty belum ditagih tidak mencukupi';
      END IF;
      UPDATE public.backoffice_sales_order_lines SET
        returned_before_invoice_base_qty=returned_before_invoice_base_qty+v_qty_base,
        updated_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_order_line.id;
      INSERT INTO public.backoffice_sales_return_invoice_allocations(company_id,return_id,
        return_receipt_line_id,sales_order_line_id,allocation_type,allocated_base_qty,
        operation_id,actor_id)
      VALUES(v_company,p_return_id,v_receipt_line.id,v_order_line.id,v_type,
        v_qty_base,p_operation_id,v_actor);
      CONTINUE;
    END IF;

    BEGIN
      SELECT invoice.* INTO STRICT v_invoice
      FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=v_company AND invoice.id=(v_item->>'invoiceId')::uuid
        AND invoice.sales_order_id=v_return.sales_order_id FOR UPDATE;
      SELECT line.* INTO STRICT v_invoice_line
      FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.id=(v_item->>'invoiceLineId')::uuid
        AND line.invoice_id=v_invoice.id AND line.sales_order_line_id=v_order_line.id
        AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER';
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'RETURN_SOURCE_INVOICE_LINE_INVALID: Invoice dan baris Product harus berasal dari SO Retur yang sama';
    END;
    IF v_type='DRAFT_INVOICE' THEN
      IF v_invoice.status<>'DRAFT' THEN
        RAISE EXCEPTION 'DRAFT_INVOICE_REQUIRED: tujuan yang dipilih bukan Draft Invoice';
      END IF;
      SELECT * INTO v_alloc FROM public.backoffice_sales_invoice_quantity_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.invoice_line_id=v_invoice_line.id
        AND allocation.status='HELD' FOR UPDATE;
      IF NOT FOUND OR v_qty_base>v_alloc.allocated_base_qty THEN
        RAISE EXCEPTION 'DRAFT_INVOICE_RETURN_QUANTITY_EXCEEDS_LINE: qty Retur melebihi qty Draft Invoice';
      END IF;
      v_before:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
      v_ratio:=v_qty_base/v_invoice_line.quantity_base;
      v_discount:=CASE WHEN v_qty_base=v_invoice_line.quantity_base
        THEN v_invoice_line.discount_amount ELSE round(v_invoice_line.discount_amount*v_ratio,4) END;
      v_tax:=CASE WHEN v_qty_base=v_invoice_line.quantity_base
        THEN v_invoice_line.tax_amount ELSE round(v_invoice_line.tax_amount*v_ratio,4) END;
      v_line_amount:=CASE WHEN v_qty_base=v_invoice_line.quantity_base
        THEN v_invoice_line.line_amount ELSE round(v_invoice_line.line_amount*v_ratio,4) END;
      IF v_qty_base=v_invoice_line.quantity_base THEN
        DELETE FROM public.backoffice_sales_invoice_quantity_allocations
        WHERE company_id=v_company AND id=v_alloc.id;
        DELETE FROM public.backoffice_sales_invoice_lines
        WHERE company_id=v_company AND id=v_invoice_line.id;
      ELSE
        UPDATE public.backoffice_sales_invoice_lines SET
          quantity_uom=round((quantity_base-v_qty_base)/base_qty_per_uom,6),
          quantity_base=quantity_base-v_qty_base,
          discount_amount=discount_amount-v_discount,
          tax_amount=tax_amount-v_tax,line_amount=line_amount-v_line_amount,
          source_snapshot=source_snapshot||jsonb_build_object(
            'returnAdjusted',true,'lastReturnId',p_return_id)
        WHERE company_id=v_company AND id=v_invoice_line.id;
        UPDATE public.backoffice_sales_invoice_quantity_allocations
        SET allocated_base_qty=allocated_base_qty-v_qty_base,updated_at=clock_timestamp()
        WHERE company_id=v_company AND id=v_alloc.id;
      END IF;
      UPDATE public.backoffice_sales_order_lines SET
        draft_invoice_allocated_base_qty=draft_invoice_allocated_base_qty-v_qty_base,
        returned_before_invoice_base_qty=returned_before_invoice_base_qty+v_qty_base,
        updated_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_order_line.id;
      UPDATE public.backoffice_sales_invoices invoice SET
        charge_total=COALESCE((SELECT round(sum(line.line_amount+line.discount_amount),4)
          FROM public.backoffice_sales_invoice_lines line
          WHERE line.company_id=v_company AND line.invoice_id=invoice.id
            AND line.effect_type='CHARGE'),0),
        discount_total=COALESCE((SELECT round(sum(line.discount_amount),4)
          FROM public.backoffice_sales_invoice_lines line
          WHERE line.company_id=v_company AND line.invoice_id=invoice.id
            AND line.effect_type='CHARGE'),0),
        tax_total=COALESCE((SELECT round(sum(line.tax_amount),4)
          FROM public.backoffice_sales_invoice_lines line
          WHERE line.company_id=v_company AND line.invoice_id=invoice.id
            AND line.effect_type='CHARGE'),0),
        return_adjustment_pending_confirmation=true,return_adjusted_at=clock_timestamp(),
        master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
      WHERE invoice.company_id=v_company AND invoice.id=v_invoice.id;
      DELETE FROM public.backoffice_sales_invoice_receivable_schedules
      WHERE company_id=v_company AND invoice_id=v_invoice.id;
      IF (SELECT grand_total FROM public.backoffice_sales_invoices
          WHERE company_id=v_company AND id=v_invoice.id)>0 THEN
        PERFORM private.rebuild_backoffice_sales_invoice_schedules(v_company,v_invoice.id,v_actor);
      END IF;
      v_after:=private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id);
      v_invoice_op:=gen_random_uuid();
      INSERT INTO public.backoffice_sales_invoice_operations(company_id,operation_id,
        operation_type,invoice_id,expected_version,request_hash,response_snapshot,actor_id)
      VALUES(v_company,v_invoice_op,'RETURN_ADJUST_DRAFT',v_invoice.id,
        v_invoice.master_version,
        encode(extensions.digest(convert_to(jsonb_build_object('returnId',p_return_id,
          'returnOperationId',p_operation_id,'invoiceLineId',v_invoice_line.id,
          'quantityBase',v_qty_base)::text,'UTF8'),'sha256'),'hex'),
        jsonb_build_object('data',v_after,'returnId',p_return_id),v_actor);
      INSERT INTO public.backoffice_sales_invoice_audit(company_id,invoice_id,action,
        operation_id,actor_id,reason,before_state,after_state)
      VALUES(v_company,v_invoice.id,'RETURN_ADJUST_DRAFT',v_invoice_op,v_actor,
        'Qty disesuaikan dari Retur Customer '||v_return.return_no,v_before,v_after);
      INSERT INTO public.backoffice_sales_return_invoice_allocations(company_id,return_id,
        return_receipt_line_id,sales_order_line_id,allocation_type,invoice_id,
        invoice_line_id,allocated_base_qty,invoice_line_snapshot,operation_id,actor_id)
      VALUES(v_company,p_return_id,v_receipt_line.id,v_order_line.id,v_type,v_invoice.id,
        v_invoice_line.id,v_qty_base,to_jsonb(v_invoice_line),p_operation_id,v_actor);
      CONTINUE;
    END IF;

    IF v_invoice.status<>'POSTED' THEN
      RAISE EXCEPTION 'POSTED_INVOICE_REQUIRED: tujuan yang dipilih belum menjadi Posted Invoice';
    END IF;
    v_effective_identity:=private.backoffice_invoice_effective_identity(v_company,v_invoice.id,NULL);
    SELECT COALESCE(sum(allocation.allocated_base_qty),0) INTO v_used
    FROM public.backoffice_sales_return_invoice_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.invoice_line_id=v_invoice_line.id
      AND allocation.allocation_type='POSTED_INVOICE';
    IF v_used+v_qty_base>v_invoice_line.quantity_base THEN
      RAISE EXCEPTION 'POSTED_INVOICE_RETURN_QUANTITY_EXCEEDS_LINE: koreksi kumulatif melebihi qty Invoice';
    END IF;
    SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
    WHERE note.company_id=v_company AND note.return_id=p_return_id
      AND note.source_invoice_id=v_invoice.id AND note.status='DRAFT' FOR UPDATE;
    IF NOT FOUND THEN
      v_note_id:=gen_random_uuid();
      INSERT INTO public.backoffice_sales_credit_notes(id,company_id,return_id,
        source_invoice_id,customer_id,store_id,warehouse_id,credit_note_no,
        credit_note_date,currency_code,reason,source_invoice_snapshot,created_by,updated_by,
        charge_total,discount_total,tax_total,delivery_fee_amount,grand_total)
      VALUES(v_note_id,v_company,p_return_id,v_invoice.id,(v_effective_identity->>'customerId')::uuid,
        v_invoice.store_id,v_invoice.warehouse_id,
        'CN-'||to_char((clock_timestamp() AT TIME ZONE (SELECT timezone FROM public.companies
          WHERE id=v_company))::date,'YYYYMMDD')||'-'||
          lpad(nextval('private.backoffice_sales_credit_note_no_seq')::text,10,'0'),
        (clock_timestamp() AT TIME ZONE (SELECT timezone FROM public.companies
          WHERE id=v_company))::date,v_invoice.currency_code,
        'Retur Customer '||v_return.return_no,
        private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id)||jsonb_build_object(
          'effectiveIdentity',v_effective_identity),v_actor,v_actor,
        0,0,0,0,0);
      SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.id=v_note_id FOR UPDATE;
    ELSE
      v_note_id:=v_note.id;
      UPDATE public.backoffice_sales_credit_notes SET
        master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
      WHERE company_id=v_company AND id=v_note_id
      RETURNING * INTO v_note;
    END IF;
    SELECT COALESCE(max(line_no),0)+1 INTO v_line_no
    FROM public.backoffice_sales_credit_note_lines
    WHERE company_id=v_company AND credit_note_id=v_note_id;
    v_effective_line:=private.backoffice_invoice_effective_line_amounts(
      v_company,v_invoice_line.id);
    v_ratio:=v_qty_base/v_invoice_line.quantity_base;
    SELECT round(COALESCE(sum(line.line_amount+line.discount_amount),0),4),
      round(COALESCE(sum(line.discount_amount),0),4),
      round(COALESCE(sum(line.tax_amount),0),4),
      round(COALESCE(sum(line.line_amount),0),4)
    INTO v_prior,v_discount,v_tax,v_line_amount
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.source_invoice_line_id=v_invoice_line.id;
    v_charge:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN (v_effective_line->>'chargeAmount')::numeric-v_prior
      ELSE round((v_effective_line->>'chargeAmount')::numeric*v_ratio,4) END;
    v_discount:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN (v_effective_line->>'discountAmount')::numeric-v_discount
      ELSE round((v_effective_line->>'discountAmount')::numeric*v_ratio,4) END;
    v_tax:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN (v_effective_line->>'taxAmount')::numeric-v_tax
      ELSE round((v_effective_line->>'taxAmount')::numeric*v_ratio,4) END;
    v_line_amount:=v_charge-v_discount;
    INSERT INTO public.backoffice_sales_credit_note_lines(company_id,credit_note_id,
      return_id,return_receipt_line_id,sales_order_line_id,source_invoice_line_id,
      line_no,product_id,uom_id,quantity_uom,base_qty_per_uom,quantity_base,
      unit_price,discount_amount,tax_amount,line_amount,source_snapshot)
    VALUES(v_company,v_note_id,p_return_id,v_receipt_line.id,v_order_line.id,
      v_invoice_line.id,v_line_no,v_invoice_line.product_id,v_invoice_line.uom_id,
      v_qty_uom,v_invoice_line.base_qty_per_uom,v_qty_base,
      round((v_line_amount+v_discount)/v_qty_uom,4),v_discount,v_tax,v_line_amount,
      v_invoice_line.source_snapshot||jsonb_build_object('sourceInvoiceId',v_invoice.id,
        'sourceInvoiceNo',v_invoice.invoice_no,'sourceInvoiceLineId',v_invoice_line.id,
        'effectiveEnteredUnitPrice',(v_effective_line->>'enteredUnitPrice')::numeric,
        'priceCorrectionRevision',(v_effective_line->>'priceRevision')::bigint));
    PERFORM private.recalculate_backoffice_sales_credit_note(v_company,v_note_id,v_actor);
    UPDATE public.backoffice_sales_order_lines SET
      returned_after_invoice_base_qty=returned_after_invoice_base_qty+v_qty_base,
      updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_order_line.id;
    INSERT INTO public.backoffice_sales_return_invoice_allocations(company_id,return_id,
      return_receipt_line_id,sales_order_line_id,allocation_type,invoice_id,
      invoice_line_id,credit_note_id,allocated_base_qty,invoice_line_snapshot,
      operation_id,actor_id)
    VALUES(v_company,p_return_id,v_receipt_line.id,v_order_line.id,v_type,v_invoice.id,
      v_invoice_line.id,v_note_id,v_qty_base,to_jsonb(v_invoice_line),p_operation_id,v_actor);
  END LOOP;

  SELECT NOT EXISTS(
    SELECT 1 FROM public.backoffice_sales_return_receipt_lines receipt_line
    WHERE receipt_line.company_id=v_company AND receipt_line.return_id=p_return_id
      AND receipt_line.received_base_qty>COALESCE((SELECT sum(allocation.allocated_base_qty)
        FROM public.backoffice_sales_return_invoice_allocations allocation
        WHERE allocation.company_id=receipt_line.company_id
          AND allocation.return_receipt_line_id=receipt_line.id),0)
  ) INTO v_all_received;
  SELECT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
    WHERE note.company_id=v_company AND note.return_id=p_return_id AND note.status='DRAFT')
  INTO v_has_draft_notes;
  UPDATE public.backoffice_sales_returns SET
    status=CASE WHEN v_all_received AND v_has_draft_notes THEN 'CREDIT_PENDING'
      WHEN v_all_received THEN 'COMPLETED' ELSE status END,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=p_return_id RETURNING * INTO v_return;
  v_response:=jsonb_build_object('companyId',v_company,'returnId',p_return_id,
    'returnStatus',v_return.status,'masterVersion',v_return.master_version,
    'allReceivedQuantityAllocated',v_all_received,
    'creditNotes',COALESCE((SELECT jsonb_agg(
      private.backoffice_sales_credit_note_snapshot(v_company,note.id)
      ORDER BY note.created_at,note.id)
      FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.return_id=p_return_id),'[]'::jsonb),
    'exactRetry',false);
  INSERT INTO public.backoffice_sales_credit_note_operations(company_id,operation_id,
    operation_type,return_id,request_hash,response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'ALLOCATE_RETURN',p_return_id,v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,after_state)
  VALUES(v_company,p_return_id,NULL,p_operation_id,'ALLOCATE_RETURN',v_actor,
    jsonb_build_object('returnId',p_return_id,'returnStatus',v_return.status,
      'masterVersion',v_return.master_version,'allocationCount',jsonb_array_length(p_allocations),
      'allReceivedQuantityAllocated',v_all_received));
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,after_state)
  SELECT v_company,p_return_id,note.id,p_operation_id,'ALLOCATE_RETURN',v_actor,
    private.backoffice_sales_credit_note_snapshot(v_company,note.id)
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.return_id=p_return_id AND note.status='DRAFT';
  RETURN v_response;
END
$function$;

CREATE OR REPLACE FUNCTION private.post_backoffice_sales_credit_note_before_retained(p_credit_note_id uuid, p_expected_version bigint, p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET statement_timeout TO '15s'
AS $function$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_note public.backoffice_sales_credit_notes%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;v_event public.financial_events%rowtype;
  v_period public.accounting_periods%rowtype;v_journal public.finance_journals%rowtype;
  v_category uuid;v_hash text;v_retry jsonb;v_before jsonb;v_after jsonb;v_response jsonb;
  v_paid numeric(24,4);v_prior_credit numeric(24,4);v_outstanding numeric(24,4);
  v_ar numeric(24,4);v_refund numeric(24,4);v_net numeric(24,4);
  v_account uuid;v_tax record;v_line_no integer:=0;v_journal_type text:='AUTOMATIC';
  v_accounting_date date;v_event_at timestamptz;v_timezone text;
  v_company_today date;v_latest_payment_date date;v_effective_identity jsonb;
  v_effective_total numeric(24,4);
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'finance.customer_credit_notes','POST');
  IF p_credit_note_id IS NULL OR p_expected_version IS NULL OR p_operation_id IS NULL THEN
    RAISE EXCEPTION 'CREDIT_NOTE_POST_INPUT_INVALID: pilih Draft Credit Note yang akan diposting';
  END IF;
  v_hash:=encode(extensions.digest(convert_to(jsonb_build_object(
    'creditNoteId',p_credit_note_id,'expectedVersion',p_expected_version)::text,
    'UTF8'),'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':CREDIT_NOTE:'||p_operation_id::text,0));
  v_retry:=private.backoffice_sales_credit_note_operation_retry(
    v_company,p_operation_id,'POST',v_hash);
  IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
  SELECT * INTO v_note FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.id=p_credit_note_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_FOUND: dokumen tidak ditemukan pada Company aktif'; END IF;
  IF v_note.status<>'DRAFT' THEN RAISE EXCEPTION 'CREDIT_NOTE_NOT_POSTABLE: hanya Draft Credit Note yang dapat diposting'; END IF;
  IF v_note.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT: Credit Note sudah berubah, muat ulang sebelum posting';
  END IF;
  SELECT * INTO STRICT v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=v_note.source_invoice_id
    AND invoice.status='POSTED' FOR UPDATE;
  v_effective_identity:=private.backoffice_invoice_effective_identity(v_company,v_invoice.id,NULL);
  v_effective_total:=private.backoffice_invoice_effective_total(v_company,v_invoice.id,NULL);
  IF v_note.customer_id<>(v_effective_identity->>'customerId')::uuid THEN
    RAISE EXCEPTION 'CREDIT_NOTE_INVOICE_IDENTITY_CHANGED: batalkan Draft Credit Note lalu alokasikan ulang Retur';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.credit_note_id=v_note.id) THEN
    RAISE EXCEPTION 'CREDIT_NOTE_LINES_REQUIRED: Credit Note belum mempunyai alokasi Product';
  END IF;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_timezone,v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF v_note.credit_note_date>v_company_today THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_FUTURE: tanggal Credit Note tidak boleh melewati tanggal Company';
  END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4),max(receipt.receipt_date)
  INTO v_paid,v_latest_payment_date
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id;
  IF v_latest_payment_date IS NOT NULL AND v_latest_payment_date>v_note.credit_note_date THEN
    RAISE EXCEPTION 'CREDIT_NOTE_DATE_BEFORE_PAYMENT: tanggal Credit Note harus sama atau setelah pembayaran terakhir Invoice';
  END IF;
  SELECT round(COALESCE(sum(other.grand_total),0),4) INTO v_prior_credit
  FROM public.backoffice_sales_credit_notes other
  WHERE other.company_id=v_company AND other.source_invoice_id=v_invoice.id
    AND other.status='POSTED';
  IF v_prior_credit+v_note.grand_total>v_effective_total THEN
    RAISE EXCEPTION 'CREDIT_NOTE_AMOUNT_EXCEEDS_INVOICE: koreksi kumulatif melebihi nilai Invoice sumber';
  END IF;
  v_outstanding:=greatest(0,round(v_effective_total-v_paid-v_prior_credit,4));
  v_ar:=least(v_note.grand_total,v_outstanding);v_refund:=v_note.grand_total-v_ar;
  v_event_at:=(v_note.credit_note_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_company AND v_note.credit_note_date
    BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=v_company AND period.start_date>v_note.credit_note_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND: buka periode Credit Note atau periode penyesuaian berikutnya';
    END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_note.credit_note_date; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='CUSTOMER_CREDIT_NOTE'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  IF v_category IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_CREDIT_NOTE_CATEGORY_REQUIRED: aktifkan kategori transaksi Credit Note Customer';
  END IF;
  v_before:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,amounts,status,error_message,created_by,company_id,
    store_id,system_event_key,transaction_category_id,transaction_rule_version)
  VALUES('BO-CN-'||replace(v_note.id::text,'-',''),'SALE_REVISED'::public.event_type,
    'backoffice_sales_credit_notes',v_note.id,v_event_at,1,
    'BACKOFFICE_CREDIT_NOTE|'||v_company||'|'||v_note.id||'|'||p_operation_id,
    jsonb_build_object('creditNoteId',v_note.id,'returnId',v_note.return_id,
      'sourceInvoiceId',v_invoice.id,'grandTotal',v_note.grand_total,
      'arReductionAmount',v_ar,'refundLiabilityAmount',v_refund,
      'financePostingState','HOLD'),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,
    v_company,v_note.store_id,'CUSTOMER_CREDIT_NOTE',v_category,20260917131000)
  RETURNING * INTO v_event;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(v_company,'CNJ-'||replace(v_note.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_note.credit_note_date,
    'backoffice_sales_credit_notes',v_note.id,v_note.master_version,v_event.id,
    'BACKOFFICE_CREDIT_NOTE_JOURNAL|'||v_company||'|'||v_note.id,
    'CUSTOMER_CREDIT_NOTE',v_category,20260917131000,v_note.store_id,
    v_note.warehouse_id,'Credit Note Customer '||v_note.credit_note_no,'DRAFT',v_actor)
  RETURNING * INTO v_journal;
  v_net:=round(v_note.charge_total-v_note.discount_total,4);
  IF v_net>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'SALES_RETURN_DISCOUNT');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,v_net,0,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Retur dan potongan penjualan');
  END IF;
  FOR v_tax IN SELECT (line.source_snapshot->>'taxAccountId')::uuid account_id,
      sum(line.tax_amount) amount
    FROM public.backoffice_sales_credit_note_lines line
    WHERE line.company_id=v_company AND line.credit_note_id=v_note.id
      AND line.tax_amount>0
    GROUP BY (line.source_snapshot->>'taxAccountId')::uuid
  LOOP
    IF v_tax.account_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.id=v_tax.account_id
        AND account.is_active AND account.is_postable) THEN
      RAISE EXCEPTION 'CREDIT_NOTE_SOURCE_TAX_ACCOUNT_INVALID: snapshot Pajak Invoice tidak dapat diposting';
    END IF;
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_tax.account_id,v_tax.amount,0,
      v_note.store_id,v_note.warehouse_id,v_note.customer_id,'Pembalik Pajak Keluaran');
  END LOOP;
  IF v_note.delivery_fee_amount>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'DELIVERY_FEE_REVENUE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,v_note.delivery_fee_amount,0,
      v_note.store_id,v_note.warehouse_id,v_note.customer_id,'Koreksi ongkir');
  END IF;
  IF v_ar>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,0,v_ar,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Pengurang Piutang Customer');
  END IF;
  IF v_refund>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,0,v_refund,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Utang Refund Customer');
  END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp() WHERE company_id=v_company AND id=v_journal.id
    RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>round(v_note.grand_total,4)
    OR round(v_journal.total_credit,4)<>round(v_note.grand_total,4) THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED: nilai debit dan kredit Credit Note tidak seimbang';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,
    transaction_rule_version=20260917131000
  WHERE company_id=v_company AND id=v_event.id;
  UPDATE public.backoffice_sales_credit_notes SET status='POSTED',
    ar_reduction_amount=v_ar,refund_liability_amount=v_refund,
    financial_event_id=v_event.id,posted_by=v_actor,posted_at=clock_timestamp(),
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_note.id;
  PERFORM private.reconcile_backoffice_invoice_receivable_schedule(v_company,v_invoice.id);
  UPDATE public.backoffice_sales_returns document SET
    status=CASE WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=v_company AND note.return_id=document.id
            AND note.status='DRAFT') THEN 'CREDIT_PENDING'
      WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
          WHERE note.company_id=v_company AND note.return_id=document.id
            AND note.status='POSTED' AND note.refund_liability_amount>0)
        THEN 'REFUND_PENDING' ELSE 'COMPLETED' END,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE document.company_id=v_company AND document.id=v_note.return_id;
  v_after:=private.backoffice_sales_credit_note_snapshot(v_company,v_note.id);
  v_response:=jsonb_build_object('companyId',v_company,'data',v_after,
    'finance',jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'accountingDate',v_journal.accounting_date,
      'journalType',v_journal.journal_type),
    'exactRetry',false);
  INSERT INTO public.backoffice_sales_credit_note_operations(company_id,operation_id,
    operation_type,return_id,credit_note_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_company,p_operation_id,'POST',v_note.return_id,v_note.id,p_expected_version,
    v_hash,v_response,v_actor);
  INSERT INTO public.backoffice_sales_credit_note_audit(company_id,return_id,
    credit_note_id,operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_note.return_id,v_note.id,p_operation_id,'POST',v_actor,v_before,v_after);
  RETURN v_response;
END
$function$;
-- END supabase/staging/backoffice_invoice_revision_return_consumers.sql

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261006140000','backoffice_unified_posted_invoice_revision',
  'KMS/LSM/SMS Posted Regular Backoffice Invoice correction for billing Customer, Invoice date, price and discount; append-only revision/journals, effective UI/payment/AR/statement/export/Return consumers; source SO/DO/Invoice/Stock/FIFO immutable; payment-error correction and payout remain separate canonical workflows');
NOTIFY pgrst,'reload schema';
COMMIT;
