BEGIN;

DO $guard$
DECLARE v_company record;v_category uuid;v_function text;v_account uuid;
  v_signature text;v_relation text;v_missing text[]:=ARRAY[]::text[];
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'private.kgs_schema_migrations','public.companies','public.profiles',
    'public.products','public.uoms','public.stores','public.chart_of_accounts',
    'public.system_events','public.transaction_categories','public.accounting_periods',
    'public.backoffice_sales_invoices','public.backoffice_sales_invoice_lines',
    'public.backoffice_sales_invoice_receivable_schedules','public.backoffice_sales_credit_notes',
    'public.backoffice_sales_customer_refunds','public.customer_receipt_documents',
    'public.customer_receipt_backoffice_invoice_allocations','public.financial_events',
    'public.finance_journals','public.finance_journal_lines','public.finance_posting_queue_runs',
    'public.pos_offline_sale_submissions'
  ]::text[] LOOP
    IF to_regclass(v_relation) IS NULL THEN v_missing:=array_append(v_missing,'relation:'||v_relation); END IF;
  END LOOP;
  FOREACH v_signature IN ARRAY ARRAY[
    'public.private_active_company_id()',
    'private.acp_require_permission_capability(uuid,text,text)',
    'private.require_backoffice_sales_invoice_post_permission(uuid)',
    'private.calculate_tax_group(jsonb,numeric,text,text,text)',
    'private.resolve_financial_event_account(public.financial_events,text)',
    'private.resolve_opening_stock_account(uuid,uuid,text,timestamp with time zone)',
    'private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid)',
    'private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)',
    'private.backoffice_sales_invoice_snapshot(uuid,uuid)',
    'private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)',
    'private.backoffice_sales_credit_note_refunded_amount(uuid,uuid)',
    'public.get_backoffice_sales_invoice_payment_context(uuid)',
    'public.get_finance_customer_receipts()',
    'public.get_finance_customer_statement(uuid,date,date,uuid)',
    'public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)'
  ]::text[] LOOP
    IF to_regprocedure(v_signature) IS NULL THEN v_missing:=array_append(v_missing,v_signature); END IF;
  END LOOP;
  IF cardinality(v_missing)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical runtime missing [%]',
      array_to_string(v_missing,', ');
  END IF;
  IF to_regclass('public.backoffice_sales_invoice_price_corrections') IS NOT NULL
    OR to_regclass('public.backoffice_sales_invoice_price_correction_lines') IS NOT NULL
    OR to_regclass('public.backoffice_sales_invoice_price_correction_operations') IS NOT NULL
    OR to_regclass('private.backoffice_sales_invoice_price_correction_no_seq') IS NOT NULL
    OR to_regprocedure('public.post_backoffice_sales_invoice_price_correction(uuid,bigint,bigint,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('public.get_backoffice_sales_invoice_price_correction_context(uuid)') IS NOT NULL
    OR to_regprocedure('private.backoffice_sales_invoice_ui_snapshot_before_price_correction(uuid,uuid)') IS NOT NULL
    OR EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260928110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: price-correction objects already exist';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version IN(
      '20260911163000','20260917131000','20260917150000','20260918150000',
      '20260919110000','20260925100000'))<>6 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: dependency ledger incomplete';
  END IF;
  IF (SELECT count(*) FROM public.system_events
      WHERE system_key IN('CUSTOMER_DEBIT_NOTE','CUSTOMER_CREDIT_NOTE'))<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Debit/Credit Note catalog missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF (SELECT count(*) FROM public.companies WHERE status='ACTIVE' AND id IN(
      '4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact KMS/LSM/SMS identity required';
  END IF;
  FOR v_company IN SELECT id FROM public.companies WHERE status='ACTIVE' AND id IN(
      '4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)
  LOOP
    FOREACH v_function IN ARRAY ARRAY['CUSTOMER_RECEIVABLE','SALES_REVENUE',
      'CUSTOMER_REFUND_LIABILITY']::text[] LOOP
      SELECT category.id INTO v_category FROM public.transaction_categories category
      WHERE category.company_id=v_company.id AND category.system_key='CUSTOMER_DEBIT_NOTE'
        AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
      v_account:=private.resolve_opening_stock_account(v_company.id,v_category,v_function,clock_timestamp());
      IF v_account IS NULL THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Debit Note mapping % / %',v_company.id,v_function; END IF;
    END LOOP;
    FOREACH v_function IN ARRAY ARRAY['CUSTOMER_RECEIVABLE','SALES_RETURN_DISCOUNT','CUSTOMER_REFUND_LIABILITY']::text[] LOOP
      SELECT category.id INTO v_category FROM public.transaction_categories category
      WHERE category.company_id=v_company.id AND category.system_key='CUSTOMER_CREDIT_NOTE'
        AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
      v_account:=private.resolve_opening_stock_account(v_company.id,v_category,v_function,clock_timestamp());
      IF v_account IS NULL THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Credit Note mapping % / %',v_company.id,v_function; END IF;
    END LOOP;
  END LOOP;
END
$guard$;

UPDATE public.system_events SET conditional_account_functions=(
  SELECT ARRAY(SELECT DISTINCT value FROM unnest(
    conditional_account_functions||ARRAY['CUSTOMER_REFUND_LIABILITY']) value ORDER BY value))
WHERE system_key='CUSTOMER_DEBIT_NOTE';

CREATE SEQUENCE private.backoffice_sales_invoice_price_correction_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.backoffice_sales_invoice_price_correction_no_seq
  FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.backoffice_sales_invoice_price_correction_no_seq TO service_role;

CREATE TABLE public.backoffice_sales_invoice_price_corrections(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  source_invoice_id uuid NOT NULL,
  correction_no text NOT NULL,
  correction_kind text NOT NULL,
  status text NOT NULL DEFAULT 'POSTED',
  correction_at timestamptz NOT NULL,
  correction_date date NOT NULL,
  prior_effective_total numeric(24,4) NOT NULL,
  corrected_effective_total numeric(24,4) NOT NULL,
  revenue_delta numeric(24,4) NOT NULL,
  tax_delta numeric(24,4) NOT NULL,
  total_delta numeric(24,4) NOT NULL,
  ar_adjustment_amount numeric(24,4) NOT NULL DEFAULT 0,
  refund_liability_amount numeric(24,4) NOT NULL DEFAULT 0,
  financial_event_id uuid,
  source_invoice_version bigint NOT NULL,
  source_invoice_snapshot jsonb NOT NULL,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_invoice_price_corrections_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_invoice_price_corrections_number_unique UNIQUE(company_id,correction_no),
  CONSTRAINT backoffice_invoice_price_corrections_event_unique UNIQUE(company_id,financial_event_id),
  CONSTRAINT backoffice_invoice_price_corrections_invoice_fk
    FOREIGN KEY(company_id,source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_corrections_event_fk
    FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_corrections_shape CHECK(
    correction_kind IN('DEBIT_NOTE','CREDIT_NOTE') AND status='POSTED'
    AND prior_effective_total>0 AND corrected_effective_total>0
    AND total_delta<>0 AND corrected_effective_total=prior_effective_total+total_delta
    AND total_delta=revenue_delta+tax_delta
    AND total_delta=ar_adjustment_amount-refund_liability_amount
    AND source_invoice_version>0 AND jsonb_typeof(source_invoice_snapshot)='object'
    AND financial_event_id IS NOT NULL
    AND ((correction_kind='DEBIT_NOTE' AND total_delta>0
          AND ar_adjustment_amount>=0 AND refund_liability_amount<=0)
      OR (correction_kind='CREDIT_NOTE' AND total_delta<0
          AND ar_adjustment_amount<=0 AND refund_liability_amount>=0)))
);

CREATE TABLE public.backoffice_sales_invoice_price_correction_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  correction_id uuid NOT NULL,
  source_invoice_id uuid NOT NULL,
  source_invoice_line_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  uom_id uuid NOT NULL,
  quantity_uom numeric(24,6) NOT NULL,
  old_entered_unit_price numeric(24,4) NOT NULL,
  new_entered_unit_price numeric(24,4) NOT NULL,
  discount_amount numeric(24,4) NOT NULL,
  old_revenue_amount numeric(24,4) NOT NULL,
  new_revenue_amount numeric(24,4) NOT NULL,
  old_tax_amount numeric(24,4) NOT NULL,
  new_tax_amount numeric(24,4) NOT NULL,
  revenue_delta numeric(24,4) NOT NULL,
  tax_delta numeric(24,4) NOT NULL,
  total_delta numeric(24,4) NOT NULL,
  tax_account_id uuid,
  source_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_invoice_price_correction_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_invoice_price_correction_lines_number_unique UNIQUE(company_id,correction_id,line_no),
  CONSTRAINT backoffice_invoice_price_correction_lines_source_unique UNIQUE(company_id,correction_id,source_invoice_line_id),
  CONSTRAINT backoffice_invoice_price_correction_lines_header_fk
    FOREIGN KEY(company_id,correction_id)
    REFERENCES public.backoffice_sales_invoice_price_corrections(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_lines_invoice_fk
    FOREIGN KEY(company_id,source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_lines_source_line_fk
    FOREIGN KEY(company_id,source_invoice_line_id)
    REFERENCES public.backoffice_sales_invoice_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_lines_product_fk FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_lines_uom_fk FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_lines_tax_account_fk FOREIGN KEY(company_id,tax_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_lines_shape CHECK(
    line_no>0 AND quantity_uom>0 AND old_entered_unit_price>=0 AND new_entered_unit_price>=0
    AND old_entered_unit_price<>new_entered_unit_price AND discount_amount>=0
    AND old_revenue_amount>=0 AND new_revenue_amount>=0
    AND old_tax_amount>=0 AND new_tax_amount>=0
    AND revenue_delta=new_revenue_amount-old_revenue_amount
    AND tax_delta=new_tax_amount-old_tax_amount
    AND total_delta=revenue_delta+tax_delta
    AND jsonb_typeof(source_snapshot)='object')
);

CREATE TABLE public.backoffice_sales_invoice_price_correction_operations(
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  source_invoice_id uuid NOT NULL,
  correction_id uuid,
  expected_invoice_version bigint NOT NULL,
  expected_price_revision bigint NOT NULL,
  request_snapshot jsonb NOT NULL,
  response_snapshot jsonb,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  completed_at timestamptz,
  PRIMARY KEY(company_id,operation_id),
  CONSTRAINT backoffice_invoice_price_correction_operations_invoice_fk
    FOREIGN KEY(company_id,source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_operations_correction_fk
    FOREIGN KEY(company_id,correction_id)
    REFERENCES public.backoffice_sales_invoice_price_corrections(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_invoice_price_correction_operations_shape CHECK(
    expected_invoice_version>0 AND expected_price_revision>=0
    AND jsonb_typeof(request_snapshot)='object'
    AND (response_snapshot IS NULL OR jsonb_typeof(response_snapshot)='object')
    AND ((completed_at IS NULL AND correction_id IS NULL AND response_snapshot IS NULL)
      OR (completed_at IS NOT NULL AND correction_id IS NOT NULL AND response_snapshot IS NOT NULL)))
);

ALTER TABLE public.backoffice_sales_invoice_receivable_schedules
  ADD COLUMN original_amount_due numeric(24,4);
UPDATE public.backoffice_sales_invoice_receivable_schedules
SET original_amount_due=amount_due WHERE original_amount_due IS NULL;
ALTER TABLE public.backoffice_sales_invoice_receivable_schedules
  ALTER COLUMN original_amount_due SET NOT NULL;
ALTER TABLE public.backoffice_sales_invoice_receivable_schedules
  ADD CONSTRAINT backoffice_sales_invoice_schedules_original_amount_check
  CHECK(original_amount_due>0);

CREATE INDEX backoffice_invoice_price_corrections_source
  ON public.backoffice_sales_invoice_price_corrections(company_id,source_invoice_id,posted_at,id);
CREATE INDEX backoffice_invoice_price_correction_lines_source
  ON public.backoffice_sales_invoice_price_correction_lines(company_id,source_invoice_id,source_invoice_line_id);

ALTER TABLE public.backoffice_sales_invoice_price_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_invoice_price_correction_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_invoice_price_correction_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_invoice_price_corrections,
  public.backoffice_sales_invoice_price_correction_lines,
  public.backoffice_sales_invoice_price_correction_operations
  FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.backoffice_sales_invoice_price_corrections,
  public.backoffice_sales_invoice_price_correction_lines,
  public.backoffice_sales_invoice_price_correction_operations TO service_role;

CREATE FUNCTION private.trg_guard_backoffice_invoice_price_correction_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'POSTED_INVOICE_PRICE_CORRECTION_IMMUTABLE';
END
$$;
CREATE TRIGGER backoffice_invoice_price_corrections_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_invoice_price_corrections
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_invoice_price_correction_history();
CREATE TRIGGER backoffice_invoice_price_correction_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_invoice_price_correction_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_invoice_price_correction_history();

CREATE FUNCTION private.backoffice_invoice_price_delta(
  p_company_id uuid,p_invoice_id uuid,p_as_of date DEFAULT NULL
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT round(COALESCE(sum(correction.total_delta),0),4)
  FROM public.backoffice_sales_invoice_price_corrections correction
  WHERE correction.company_id=p_company_id AND correction.source_invoice_id=p_invoice_id
    AND correction.status='POSTED'
    AND (p_as_of IS NULL OR correction.correction_date<=p_as_of)
$$;

CREATE FUNCTION private.backoffice_invoice_effective_total(
  p_company_id uuid,p_invoice_id uuid,p_as_of date DEFAULT NULL
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT round(invoice.grand_total+
    private.backoffice_invoice_price_delta(invoice.company_id,invoice.id,p_as_of),4)
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

CREATE FUNCTION private.backoffice_invoice_effective_entered_unit_price(
  p_company_id uuid,p_invoice_line_id uuid
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT COALESCE((SELECT line.new_entered_unit_price
      FROM public.backoffice_sales_invoice_price_correction_lines line
      JOIN public.backoffice_sales_invoice_price_corrections correction
        ON correction.company_id=line.company_id AND correction.id=line.correction_id
       AND correction.status='POSTED'
      WHERE line.company_id=source.company_id AND line.source_invoice_line_id=source.id
      ORDER BY correction.posted_at DESC,correction.id DESC LIMIT 1),
    NULLIF(source.source_snapshot->>'enteredGrossUnitPrice','')::numeric,source.unit_price)
  FROM public.backoffice_sales_invoice_lines source
  WHERE source.company_id=p_company_id AND source.id=p_invoice_line_id
$$;

CREATE FUNCTION private.backoffice_invoice_effective_line_amounts(
  p_company_id uuid,p_invoice_line_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_line public.backoffice_sales_invoice_lines%rowtype;v_price numeric(24,4);
  v_gross numeric(24,4);v_dpp numeric(24,4);v_tax numeric(24,4);v_result jsonb;v_tax_line jsonb;
BEGIN
  SELECT * INTO v_line FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=p_company_id AND line.id=p_invoice_line_id;
  IF NOT FOUND OR v_line.line_type<>'PRODUCT' OR v_line.source_kind<>'SALES_ORDER' THEN
    RAISE EXCEPTION 'BACKOFFICE_INVOICE_EFFECTIVE_LINE_INVALID';
  END IF;
  v_price:=round(private.backoffice_invoice_effective_entered_unit_price(p_company_id,p_invoice_line_id),4);
  v_gross:=round(v_line.quantity_uom*v_price-v_line.discount_amount,4);
  IF v_gross<0 THEN RAISE EXCEPTION 'INVOICE_DISCOUNT_EXCEEDS_CORRECTED_LINE_TOTAL'; END IF;
  v_dpp:=v_gross;v_tax:=0;
  IF COALESCE((v_line.source_snapshot->>'taxApplied')::boolean,false) THEN
    IF v_line.source_snapshot->>'taxPriceMode'<>'INCLUSIVE'
      OR NULLIF(v_line.source_snapshot->>'taxRatePercent','') IS NULL
      OR NULLIF(v_line.source_snapshot->>'taxCalculationScope','') IS NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID';
    END IF;
    v_result:=private.calculate_tax_group(jsonb_build_array(
      jsonb_build_object('lineKey',v_line.id::text,'amount',v_gross)),
      (v_line.source_snapshot->>'taxRatePercent')::numeric,'SALES',
      v_line.source_snapshot->>'taxPriceMode',v_line.source_snapshot->>'taxCalculationScope');
    v_tax_line:=v_result->'lines'->0;
    v_dpp:=round((v_tax_line->>'taxBase')::numeric,4);
    v_tax:=round((v_tax_line->>'taxAmount')::numeric,4);
  END IF;
  RETURN jsonb_build_object('enteredUnitPrice',v_price,
    'chargeAmount',round(v_dpp+v_line.discount_amount,4),
    'discountAmount',v_line.discount_amount,'lineAmount',v_dpp,'taxAmount',v_tax,
    'priceRevision',(SELECT count(*) FROM public.backoffice_sales_invoice_price_correction_lines correction_line
      JOIN public.backoffice_sales_invoice_price_corrections correction
        ON correction.company_id=correction_line.company_id AND correction.id=correction_line.correction_id
       AND correction.status='POSTED'
      WHERE correction_line.company_id=p_company_id
        AND correction_line.source_invoice_line_id=p_invoice_line_id));
END
$$;

ALTER FUNCTION private.backoffice_sales_invoice_ui_snapshot(uuid,uuid)
  RENAME TO backoffice_sales_invoice_ui_snapshot_before_price_correction;
CREATE FUNCTION private.backoffice_sales_invoice_ui_snapshot(p_company_id uuid,p_invoice_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT private.backoffice_sales_invoice_ui_snapshot_before_price_correction(p_company_id,p_invoice_id)
    ||jsonb_build_object('priceCorrectionAmount',
        private.backoffice_invoice_price_delta(p_company_id,p_invoice_id,NULL),
      'effectiveGrandTotal',private.backoffice_invoice_effective_total(p_company_id,p_invoice_id,NULL),
      'priceRevision',(SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections correction
        WHERE correction.company_id=p_company_id AND correction.source_invoice_id=p_invoice_id
          AND correction.status='POSTED'))
$$;

CREATE OR REPLACE FUNCTION private.backoffice_invoice_receivable_before_receipts(
  p_company_id uuid,p_invoice_id uuid,p_as_of date
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN invoice.status='POSTED' AND invoice.invoice_date<=p_as_of THEN greatest(0,
    private.backoffice_invoice_effective_total(invoice.company_id,invoice.id,p_as_of)
    -COALESCE((SELECT sum(note.grand_total) FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=invoice.company_id AND note.source_invoice_id=invoice.id
        AND note.status='POSTED' AND note.credit_note_date<=p_as_of),0)) ELSE 0::numeric END
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id
$$;

CREATE FUNCTION private.rebuild_backoffice_invoice_effective_schedules(
  p_company_id uuid,p_invoice_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_total numeric(24,4);v_original numeric(24,4);v_assigned numeric(24,4):=0;
  v_count bigint;v_row bigint:=0;v_schedule record;v_amount numeric(24,4);
BEGIN
  v_total:=private.backoffice_invoice_effective_total(p_company_id,p_invoice_id,NULL);
  SELECT round(sum(original_amount_due),4),count(*) INTO v_original,v_count
  FROM public.backoffice_sales_invoice_receivable_schedules
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
  IF v_total<=0 OR v_original<=0 OR v_count=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_INVOICE_EFFECTIVE_SCHEDULE_INVALID';
  END IF;
  FOR v_schedule IN SELECT id,original_amount_due FROM public.backoffice_sales_invoice_receivable_schedules
    WHERE company_id=p_company_id AND invoice_id=p_invoice_id
    ORDER BY installment_no FOR UPDATE
  LOOP
    v_row:=v_row+1;
    v_amount:=CASE WHEN v_row=v_count THEN v_total-v_assigned
      ELSE round(v_total*v_schedule.original_amount_due/v_original,4) END;
    IF v_amount<=0 THEN RAISE EXCEPTION 'BACKOFFICE_INVOICE_EFFECTIVE_SCHEDULE_INVALID'; END IF;
    UPDATE public.backoffice_sales_invoice_receivable_schedules
    SET amount_due=v_amount,updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_schedule.id;
    v_assigned:=v_assigned+v_amount;
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION private.reconcile_backoffice_invoice_receivable_schedule(
  p_company_id uuid,p_invoice_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;v_paid numeric(24,4);
  v_credit numeric(24,4);v_effective numeric(24,4);v_remaining numeric(24,4);
  v_apply numeric(24,4);v_schedule record;
BEGIN
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND OR v_invoice.status<>'POSTED' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE';
  END IF;
  v_effective:=private.backoffice_invoice_effective_total(p_company_id,p_invoice_id,NULL);
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=p_company_id AND allocation.invoice_id=p_invoice_id;
  SELECT round(COALESCE(sum(note.ar_reduction_amount),0),4) INTO v_credit
  FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=p_company_id AND note.source_invoice_id=p_invoice_id AND note.status='POSTED';
  IF v_paid<0 OR v_credit<0 OR v_credit>v_effective THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_SETTLEMENT_RECONCILIATION_FAILED';
  END IF;
  PERFORM private.rebuild_backoffice_invoice_effective_schedules(p_company_id,p_invoice_id);
  UPDATE public.backoffice_sales_invoice_receivable_schedules
  SET allocated_payment_amount=0,credited_amount=0,status='OPEN',updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
  v_remaining:=least(v_paid,greatest(0,v_effective-v_credit));
  FOR v_schedule IN SELECT id,amount_due FROM public.backoffice_sales_invoice_receivable_schedules
    WHERE company_id=p_company_id AND invoice_id=p_invoice_id
    ORDER BY due_date,installment_no FOR UPDATE
  LOOP
    v_apply:=least(v_remaining,v_schedule.amount_due);
    UPDATE public.backoffice_sales_invoice_receivable_schedules
    SET allocated_payment_amount=v_apply,updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_schedule.id;
    v_remaining:=v_remaining-v_apply;
  END LOOP;
  IF v_remaining<>0 THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_OVER_ALLOCATION'; END IF;
  v_remaining:=v_credit;
  FOR v_schedule IN SELECT id,amount_due,allocated_payment_amount
    FROM public.backoffice_sales_invoice_receivable_schedules
    WHERE company_id=p_company_id AND invoice_id=p_invoice_id
    ORDER BY due_date,installment_no FOR UPDATE
  LOOP
    v_apply:=least(v_remaining,v_schedule.amount_due-v_schedule.allocated_payment_amount);
    UPDATE public.backoffice_sales_invoice_receivable_schedules
    SET credited_amount=v_apply,updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_schedule.id;
    v_remaining:=v_remaining-v_apply;
  END LOOP;
  IF v_remaining<>0 THEN RAISE EXCEPTION 'CREDIT_NOTE_AR_OVER_ALLOCATION'; END IF;
  UPDATE public.backoffice_sales_invoice_receivable_schedules SET status=CASE
      WHEN allocated_payment_amount+credited_amount=amount_due THEN 'PAID'
      WHEN allocated_payment_amount+credited_amount>0 THEN 'PARTIALLY_PAID' ELSE 'OPEN' END,
    updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
END
$$;

CREATE FUNCTION public.get_backoffice_sales_invoice_price_correction_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_invoice public.backoffice_sales_invoices%rowtype;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  RETURN jsonb_build_object('sourceInvoiceId',v_invoice.id,'originalTotal',v_invoice.grand_total,
    'effectiveTotal',private.backoffice_invoice_effective_total(v_company,v_invoice.id,NULL),
    'canCorrect',v_company IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)
      AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.source_invoice_id=v_invoice.id
        AND note.status IN('DRAFT','POSTED')),
    'blockedReason',CASE WHEN v_company NOT IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,'809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid)
      THEN 'COMPANY_NOT_ENABLED' WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.source_invoice_id=v_invoice.id
        AND note.status IN('DRAFT','POSTED')) THEN 'RETURN_CREDIT_NOTE_EXISTS' ELSE NULL END,
    'priceRevision',(SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections correction
      WHERE correction.company_id=v_company AND correction.source_invoice_id=v_invoice.id
        AND correction.status='POSTED'),
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object('invoiceLineId',line.id,
      'effectiveUnitPrice',private.backoffice_invoice_effective_entered_unit_price(v_company,line.id),
      'effectiveAmounts',private.backoffice_invoice_effective_line_amounts(v_company,line.id))
      ORDER BY line.line_no) FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
        AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'
        AND line.sales_order_line_id IS NOT NULL),'[]'::jsonb),
    'corrections',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',correction.id,
      'correctionNo',correction.correction_no,'kind',correction.correction_kind,
      'correctionAt',correction.correction_at,'correctionDate',correction.correction_date,
      'priorEffectiveTotal',correction.prior_effective_total,
      'correctedEffectiveTotal',correction.corrected_effective_total,
      'revenueDelta',correction.revenue_delta,'taxDelta',correction.tax_delta,
      'totalDelta',correction.total_delta,'arAdjustmentAmount',correction.ar_adjustment_amount,
      'refundLiabilityAmount',correction.refund_liability_amount,
      'journalNo',(SELECT journal.journal_no FROM public.finance_journals journal
        WHERE journal.company_id=correction.company_id
          AND journal.financial_event_id=correction.financial_event_id LIMIT 1))
      ORDER BY correction.posted_at,correction.id)
      FROM public.backoffice_sales_invoice_price_corrections correction
      WHERE correction.company_id=v_company AND correction.source_invoice_id=v_invoice.id
        AND correction.status='POSTED'),'[]'::jsonb));
END
$$;

CREATE FUNCTION public.post_backoffice_sales_invoice_price_correction(
  p_invoice_id uuid,p_expected_version bigint,p_expected_price_revision bigint,
  p_operation_id uuid,p_lines jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='20s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_invoice public.backoffice_sales_invoices%rowtype;v_operation record;v_payload jsonb;
  v_item jsonb;v_line public.backoffice_sales_invoice_lines%rowtype;v_seen uuid[]:=ARRAY[]::uuid[];
  v_line_count bigint;v_changed bigint:=0;v_direction integer:=0;v_item_direction integer;
  v_old_price numeric(24,4);v_new_price numeric(24,4);v_discount numeric(24,4);
  v_old_gross numeric(24,4);v_new_gross numeric(24,4);v_old_dpp numeric(24,4);
  v_new_dpp numeric(24,4);v_old_tax numeric(24,4);v_new_tax numeric(24,4);
  v_tax_result jsonb;v_tax_line jsonb;v_rows jsonb:='[]'::jsonb;
  v_revenue_delta numeric(24,4):=0;v_tax_delta numeric(24,4):=0;v_total_delta numeric(24,4);
  v_prior_total numeric(24,4);v_new_total numeric(24,4);v_return_credit numeric(24,4);
  v_paid numeric(24,4);v_prior_net numeric(24,4);v_new_net numeric(24,4);
  v_prior_ar numeric(24,4);v_new_ar numeric(24,4);v_prior_refund numeric(24,4);
  v_new_refund numeric(24,4);v_ar numeric(24,4);v_refund numeric(24,4);
  v_now timestamptz:=clock_timestamp();v_date date;v_timezone text;v_kind text;
  v_correction_id uuid:=gen_random_uuid();v_correction_no text;v_category uuid;
  v_event public.financial_events%rowtype;v_period public.accounting_periods%rowtype;
  v_journal public.finance_journals%rowtype;v_journal_type text:='AUTOMATIC';v_accounting_date date;
  v_account uuid;v_line_no integer:=0;v_group record;v_response jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company NOT IN('4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) THEN
    RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_COMPANY_NOT_ENABLED';
  END IF;
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','EDIT_DRAFT');
  PERFORM private.require_backoffice_sales_invoice_post_permission(v_company);
  IF p_invoice_id IS NULL OR p_expected_version IS NULL OR p_expected_price_revision IS NULL
    OR p_expected_price_revision<0 OR p_operation_id IS NULL
    OR jsonb_typeof(p_lines)<>'array' OR jsonb_array_length(p_lines)=0
    OR jsonb_array_length(p_lines)>500 THEN
    RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_PAYLOAD_INVALID';
  END IF;
  v_payload:=jsonb_build_object('invoiceId',p_invoice_id,'expectedVersion',p_expected_version,
    'expectedPriceRevision',p_expected_price_revision,'lines',p_lines);
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company||':BACKOFFICE_INVOICE_PRICE_CORRECTION:'||p_operation_id,0));
  SELECT * INTO v_operation FROM public.backoffice_sales_invoice_price_correction_operations operation
  WHERE operation.company_id=v_company AND operation.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_operation.source_invoice_id IS DISTINCT FROM p_invoice_id
      OR v_operation.expected_invoice_version IS DISTINCT FROM p_expected_version
      OR v_operation.expected_price_revision IS DISTINCT FROM p_expected_price_revision
      OR v_operation.request_snapshot IS DISTINCT FROM v_payload THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    IF v_operation.response_snapshot IS NULL THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_OPERATION_INCOMPLETE'; END IF;
    RETURN v_operation.response_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  IF v_invoice.status<>'POSTED' OR v_invoice.invoice_type<>'REGULAR' THEN
    RAISE EXCEPTION 'POSTED_REGULAR_INVOICE_PRICE_CORRECTION_REQUIRED';
  END IF;
  IF v_invoice.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF (SELECT count(*) FROM public.backoffice_sales_invoice_price_corrections correction
      WHERE correction.company_id=v_company AND correction.source_invoice_id=v_invoice.id
        AND correction.status='POSTED')<>p_expected_price_revision THEN
    RAISE EXCEPTION 'INVOICE_PRICE_REVISION_CONFLICT';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=v_company AND note.source_invoice_id=v_invoice.id
        AND note.status IN('DRAFT','POSTED')) THEN
    RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_AFTER_RETURN_NOT_ALLOWED';
  END IF;
  SELECT company.timezone,(v_now AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_date FROM public.companies company WHERE company.id=v_company;
  SELECT count(*) INTO v_line_count FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
    AND line.line_type='PRODUCT' AND line.source_kind='SALES_ORDER'
    AND line.sales_order_line_id IS NOT NULL;
  IF jsonb_array_length(p_lines)<>v_line_count THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_LINE_SET_MISMATCH'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
    BEGIN
      SELECT * INTO STRICT v_line FROM public.backoffice_sales_invoice_lines line
      WHERE line.company_id=v_company AND line.invoice_id=v_invoice.id
        AND line.id=(v_item->>'invoiceLineId')::uuid AND line.line_type='PRODUCT'
        AND line.source_kind='SALES_ORDER' AND line.sales_order_line_id IS NOT NULL;
      v_new_price:=round((v_item->>'newUnitPrice')::numeric,4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_LINE_INVALID'; END;
    IF v_new_price<0 OR v_line.id=ANY(v_seen) THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_LINE_INVALID'; END IF;
    v_seen:=array_append(v_seen,v_line.id);
    v_old_price:=round(private.backoffice_invoice_effective_entered_unit_price(v_company,v_line.id),4);
    IF v_new_price=v_old_price THEN CONTINUE; END IF;
    v_changed:=v_changed+1;v_item_direction:=CASE WHEN v_new_price>v_old_price THEN 1 ELSE -1 END;
    IF v_direction=0 THEN v_direction:=v_item_direction;
    ELSIF v_direction<>v_item_direction THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_MIXED_DIRECTION'; END IF;
    v_discount:=round(v_line.discount_amount,4);
    v_old_gross:=round(v_line.quantity_uom*v_old_price-v_discount,4);
    v_new_gross:=round(v_line.quantity_uom*v_new_price-v_discount,4);
    IF v_new_gross<0 THEN RAISE EXCEPTION 'INVOICE_DISCOUNT_EXCEEDS_CORRECTED_LINE_TOTAL'; END IF;
    v_old_dpp:=v_old_gross;v_new_dpp:=v_new_gross;v_old_tax:=0;v_new_tax:=0;
    IF COALESCE((v_line.source_snapshot->>'taxApplied')::boolean,false) THEN
      IF v_line.source_snapshot->>'taxPriceMode'<>'INCLUSIVE'
        OR NULLIF(v_line.source_snapshot->>'taxRatePercent','') IS NULL
        OR NULLIF(v_line.source_snapshot->>'taxCalculationScope','') IS NULL
        OR NULLIF(v_line.source_snapshot->>'taxAccountId','') IS NULL THEN
        RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_TAX_SOURCE_INVALID';
      END IF;
      v_tax_result:=private.calculate_tax_group(jsonb_build_array(
        jsonb_build_object('lineKey',v_line.id::text,'amount',v_old_gross)),
        (v_line.source_snapshot->>'taxRatePercent')::numeric,'SALES',
        v_line.source_snapshot->>'taxPriceMode',v_line.source_snapshot->>'taxCalculationScope');
      v_tax_line:=v_tax_result->'lines'->0;v_old_dpp:=round((v_tax_line->>'taxBase')::numeric,4);
      v_old_tax:=round((v_tax_line->>'taxAmount')::numeric,4);
      v_tax_result:=private.calculate_tax_group(jsonb_build_array(
        jsonb_build_object('lineKey',v_line.id::text,'amount',v_new_gross)),
        (v_line.source_snapshot->>'taxRatePercent')::numeric,'SALES',
        v_line.source_snapshot->>'taxPriceMode',v_line.source_snapshot->>'taxCalculationScope');
      v_tax_line:=v_tax_result->'lines'->0;v_new_dpp:=round((v_tax_line->>'taxBase')::numeric,4);
      v_new_tax:=round((v_tax_line->>'taxAmount')::numeric,4);
    END IF;
    v_revenue_delta:=v_revenue_delta+(v_new_dpp-v_old_dpp);
    v_tax_delta:=v_tax_delta+(v_new_tax-v_old_tax);
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object('source',to_jsonb(v_line),
      'oldPrice',v_old_price,'newPrice',v_new_price,'discount',v_discount,
      'oldRevenue',v_old_dpp,'newRevenue',v_new_dpp,'oldTax',v_old_tax,'newTax',v_new_tax,
      'revenueDelta',v_new_dpp-v_old_dpp,'taxDelta',v_new_tax-v_old_tax,
      'totalDelta',(v_new_dpp-v_old_dpp)+(v_new_tax-v_old_tax),
      'taxAccountId',NULLIF(v_line.source_snapshot->>'taxAccountId','')));
  END LOOP;
  IF v_changed=0 THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_NO_CHANGE'; END IF;
  v_revenue_delta:=round(v_revenue_delta,4);v_tax_delta:=round(v_tax_delta,4);
  v_total_delta:=round(v_revenue_delta+v_tax_delta,4);
  IF v_total_delta=0 OR sign(v_total_delta)<>v_direction THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_NO_FINANCIAL_CHANGE'; END IF;
  v_prior_total:=private.backoffice_invoice_effective_total(v_company,v_invoice.id,NULL);
  v_new_total:=round(v_prior_total+v_total_delta,4);
  SELECT round(COALESCE(sum(note.grand_total),0),4) INTO v_return_credit
  FROM public.backoffice_sales_credit_notes note WHERE note.company_id=v_company
    AND note.source_invoice_id=v_invoice.id AND note.status='POSTED';
  IF v_new_total<=0 OR v_new_total<v_return_credit THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_BELOW_POSTED_CREDIT'; END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id;
  v_kind:=CASE WHEN v_total_delta>0 THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END;
  v_prior_net:=round(v_prior_total-v_return_credit-v_paid,4);
  v_new_net:=round(v_new_total-v_return_credit-v_paid,4);
  v_prior_ar:=greatest(0,v_prior_net);v_new_ar:=greatest(0,v_new_net);
  v_prior_refund:=greatest(0,-v_prior_net);v_new_refund:=greatest(0,-v_new_net);
  v_ar:=round(v_new_ar-v_prior_ar,4);
  v_refund:=round(v_new_refund-v_prior_refund,4);
  IF round(v_ar-v_refund,4)<>v_total_delta
    OR (v_kind='DEBIT_NOTE' AND (v_ar<0 OR v_refund>0))
    OR (v_kind='CREDIT_NOTE' AND (v_ar>0 OR v_refund<0)) THEN
    RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_SETTLEMENT_SPLIT_INVALID';
  END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company
    AND category.system_key=CASE v_kind WHEN 'DEBIT_NOTE' THEN 'CUSTOMER_DEBIT_NOTE' ELSE 'CUSTOMER_CREDIT_NOTE' END
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  IF v_category IS NULL THEN RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_CATEGORY_REQUIRED'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period WHERE period.company_id=v_company
    AND v_date BETWEEN period.start_date AND period.end_date AND period.status IN('OPEN','REOPENED')
    ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period WHERE period.company_id=v_company
      AND period.start_date>v_date AND period.status IN('OPEN','REOPENED')
      ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_date; END IF;
  v_correction_no:=CASE v_kind WHEN 'DEBIT_NOTE' THEN 'DN-' ELSE 'PCN-' END
    ||to_char(v_date,'YYYYMMDD')||'-'||lpad(nextval('private.backoffice_sales_invoice_price_correction_no_seq')::text,10,'0');
  INSERT INTO public.backoffice_sales_invoice_price_correction_operations(company_id,operation_id,
    source_invoice_id,expected_invoice_version,expected_price_revision,request_snapshot,actor_id)
  VALUES(v_company,p_operation_id,v_invoice.id,p_expected_version,p_expected_price_revision,v_payload,v_actor);
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,amounts,status,error_message,created_by,company_id,store_id,
    system_event_key,transaction_category_id,transaction_rule_version)
  VALUES('BO-IPC-'||replace(v_correction_id::text,'-',''),'SALE_REVISED'::public.event_type,
    'backoffice_sales_invoice_price_corrections',v_correction_id,v_now,1,
    'BACKOFFICE_INVOICE_PRICE_CORRECTION|'||v_company||'|'||v_correction_id,
    jsonb_build_object('sourceInvoiceId',v_invoice.id,'correctionKind',v_kind,
      'priorEffectiveTotal',v_prior_total,'correctedEffectiveTotal',v_new_total,
      'revenueDelta',v_revenue_delta,'taxDelta',v_tax_delta,'totalDelta',v_total_delta,
      'paidAmountAtCorrection',v_paid,'postedReturnCreditAtCorrection',v_return_credit,
      'priorNetSettlementPosition',v_prior_net,'correctedNetSettlementPosition',v_new_net,
      'arAdjustmentAmount',v_ar,'refundLiabilityAmount',v_refund),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,v_company,
    v_invoice.store_id,CASE v_kind WHEN 'DEBIT_NOTE' THEN 'CUSTOMER_DEBIT_NOTE' ELSE 'CUSTOMER_CREDIT_NOTE' END,
    v_category,20260928110000) RETURNING * INTO v_event;
  INSERT INTO public.backoffice_sales_invoice_price_corrections(id,company_id,source_invoice_id,
    correction_no,correction_kind,status,correction_at,correction_date,prior_effective_total,
    corrected_effective_total,revenue_delta,tax_delta,total_delta,ar_adjustment_amount,
    refund_liability_amount,financial_event_id,source_invoice_version,source_invoice_snapshot,
    created_by,posted_by,posted_at)
  VALUES(v_correction_id,v_company,v_invoice.id,v_correction_no,v_kind,'POSTED',v_now,v_date,
    v_prior_total,v_new_total,v_revenue_delta,v_tax_delta,v_total_delta,v_ar,v_refund,
    v_event.id,v_invoice.master_version,private.backoffice_sales_invoice_snapshot(v_company,v_invoice.id)
      ||jsonb_build_object('priceCorrectionSettlement',jsonb_build_object(
        'paidAmountAtCorrection',v_paid,'postedReturnCreditAtCorrection',v_return_credit,
        'priorNetSettlementPosition',v_prior_net,'correctedNetSettlementPosition',v_new_net,
        'arAdjustmentAmount',v_ar,'refundLiabilityAmount',v_refund)),
    v_actor,v_actor,v_now);
  INSERT INTO public.backoffice_sales_invoice_price_correction_lines(company_id,correction_id,
    source_invoice_id,source_invoice_line_id,line_no,product_id,uom_id,quantity_uom,
    old_entered_unit_price,new_entered_unit_price,discount_amount,old_revenue_amount,
    new_revenue_amount,old_tax_amount,new_tax_amount,revenue_delta,tax_delta,total_delta,
    tax_account_id,source_snapshot)
  SELECT v_company,v_correction_id,v_invoice.id,(row->'source'->>'id')::uuid,ordinality,
    (row->'source'->>'product_id')::uuid,(row->'source'->>'uom_id')::uuid,
    (row->'source'->>'quantity_uom')::numeric,(row->>'oldPrice')::numeric,
    (row->>'newPrice')::numeric,(row->>'discount')::numeric,(row->>'oldRevenue')::numeric,
    (row->>'newRevenue')::numeric,(row->>'oldTax')::numeric,(row->>'newTax')::numeric,
    (row->>'revenueDelta')::numeric,(row->>'taxDelta')::numeric,(row->>'totalDelta')::numeric,
    NULLIF(row->>'taxAccountId','')::uuid,row->'source'
  FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS item(row,ordinality);
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,accounting_period_id,
    accounting_date,original_event_date,source_type,source_id,source_version,financial_event_id,
    idempotency_key,system_event_key,transaction_category_id,transaction_rule_version,store_id,
    warehouse_id,description,status,created_by)
  VALUES(v_company,'IPC-'||replace(v_correction_id::text,'-',''),v_journal_type,v_period.id,
    v_accounting_date,v_date,'backoffice_sales_invoice_price_corrections',v_correction_id,1,
    v_event.id,'BACKOFFICE_INVOICE_PRICE_CORRECTION_JOURNAL|'||v_company||'|'||v_correction_id,
    v_event.system_event_key,v_category,20260928110000,v_invoice.store_id,v_invoice.warehouse_id,
    'Koreksi harga '||v_invoice.invoice_no||' · '||v_correction_no,'DRAFT',v_actor)
  RETURNING * INTO v_journal;
  IF v_kind='DEBIT_NOTE' THEN
    v_account:=private.resolve_financial_event_account(v_event,'SALES_REVENUE');v_line_no:=20;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
      store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,0,v_revenue_delta,v_invoice.store_id,
      v_invoice.warehouse_id,v_invoice.customer_id,'Penambahan pendapatan koreksi harga');
  ELSE
    v_account:=private.resolve_financial_event_account(v_event,'SALES_RETURN_DISCOUNT');v_line_no:=10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
      store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,-v_revenue_delta,0,v_invoice.store_id,
      v_invoice.warehouse_id,v_invoice.customer_id,'Pengurang pendapatan koreksi harga');
  END IF;
  FOR v_group IN SELECT tax_account_id,round(sum(tax_delta),4) amount
    FROM public.backoffice_sales_invoice_price_correction_lines
    WHERE company_id=v_company AND correction_id=v_correction_id AND tax_delta<>0
    GROUP BY tax_account_id ORDER BY tax_account_id
  LOOP
    IF v_group.tax_account_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.id=v_group.tax_account_id
        AND account.is_active AND account.is_postable) THEN
      RAISE EXCEPTION 'INVOICE_PRICE_CORRECTION_TAX_ACCOUNT_INVALID';
    END IF;
    v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
      store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_group.tax_account_id,
      CASE WHEN v_group.amount<0 THEN -v_group.amount ELSE 0 END,
      CASE WHEN v_group.amount>0 THEN v_group.amount ELSE 0 END,
      v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,'Koreksi Pajak Keluaran');
  END LOOP;
  IF v_ar<>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
      store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,
      CASE WHEN v_ar>0 THEN v_ar ELSE 0 END,CASE WHEN v_ar<0 THEN -v_ar ELSE 0 END,
      v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,
      CASE WHEN v_ar>0 THEN 'Penambahan Piutang koreksi harga' ELSE 'Pengurang Piutang koreksi harga' END);
  END IF;
  IF v_refund<>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');v_line_no:=v_line_no+10;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,
      store_id,warehouse_id,customer_id,description)
    VALUES(v_company,v_journal.id,v_line_no,v_account,
      CASE WHEN v_refund<0 THEN -v_refund ELSE 0 END,
      CASE WHEN v_refund>0 THEN v_refund ELSE 0 END,
      v_invoice.store_id,v_invoice.warehouse_id,v_invoice.customer_id,
      CASE WHEN v_refund>0 THEN 'Utang Refund koreksi harga'
        ELSE 'Pengurang Utang Refund koreksi harga' END);
  END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,posted_at=v_now
  WHERE company_id=v_company AND id=v_journal.id RETURNING * INTO v_journal;
  IF round(v_journal.total_debit,4)<>round(v_journal.total_credit,4)
    OR round(v_journal.total_debit,4)<=0 THEN RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,processed_at=v_now,
    error_message=NULL,transaction_rule_version=20260928110000
  WHERE company_id=v_company AND id=v_event.id;
  PERFORM private.reconcile_backoffice_invoice_receivable_schedule(v_company,v_invoice.id);
  v_response:=jsonb_build_object('companyId',v_company,'correctionId',v_correction_id,
    'correctionNo',v_correction_no,'kind',v_kind,'correctionAt',v_now,
    'priorEffectiveTotal',v_prior_total,'effectiveTotal',v_new_total,
    'totalDelta',v_total_delta,'journalNo',v_journal.journal_no,
    'priceCorrectionContext',public.get_backoffice_sales_invoice_price_correction_context(v_invoice.id),
    'paymentContext',public.get_backoffice_sales_invoice_payment_context(v_invoice.id),'exactRetry',false);
  UPDATE public.backoffice_sales_invoice_price_correction_operations
  SET correction_id=v_correction_id,response_snapshot=v_response,completed_at=clock_timestamp()
  WHERE company_id=v_company AND operation_id=p_operation_id;
  RETURN v_response;
