-- Source-neutral Customer Receipt allocation for posted Backoffice Sales Invoices.
-- Existing Retail allocation/RPC contracts remain available and unchanged.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260829120000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909161000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Receipt and Backoffice Invoice runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260911160000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911160000';
  END IF;
  IF to_regclass('public.customer_receipt_backoffice_invoice_allocations') IS NOT NULL
    OR to_regprocedure('public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb)') IS NOT NULL
    OR to_regprocedure('public.post_customer_receipt_allocated(uuid,bigint,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice payment collection object collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.backoffice_sales_invoices invoice
    LEFT JOIN public.backoffice_sales_invoice_receivable_schedules schedule
      ON schedule.company_id=invoice.company_id AND schedule.invoice_id=invoice.id
    WHERE invoice.status='POSTED' AND invoice.grand_total>0
    GROUP BY invoice.company_id,invoice.id,invoice.grand_total
    HAVING round(COALESCE(sum(schedule.amount_due),0),4)<>round(invoice.grand_total,4)
      OR bool_or(schedule.status NOT IN('OPEN','PARTIALLY_PAID','PAID'))
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: posted Backoffice Invoice schedule drift';
  END IF;
END
$guard$;

CREATE TABLE public.customer_receipt_backoffice_invoice_allocations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  document_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  client_allocation_key uuid NOT NULL,
  allocated_amount numeric(20,4) NOT NULL,
  invoice_no_snapshot text NOT NULL,
  invoice_date_snapshot date NOT NULL,
  due_date_snapshot date,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT customer_receipt_bo_alloc_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT customer_receipt_bo_alloc_invoice_unique UNIQUE(company_id,document_id,invoice_id),
  CONSTRAINT customer_receipt_bo_alloc_client_unique UNIQUE(company_id,document_id,client_allocation_key),
  CONSTRAINT customer_receipt_bo_alloc_document_fk FOREIGN KEY(company_id,document_id)
    REFERENCES public.customer_receipt_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_bo_alloc_invoice_fk FOREIGN KEY(company_id,invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT customer_receipt_bo_alloc_amount_check CHECK(allocated_amount>0),
  CONSTRAINT customer_receipt_bo_alloc_invoice_no_check CHECK(nullif(btrim(invoice_no_snapshot),'') IS NOT NULL)
);

CREATE INDEX customer_receipt_bo_alloc_invoice_idx
  ON public.customer_receipt_backoffice_invoice_allocations(company_id,invoice_id);

CREATE TRIGGER customer_receipt_bo_allocation_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.customer_receipt_backoffice_invoice_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_customer_receipt_child_guard();

ALTER TABLE public.customer_receipt_backoffice_invoice_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.customer_receipt_backoffice_invoice_allocations
  FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.customer_receipt_backoffice_invoice_allocations TO service_role;

CREATE FUNCTION private.backoffice_invoice_receivable_before_receipts(
  p_company_id uuid,p_invoice_id uuid,p_as_of date
) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN invoice.status='POSTED' AND invoice.invoice_date<=p_as_of
    THEN invoice.grand_total ELSE 0::numeric END
  FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id;
$$;

CREATE FUNCTION private.reconcile_backoffice_invoice_receivable_schedule(
  p_company_id uuid,p_invoice_id uuid
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_invoice public.backoffice_sales_invoices%rowtype;
  v_paid numeric(24,4);v_remaining numeric(24,4);v_apply numeric(24,4);v_schedule record;
BEGIN
  SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
  WHERE invoice.company_id=p_company_id AND invoice.id=p_invoice_id FOR UPDATE;
  IF NOT FOUND OR v_invoice.status<>'POSTED' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE';
  END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_paid
  FROM public.customer_receipt_backoffice_invoice_allocations allocation
  JOIN public.customer_receipt_documents receipt
    ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
   AND receipt.status='POSTED'
  WHERE allocation.company_id=p_company_id AND allocation.invoice_id=p_invoice_id;
  IF v_paid<0 OR v_paid>round(v_invoice.grand_total,4) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_OVER_ALLOCATION';
  END IF;
  UPDATE public.backoffice_sales_invoice_receivable_schedules
  SET allocated_payment_amount=0,status='OPEN',updated_at=clock_timestamp()
  WHERE company_id=p_company_id AND invoice_id=p_invoice_id;
  v_remaining:=v_paid;
  FOR v_schedule IN
    SELECT schedule.id,schedule.amount_due
    FROM public.backoffice_sales_invoice_receivable_schedules schedule
    WHERE schedule.company_id=p_company_id AND schedule.invoice_id=p_invoice_id
    ORDER BY schedule.due_date,schedule.installment_no FOR UPDATE
  LOOP
    v_apply:=least(v_remaining,v_schedule.amount_due);
    UPDATE public.backoffice_sales_invoice_receivable_schedules
    SET allocated_payment_amount=v_apply,
      status=CASE WHEN v_apply=0 THEN 'OPEN'
        WHEN v_apply=v_schedule.amount_due THEN 'PAID' ELSE 'PARTIALLY_PAID' END,
      updated_at=clock_timestamp()
    WHERE company_id=p_company_id AND id=v_schedule.id;
    v_remaining:=v_remaining-v_apply;
  END LOOP;
  IF v_remaining<>0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_SCHEDULE_MISMATCH';
  END IF;
END
$$;

CREATE FUNCTION public.save_customer_receipt_allocated_draft(
  p_document_id uuid,p_master_version bigint,p_customer_id uuid,p_receipt_date date,
  p_payment_method_id uuid,p_reference_no text,p_evidence_url text,p_notes text,
  p_received_amount numeric,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_document public.customer_receipt_documents%rowtype;v_method public.payment_methods%rowtype;
  v_before jsonb;v_item jsonb;v_sale public.sales_headers%rowtype;
  v_invoice public.backoffice_sales_invoices%rowtype;v_source_type text;v_source_id uuid;
  v_amount numeric(20,4);v_paid numeric(20,4);v_total numeric(20,4):=0;
  v_client_key uuid;v_due date;v_is_new boolean:=p_document_id IS NULL;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts',
    CASE WHEN v_is_new THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_customer_id IS NULL OR p_receipt_date IS NULL OR p_payment_method_id IS NULL THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_REQUIRED_FIELD_MISSING';
  END IF;
  IF p_receipt_date>current_date THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_FUTURE'; END IF;
  IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_EVIDENCE_MUST_USE_HTTPS';
  END IF;
  IF jsonb_typeof(p_allocations)<>'array' OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_REQUIRED';
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(p_allocations))<>
    (SELECT count(DISTINCT item->>'clientAllocationKey')
      FROM jsonb_array_elements(p_allocations) item) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_CLIENT_KEY_DUPLICATE';
  END IF;
  PERFORM 1 FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=p_customer_id AND customer.is_active AND NOT customer.is_system_customer FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_CUSTOMER_INVALID'; END IF;
  SELECT * INTO v_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.id=p_payment_method_id AND method.is_active
    AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK');
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_PAYMENT_METHOD_INVALID'; END IF;

  IF v_is_new THEN
    INSERT INTO public.customer_receipt_documents(company_id,receipt_no,customer_id,
      receipt_date,payment_method_id,payment_method_name_snapshot,payment_method_type_snapshot,
      settlement_route_snapshot,reference_no,evidence_url,notes,total_amount,received_amount,
      unapplied_amount,unapplied_disposition,created_by)
    VALUES(v_company,'CR/'||to_char(p_receipt_date,'YYYY/MM')||'/'||
      lpad(nextval('private.customer_receipt_no_seq')::text,6,'0'),p_customer_id,
      p_receipt_date,p_payment_method_id,v_method.payment_method_name,v_method.method_type,
      v_method.settlement_route,NULLIF(btrim(p_reference_no),''),p_evidence_url,
      NULLIF(btrim(p_notes),''),0,0,0,'NONE',v_actor) RETURNING * INTO v_document;
  ELSE
    SELECT * INTO v_document FROM public.customer_receipt_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
    IF v_document.status<>'DRAFT' OR v_document.unapplied_disposition<>'NONE' THEN
      RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE';
    END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN
      RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    v_before:=to_jsonb(v_document);
    DELETE FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id;
    DELETE FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id;
    UPDATE public.customer_receipt_documents SET customer_id=p_customer_id,
      receipt_date=p_receipt_date,payment_method_id=p_payment_method_id,
      payment_method_name_snapshot=v_method.payment_method_name,
      payment_method_type_snapshot=v_method.method_type,
      settlement_route_snapshot=v_method.settlement_route,
      reference_no=NULLIF(btrim(p_reference_no),''),evidence_url=p_evidence_url,
      notes=NULLIF(btrim(p_notes),''),total_amount=0,received_amount=0,
      unapplied_amount=0,unapplied_disposition='NONE',master_version=master_version+1,
      updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
    v_source_type:=upper(NULLIF(btrim(v_item->>'sourceType'),''));
    BEGIN
      v_source_id:=(v_item->>'sourceId')::uuid;
      v_client_key:=(v_item->>'clientAllocationKey')::uuid;
      v_amount:=round((v_item->>'allocatedAmount')::numeric,4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_INVALID'; END;
    IF v_source_type IS NULL
      OR v_source_type NOT IN('RETAIL_SALE','BACKOFFICE_SALES_INVOICE') OR v_amount<=0 THEN
      RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_INVALID';
    END IF;
    IF v_source_type='RETAIL_SALE' THEN
      SELECT * INTO v_sale FROM public.sales_headers sale
      WHERE sale.company_id=v_company AND sale.id=v_source_id AND sale.is_tempo
        AND sale.customer_id=p_customer_id
        AND (sale.document_status='POSTED' OR EXISTS(SELECT 1
          FROM public.sales_dispatch_financial_effects effect
          WHERE effect.company_id=sale.company_id AND effect.sales_id=sale.id
            AND effect.effective_date<=p_receipt_date)) FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_INVALID'; END IF;
      SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_paid
      FROM public.customer_receipt_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
       AND receipt.status='POSTED'
      WHERE allocation.company_id=v_company AND allocation.sales_id=v_sale.id;
      IF v_amount>private.odr6d_dispatched_receivable_before_receipts(
        v_company,v_sale.id,p_receipt_date)-v_paid THEN
        RAISE EXCEPTION 'CUSTOMER_RECEIPT_OVER_ALLOCATION';
      END IF;
      INSERT INTO public.customer_receipt_allocations(company_id,document_id,sales_id,
        client_allocation_key,allocated_amount,invoice_no_snapshot,
        sale_transaction_date_snapshot,due_date_snapshot)
      SELECT v_company,v_document.id,v_sale.id,v_client_key,v_amount,
        invoice.invoice_no,v_sale.transaction_date,v_sale.due_date
      FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=v_company AND invoice.sales_id=v_sale.id;
      IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_INVOICE_SNAPSHOT_REQUIRED'; END IF;
    ELSE
      SELECT * INTO v_invoice FROM public.backoffice_sales_invoices invoice
      WHERE invoice.company_id=v_company AND invoice.id=v_source_id
        AND invoice.status='POSTED' AND invoice.customer_id=p_customer_id
        AND invoice.invoice_date<=p_receipt_date FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE'; END IF;
      SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_paid
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      JOIN public.customer_receipt_documents receipt
        ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
       AND receipt.status='POSTED'
      WHERE allocation.company_id=v_company AND allocation.invoice_id=v_invoice.id;
      IF v_amount>v_invoice.grand_total-v_paid THEN
        RAISE EXCEPTION 'CUSTOMER_RECEIPT_OVER_ALLOCATION';
      END IF;
      SELECT min(schedule.due_date) INTO v_due
      FROM public.backoffice_sales_invoice_receivable_schedules schedule
      WHERE schedule.company_id=v_company AND schedule.invoice_id=v_invoice.id;
      INSERT INTO public.customer_receipt_backoffice_invoice_allocations(
        company_id,document_id,invoice_id,client_allocation_key,allocated_amount,
        invoice_no_snapshot,invoice_date_snapshot,due_date_snapshot)
      VALUES(v_company,v_document.id,v_invoice.id,v_client_key,v_amount,
        v_invoice.invoice_no,v_invoice.invoice_date,v_due);
    END IF;
    v_total:=v_total+v_amount;
  END LOOP;
  IF round(COALESCE(p_received_amount,0),4)<>round(v_total,4) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_AMOUNT_MISMATCH';
  END IF;
  UPDATE public.customer_receipt_documents SET total_amount=v_total,received_amount=v_total,
    updated_at=clock_timestamp() WHERE company_id=v_company AND id=v_document.id
  RETURNING * INTO v_document;
  INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_document.id,
      CASE WHEN v_is_new THEN 'CREATE' ELSE 'UPDATE' END,v_actor,v_before,to_jsonb(v_document));
  RETURN jsonb_build_object('documentId',v_document.id,'receiptNo',v_document.receipt_no,
    'status',v_document.status,'totalAmount',v_document.total_amount,
    'receivedAmount',v_document.received_amount,'unappliedAmount',0,
    'unappliedDisposition','NONE','masterVersion',v_document.master_version);
END
$$;

-- The canonical Finance journal remains one Debit Cash/Bank and one Credit AR.
-- Only the source-total reconciliation is widened to both typed allocation tables.
CREATE OR REPLACE FUNCTION private.post_customer_receipt_financial_event_core(
  p_company_id uuid,p_event_id uuid,p_expected_event_version bigint,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_event public.financial_events%rowtype;v_document public.customer_receipt_documents%rowtype;
  v_period public.accounting_periods%rowtype;v_journal public.finance_journals%rowtype;
  v_receipt_account public.chart_of_accounts%rowtype;v_ar_account public.chart_of_accounts%rowtype;
  v_accounting_date date;v_journal_type text:='AUTOMATIC';
  v_allocation_total numeric(20,4);v_amount numeric(20,4);v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;
  IF v_event.status::text='POSTED' THEN
    SELECT * INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
      AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',true);
  END IF;
  IF v_event.status::text<>'HOLD' OR v_event.system_event_key<>'SALE_PAYMENT'
    OR v_event.event_type::text<>'PAYMENT_RECEIVED'
    OR v_event.source_table<>'customer_receipt_documents' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'G6_FINANCIAL_EVENT|'||p_company_id||'|'||p_event_id,0));
  IF EXISTS(SELECT 1 FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_JOURNAL_IDENTITY_CONFLICT';
  END IF;
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=p_company_id AND document.id=v_event.source_id
    AND document.status='POSTED' AND document.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FINAL'; END IF;
  SELECT round(
    COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_allocations allocation
      WHERE allocation.company_id=p_company_id AND allocation.document_id=v_document.id),0)
    +COALESCE((SELECT sum(allocation.allocated_amount)
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      WHERE allocation.company_id=p_company_id AND allocation.document_id=v_document.id),0),4)
  INTO v_allocation_total;
  v_amount:=round(v_document.total_amount,4);
  IF v_amount<=0 OR v_amount<>v_allocation_total
    OR v_amount<>round((v_event.amounts->>'receiptAmount')::numeric,4)
    OR v_document.customer_id IS DISTINCT FROM NULLIF(v_event.amounts->>'customerId','')::uuid
    OR v_document.receipt_account_id_snapshot IS DISTINCT FROM NULLIF(v_event.amounts->>'receiptAccountId','')::uuid
    OR v_document.receivable_account_id_snapshot IS DISTINCT FROM NULLIF(v_event.amounts->>'receivableAccountId','')::uuid THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;
  SELECT * INTO v_receipt_account FROM public.chart_of_accounts account
  WHERE account.company_id=p_company_id AND account.id=v_document.receipt_account_id_snapshot
    AND account.is_active AND account.is_postable;
  IF NOT FOUND THEN RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INVALID'; END IF;
  SELECT * INTO v_ar_account FROM public.chart_of_accounts account
  WHERE account.company_id=p_company_id AND account.id=v_document.receivable_account_id_snapshot
    AND account.is_active AND account.is_postable;
  IF NOT FOUND THEN RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INVALID'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_event.event_date::date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_event.event_date::date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_event.event_date::date; END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,description,status,created_by)
  VALUES(p_company_id,'G6-'||replace(v_event.id::text,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_event.event_date::date,v_event.source_table,
    v_event.source_id,v_event.event_version,v_event.id,
    'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,20260827110000,
    'Penerimaan Customer: '||v_document.receipt_no,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,customer_id,description) VALUES
    (p_company_id,v_journal.id,1,v_receipt_account.id,v_amount,0,v_document.customer_id,
      'PENERIMAAN_CUSTOMER_'||v_document.settlement_route_snapshot),
    (p_company_id,v_journal.id,2,v_ar_account.id,0,v_amount,v_document.customer_id,
      'PELUNASAN_PIUTANG_CUSTOMER');
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
  WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,processed_at=v_now,
    error_message=NULL,transaction_rule_version=20260827110000
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',false);
END
$$;

CREATE FUNCTION public.post_customer_receipt_allocated(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_document public.customer_receipt_documents%rowtype;
  v_allocation record;v_paid numeric(20,4);v_total numeric(20,4);v_result jsonb;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','POST');
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.status='POSTED' AND v_document.posting_idempotency_key=p_idempotency_key THEN
    v_result:=public.post_customer_receipt(p_document_id,p_master_version,p_idempotency_key);
    FOR v_allocation IN
      SELECT DISTINCT allocation.invoice_id
      FROM public.customer_receipt_backoffice_invoice_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id
      ORDER BY allocation.invoice_id
    LOOP
      PERFORM private.reconcile_backoffice_invoice_receivable_schedule(
        v_company,v_allocation.invoice_id);
    END LOOP;
    RETURN v_result;
  END IF;
  IF v_document.status<>'DRAFT' OR v_document.unapplied_disposition<>'NONE' THEN
    RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE';
  END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  SELECT round(COALESCE((SELECT sum(allocated_amount) FROM public.customer_receipt_allocations
      WHERE company_id=v_company AND document_id=v_document.id),0)
    +COALESCE((SELECT sum(allocated_amount)
      FROM public.customer_receipt_backoffice_invoice_allocations
      WHERE company_id=v_company AND document_id=v_document.id),0),4) INTO v_total;
  IF v_total<=0 OR v_total<>round(v_document.total_amount,4) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_ALLOCATION_TOTAL_INVALID';
  END IF;
  FOR v_allocation IN
    SELECT allocation.invoice_id,allocation.allocated_amount
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id
    ORDER BY allocation.invoice_id
  LOOP
    PERFORM 1 FROM public.backoffice_sales_invoices invoice
    WHERE invoice.company_id=v_company AND invoice.id=v_allocation.invoice_id
      AND invoice.status='POSTED' AND invoice.customer_id=v_document.customer_id
      AND invoice.invoice_date<=v_document.receipt_date FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_NOT_PAYMENT_ELIGIBLE'; END IF;
    SELECT COALESCE(sum(allocation.allocated_amount),0) INTO v_paid
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    JOIN public.customer_receipt_documents receipt
      ON receipt.company_id=allocation.company_id AND receipt.id=allocation.document_id
     AND receipt.status='POSTED'
    WHERE allocation.company_id=v_company AND allocation.invoice_id=v_allocation.invoice_id;
    IF v_allocation.allocated_amount>
      private.backoffice_invoice_receivable_before_receipts(
        v_company,v_allocation.invoice_id,v_document.receipt_date)-v_paid THEN
      RAISE EXCEPTION 'CUSTOMER_RECEIPT_OUTSTANDING_CHANGED';
    END IF;
  END LOOP;
  v_result:=public.post_customer_receipt(p_document_id,p_master_version,p_idempotency_key);
  FOR v_allocation IN
    SELECT DISTINCT allocation.invoice_id
    FROM public.customer_receipt_backoffice_invoice_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id
    ORDER BY allocation.invoice_id
  LOOP
    PERFORM private.reconcile_backoffice_invoice_receivable_schedule(
      v_company,v_allocation.invoice_id);
  END LOOP;
  RETURN v_result;
END
$$;

REVOKE ALL ON FUNCTION
  private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date),
  private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid),
  private.post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.backoffice_invoice_receivable_before_receipts(uuid,uuid,date),
  private.reconcile_backoffice_invoice_receivable_schedule(uuid,uuid),
  private.post_customer_receipt_financial_event_core(uuid,uuid,bigint,uuid)
  TO service_role;
REVOKE ALL ON FUNCTION
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb),
  public.post_customer_receipt_allocated(uuid,bigint,uuid)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.save_customer_receipt_allocated_draft(uuid,bigint,uuid,date,uuid,text,text,text,numeric,jsonb),
  public.post_customer_receipt_allocated(uuid,bigint,uuid)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911160000','backoffice_sales_payment_collection_runtime',
  'Add typed Backoffice Invoice allocations to canonical Customer Receipt; preserve Retail allocation RPCs; final POST remains one atomic Debit Cash/Bank Credit AR journal and reconciles receivable schedules without Stock, DO, POS or Invoice-document mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