END
$$;

DO $patch_future_return_credit$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.allocate_backoffice_sales_return_invoices_before_retained(uuid,bigint,uuid,jsonb)'::regprocedure)
  INTO STRICT v_definition;

  v_old:='v_before jsonb;v_after jsonb;v_all_received boolean;v_has_draft_notes boolean;';
  v_new:='v_before jsonb;v_after jsonb;v_all_received boolean;v_has_draft_notes boolean;
  v_effective_line jsonb;';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return declaration anchor drift %',v_count;
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='    v_ratio:=v_qty_base/v_invoice_line.quantity_base;
    SELECT round(COALESCE(sum(line.line_amount+line.discount_amount),0),4),';
  v_new:='    v_effective_line:=private.backoffice_invoice_effective_line_amounts(
      v_company,v_invoice_line.id);
    v_ratio:=v_qty_base/v_invoice_line.quantity_base;
    SELECT round(COALESCE(sum(line.line_amount+line.discount_amount),0),4),';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return effective-price anchor drift %',v_count;
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='    v_charge:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.line_amount+v_invoice_line.discount_amount-v_prior
      ELSE round((v_invoice_line.line_amount+v_invoice_line.discount_amount)*v_ratio,4) END;
    v_discount:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.discount_amount-v_discount
      ELSE round(v_invoice_line.discount_amount*v_ratio,4) END;
    v_tax:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN v_invoice_line.tax_amount-v_tax
      ELSE round(v_invoice_line.tax_amount*v_ratio,4) END;';
  v_new:='    v_charge:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN (v_effective_line->>''chargeAmount'')::numeric-v_prior
      ELSE round((v_effective_line->>''chargeAmount'')::numeric*v_ratio,4) END;
    v_discount:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN (v_effective_line->>''discountAmount'')::numeric-v_discount
      ELSE round((v_effective_line->>''discountAmount'')::numeric*v_ratio,4) END;
    v_tax:=CASE WHEN v_used+v_qty_base=v_invoice_line.quantity_base
      THEN (v_effective_line->>''taxAmount'')::numeric-v_tax
      ELSE round((v_effective_line->>''taxAmount'')::numeric*v_ratio,4) END;';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return value anchor drift %',v_count;
  END IF;
  v_definition:=replace(v_definition,v_old,v_new);

  v_old:='      v_qty_uom,v_invoice_line.base_qty_per_uom,v_qty_base,v_invoice_line.unit_price,
      v_discount,v_tax,v_line_amount,
      v_invoice_line.source_snapshot||jsonb_build_object(''sourceInvoiceId'',v_invoice.id,
        ''sourceInvoiceNo'',v_invoice.invoice_no,''sourceInvoiceLineId'',v_invoice_line.id));';
  v_new:='      v_qty_uom,v_invoice_line.base_qty_per_uom,v_qty_base,
      round((v_line_amount+v_discount)/v_qty_uom,4),v_discount,v_tax,v_line_amount,
      v_invoice_line.source_snapshot||jsonb_build_object(''sourceInvoiceId'',v_invoice.id,
        ''sourceInvoiceNo'',v_invoice.invoice_no,''sourceInvoiceLineId'',v_invoice_line.id,
        ''effectiveEnteredUnitPrice'',(v_effective_line->>''enteredUnitPrice'')::numeric,
        ''priceCorrectionRevision'',(v_effective_line->>''priceRevision'')::bigint));';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return insert anchor drift %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_future_return_credit$;

DO $patch_customer_statement$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_finance_customer_statement(uuid,date,date,uuid)'::regprocedure)
  INTO STRICT v_definition;
  v_old:='WHERE refund.company_id=v_company AND refund.status=''POSTED''
      AND refund.refund_date<=v_as_of
      AND (p_store_id IS NULL OR refund.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows)';
  v_new:='WHERE refund.company_id=v_company AND refund.status=''POSTED''
      AND refund.refund_date<=v_as_of
      AND (p_store_id IS NULL OR refund.store_id=p_store_id)
    UNION ALL
    SELECT correction.id,''PRICE_CORRECTION'',''BACKOFFICE'',correction.correction_no,
      correction.correction_date,NULL::date,invoice.store_id,store.store_name,
      CASE WHEN correction.total_delta>0 THEN correction.total_delta ELSE 0::numeric END,
      CASE WHEN correction.total_delta<0 THEN -correction.total_delta ELSE 0::numeric END,
      (CASE correction.correction_kind WHEN ''DEBIT_NOTE'' THEN ''Debit Note koreksi harga untuk ''
        ELSE ''Credit Note koreksi harga untuk '' END||invoice.invoice_no)::text
    FROM public.backoffice_sales_invoice_price_corrections correction
    JOIN public.backoffice_sales_invoices invoice
      ON invoice.company_id=correction.company_id AND invoice.id=correction.source_invoice_id
      AND invoice.customer_id=p_customer_id
    LEFT JOIN public.stores store ON store.company_id=invoice.company_id AND store.id=invoice.store_id
    WHERE correction.company_id=v_company AND correction.status=''POSTED''
      AND correction.correction_date<=v_as_of
      AND (p_store_id IS NULL OR invoice.store_id=p_store_id)
  ),all_rows AS (SELECT * FROM invoice_rows UNION ALL SELECT * FROM receipt_rows)';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Statement correction anchor drift %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_customer_statement$;

DO $patch_receipt_workspace$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef('public.get_finance_customer_receipts()'::regprocedure)
  INTO STRICT v_definition;
  v_old:='store.store_name,invoice.grand_total,COALESCE(receipt.paid,0),';
  v_new:='store.store_name,
        private.backoffice_invoice_effective_total(invoice.company_id,invoice.id,v_today),
        COALESCE(receipt.paid,0),';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt workspace total anchor drift %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_receipt_workspace$;

CREATE OR REPLACE FUNCTION public.get_backoffice_sales_invoice_payment_context(p_invoice_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='8s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
  v_invoice public.backoffice_sales_invoices%rowtype;v_paid numeric(20,4);
  v_credit numeric(20,4);v_return_refund numeric(20,4);v_refunded numeric(20,4);
  v_price_refund numeric(20,4);v_effective numeric(20,4);v_result jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders','VIEW');
  v_permission:=private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=v_company AND invoice.id=p_invoice_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_FOUND'; END IF;
  v_effective:=private.backoffice_invoice_effective_total(v_company,p_invoice_id,NULL);
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
  WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id;
  SELECT round(COALESCE(sum(note.grand_total),0),4),
    round(COALESCE(sum(note.refund_liability_amount),0),4),
    round(COALESCE(sum(private.backoffice_sales_credit_note_refunded_amount(note.company_id,note.id)),0),4)
  INTO v_credit,v_return_refund,v_refunded FROM public.backoffice_sales_credit_notes note
  WHERE note.company_id=v_company AND note.source_invoice_id=p_invoice_id AND note.status='POSTED';
  SELECT round(COALESCE(sum(correction.refund_liability_amount),0),4) INTO v_price_refund
  FROM public.backoffice_sales_invoice_price_corrections correction
  WHERE correction.company_id=v_company AND correction.source_invoice_id=p_invoice_id
    AND correction.status='POSTED';
  SELECT jsonb_build_object('companyDate',(clock_timestamp() AT TIME ZONE company.timezone)::date,
    'effectiveCapabilities',v_permission->'effectiveCapabilities',
    'summary',jsonb_build_object('originalAmount',v_invoice.grand_total,
      'priceCorrectionAmount',v_effective-v_invoice.grand_total,'effectiveInvoiceAmount',v_effective,
      'creditNoteAmount',v_credit,'netInvoiceAmount',greatest(0,v_effective-v_credit),
      'paidAmount',v_paid,'outstandingAmount',greatest(0,v_effective-v_credit-v_paid),
      'refundLiabilityAmount',v_return_refund+v_price_refund,'priceCorrectionRefundLiabilityAmount',v_price_refund,
      'refundedAmount',v_refunded,'remainingRefundLiability',greatest(0,v_return_refund+v_price_refund-v_refunded),
      'status',CASE WHEN v_invoice.status<>'POSTED' THEN 'NOT_APPLICABLE'
        WHEN v_effective-v_credit-v_paid>0 THEN 'PARTIALLY_PAID'
        WHEN v_return_refund+v_price_refund-v_refunded>0 THEN 'REFUND_PENDING'
        WHEN v_return_refund+v_price_refund>0 THEN 'REFUNDED'
        WHEN v_paid=0 AND v_credit=0 THEN 'NOT_PAID' ELSE 'PAID' END),
    'payments',COALESCE((SELECT jsonb_agg(jsonb_build_object('receiptId',receipt.id,
      'receiptNo',receipt.receipt_no,'receiptDate',receipt.receipt_date,
      'paymentMethodName',receipt.payment_method_name_snapshot,'settlementRoute',receipt.settlement_route_snapshot,
      'referenceNo',receipt.reference_no,'evidenceUrl',receipt.evidence_url,'notes',receipt.notes,
      'amount',allocation.allocated_amount,'postedAt',receipt.posted_at,
      'journalNo',(SELECT journal.journal_no FROM public.finance_journals journal
        WHERE journal.company_id=receipt.company_id AND journal.financial_event_id=receipt.financial_event_id
          AND journal.status='POSTED' ORDER BY journal.id LIMIT 1))
      ORDER BY receipt.receipt_date,receipt.posted_at,receipt.id)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
        AND receipt.id=allocation.document_id AND receipt.status='POSTED'
      WHERE allocation.company_id=v_company AND allocation.invoice_id=p_invoice_id),'[]'::jsonb),
    'creditNotes',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',note.id,
      'creditNoteNo',note.credit_note_no,'creditNoteDate',note.credit_note_date,
      'grandTotal',note.grand_total,'arReductionAmount',note.ar_reduction_amount,
      'refundLiabilityAmount',note.refund_liability_amount,
      'refundedAmount',private.backoffice_sales_credit_note_refunded_amount(note.company_id,note.id),
      'status',note.status) ORDER BY note.credit_note_date,note.created_at,note.id)
      FROM public.backoffice_sales_credit_notes note WHERE note.company_id=v_company
        AND note.source_invoice_id=p_invoice_id AND note.status='POSTED'),'[]'::jsonb),
    'priceCorrections',(public.get_backoffice_sales_invoice_price_correction_context(p_invoice_id)->'corrections'),
    'refunds',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',refund.id,'refundNo',refund.refund_no,
      'documentKind',refund.document_kind,'refundDate',refund.refund_date,'amount',refund.amount,
      'paymentMethodName',refund.payment_method_name_snapshot,'settlementRoute',refund.settlement_route_snapshot,
      'referenceNo',refund.reference_no,'evidenceUrl',refund.evidence_url,'notes',refund.notes,
      'reversalOfRefundId',refund.reversal_of_refund_id,'postedAt',refund.posted_at)
      ORDER BY refund.refund_date,refund.created_at,refund.id)
      FROM public.backoffice_sales_customer_refunds refund
      WHERE refund.company_id=v_company AND refund.source_invoice_id=p_invoice_id),'[]'::jsonb),
    'paymentMethods',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',method.id,
      'name',method.payment_method_name,'type',method.method_type,
      'settlementRoute',method.settlement_route,'proofMode',method.proof_mode)
      ORDER BY method.is_default DESC,method.payment_method_name,method.id)
      FROM public.payment_methods method WHERE method.company_id=v_company AND method.is_active
        AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK')),'[]'::jsonb))
  INTO STRICT v_result FROM public.companies company WHERE company.id=v_company;
  RETURN v_result;
END
$$;

REVOKE ALL ON FUNCTION private.trg_guard_backoffice_invoice_price_correction_history(),
  private.backoffice_invoice_price_delta(uuid,uuid,date),
  private.backoffice_invoice_effective_total(uuid,uuid,date),
  private.backoffice_invoice_effective_entered_unit_price(uuid,uuid),
  private.backoffice_invoice_effective_line_amounts(uuid,uuid),
  private.backoffice_sales_invoice_ui_snapshot_before_price_correction(uuid,uuid),
  private.backoffice_sales_invoice_ui_snapshot(uuid,uuid),
  private.rebuild_backoffice_invoice_effective_schedules(uuid,uuid),
  public.get_backoffice_sales_invoice_price_correction_context(uuid),
  public.post_backoffice_sales_invoice_price_correction(uuid,bigint,bigint,uuid,jsonb)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.get_backoffice_sales_invoice_price_correction_context(uuid),
  public.post_backoffice_sales_invoice_price_correction(uuid,bigint,bigint,uuid,jsonb)
  TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_invoice_price_correction_history(),
  private.backoffice_invoice_price_delta(uuid,uuid,date),
  private.backoffice_invoice_effective_total(uuid,uuid,date),
  private.backoffice_invoice_effective_entered_unit_price(uuid,uuid),
  private.backoffice_invoice_effective_line_amounts(uuid,uuid),
  private.backoffice_sales_invoice_ui_snapshot_before_price_correction(uuid,uuid),
  private.backoffice_sales_invoice_ui_snapshot(uuid,uuid),
  private.rebuild_backoffice_invoice_effective_schedules(uuid,uuid)
  TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260928110000','backoffice_posted_invoice_price_correction',
  'Adds immutable server-timestamped posted Backoffice Invoice price corrections with Debit/Credit Note delta Journals, effective AR/payment read models, exact retry and no Stock/FIFO/COGS/original Invoice/posted Journal mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
