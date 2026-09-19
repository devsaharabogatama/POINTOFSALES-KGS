-- Correct retained Retail Credit Note AR/refund split and repair the exact note append-only.
BEGIN;
DO $guard$
DECLARE v_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
    WHERE version IN('20260917151000','20260918150000','20260919110000'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Refund reversal guard, retained Credit, and Customer Receipt alignment required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260919131000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260919131000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_retained_retail_credit_note_core(uuid,bigint,uuid)'::regprocedure)
    INTO STRICT v_definition;
  IF position('v_sale.sisa_piutang-v_receipts-v_prior_ar' IN v_definition)=0
    OR position('odr6d_dispatched_receivable_before_receipts' IN v_definition)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Credit split runtime drift';
  END IF;
  IF (SELECT count(*) FROM public.backoffice_sales_credit_notes note
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=note.company_id
      AND invoice.sales_id=note.source_retail_sales_id
    WHERE note.credit_note_no='CN-20260919-0000000012'
      AND invoice.invoice_no='INV-20260904-0000000236'
      AND note.status='POSTED' AND note.source_kind='RETAINED_RETAIL'
      AND note.ar_reduction_amount=0
      AND note.refund_liability_amount=note.grand_total)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact Credit Note/Invoice split drift';
  END IF;
  IF (SELECT count(*) FROM public.backoffice_sales_customer_refunds refund
    JOIN public.backoffice_sales_credit_notes note ON note.company_id=refund.company_id
      AND note.id=refund.credit_note_id
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=note.company_id
      AND invoice.sales_id=note.source_retail_sales_id
    WHERE note.credit_note_no='CN-20260919-0000000012'
      AND invoice.invoice_no='INV-20260904-0000000236'
      AND refund.document_kind='REFUND' AND refund.status='POSTED'
      AND refund.amount=78400 AND refund.reversal_of_refund_id IS NULL
      AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_customer_refunds reversal
        WHERE reversal.company_id=refund.company_id
          AND reversal.reversal_of_refund_id=refund.id))<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact Refund is not singly reversible';
  END IF;
  IF EXISTS(SELECT 1 FROM public.customer_receipt_allocations allocation
    JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
      AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    JOIN public.backoffice_sales_credit_notes note ON note.company_id=allocation.company_id
      AND note.source_retail_sales_id=allocation.sales_id
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=note.company_id
      AND invoice.sales_id=note.source_retail_sales_id
    WHERE note.credit_note_no='CN-20260919-0000000012'
      AND invoice.invoice_no='INV-20260904-0000000236') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact Invoice already has Customer Receipt history';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_journals journal
    JOIN public.backoffice_sales_credit_notes note ON note.company_id=journal.company_id
      AND note.id=journal.source_id
    JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=note.company_id
      AND invoice.sales_id=note.source_retail_sales_id
    WHERE note.credit_note_no='CN-20260919-0000000012'
      AND invoice.invoice_no='INV-20260904-0000000236'
      AND journal.source_type='RETAINED_CREDIT_SPLIT_RECLASSIFICATION') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact correction Journal already exists';
  END IF;
END
$guard$;

DO $runtime$
DECLARE v_definition text;v_old text;v_new text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.post_retained_retail_credit_note_core(uuid,bigint,uuid)'::regprocedure)
    INTO STRICT v_definition;
  v_old:='round(v_sale.sisa_piutang-v_receipts-v_prior_ar,4),';
  v_new:='round(private.odr6d_dispatched_receivable_before_receipts(
      v_company,v_sale.id,v_note.credit_note_date)-v_receipts-v_prior_ar,4),';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: retained Credit split anchor count %',v_count;
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$runtime$;

DO $repair$
DECLARE
  v_note public.backoffice_sales_credit_notes%rowtype;
  v_sale public.sales_headers%rowtype;v_event public.financial_events%rowtype;
  v_source_journal public.finance_journals%rowtype;v_period public.accounting_periods%rowtype;
  v_refund public.backoffice_sales_customer_refunds%rowtype;
  v_refund_event public.financial_events%rowtype;
  v_refund_journal public.finance_journals%rowtype;
  v_reversal_event public.financial_events%rowtype;
  v_reversal_journal public.finance_journals%rowtype;
  v_receipts numeric(24,4);v_prior_ar numeric(24,4);v_outstanding numeric(24,4);
  v_expected_ar numeric(24,4);v_delta numeric(24,4);v_refund_account uuid;v_ar_account uuid;
  v_journal uuid:=gen_random_uuid();v_before jsonb;v_actor uuid;
  v_reversal_id uuid:=gen_random_uuid();v_reversal_operation uuid:=gen_random_uuid();
  v_refund_no text;v_timezone text;v_reversal_date date;v_accounting_date date;
  v_line record;v_refund_snapshot jsonb;
BEGIN
  SELECT note.* INTO STRICT v_note
  FROM public.backoffice_sales_credit_notes note
  JOIN public.sales_invoice_snapshots invoice ON invoice.company_id=note.company_id
    AND invoice.sales_id=note.source_retail_sales_id
  WHERE note.credit_note_no='CN-20260919-0000000012'
    AND invoice.invoice_no='INV-20260904-0000000236' FOR UPDATE OF note;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_note.company_id::text||':RETAINED_RETAIL_CREDIT:'||v_note.source_retail_sales_id::text,0));
  SELECT * INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_note.company_id AND sale.id=v_note.source_retail_sales_id FOR UPDATE;
  SELECT refund.* INTO STRICT v_refund
  FROM public.backoffice_sales_customer_refunds refund
  WHERE refund.company_id=v_note.company_id AND refund.credit_note_id=v_note.id
    AND refund.document_kind='REFUND' AND refund.status='POSTED'
    AND refund.amount=78400 AND refund.reversal_of_refund_id IS NULL
    AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_customer_refunds reversal
      WHERE reversal.company_id=refund.company_id AND reversal.reversal_of_refund_id=refund.id)
  FOR UPDATE OF refund;
  SELECT * INTO STRICT v_refund_event FROM public.financial_events event
  WHERE event.company_id=v_refund.company_id AND event.id=v_refund.financial_event_id;
  SELECT * INTO STRICT v_refund_journal FROM public.finance_journals journal
  WHERE journal.company_id=v_refund.company_id
    AND journal.financial_event_id=v_refund.financial_event_id
    AND journal.status='POSTED' FOR SHARE;
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO STRICT v_timezone,v_reversal_date FROM public.companies company
  WHERE company.id=v_note.company_id AND company.status='ACTIVE';
  IF v_reversal_date<v_refund.refund_date THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Company date predates exact Refund';
  END IF;
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_note.company_id AND v_reversal_date
    BETWEEN period.start_date AND period.end_date AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO STRICT v_period FROM public.accounting_periods period
    WHERE period.company_id=v_note.company_id AND period.start_date>v_reversal_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  END IF;
  v_accounting_date:=greatest(v_reversal_date,v_period.start_date);
  v_actor:=COALESCE(v_refund.posted_by,v_note.posted_by,v_refund_journal.posted_by,
    v_refund_journal.created_by);
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact Refund reversal actor unavailable';
  END IF;
  v_refund_no:='RFR/'||to_char(v_reversal_date,'YYYY/MM')||'/'||
    lpad(nextval('private.backoffice_sales_customer_refund_no_seq')::text,8,'0');
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
    event_date,event_version,idempotency_key,payment_method,amounts,status,error_message,
    created_by,company_id,store_id,system_event_key,transaction_category_id,
    transaction_rule_version)
  VALUES(gen_random_uuid(),'BO-RFR-'||replace(v_reversal_id::text,'-',''),
    'SALES_REFUND'::public.event_type,'backoffice_sales_customer_refunds',v_reversal_id,
    (v_reversal_date::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone,1,
    'BACKOFFICE_CUSTOMER_REFUND_REVERSAL|'||v_note.company_id||'|'||v_reversal_id,
    v_refund.payment_method_name_snapshot,jsonb_build_object('refundId',v_reversal_id,
      'reversalOfRefundId',v_refund.id,'creditNoteId',v_note.id,'amount',v_refund.amount,
      'reason','Koreksi Refund salah klasifikasi AR','financePostingState','HOLD'),
    'HOLD'::public.event_status,'CANONICAL_FINANCE_POSTING_PENDING',v_actor,
    v_note.company_id,v_refund.store_id,'BACKOFFICE_CUSTOMER_REFUND',
    v_refund_event.transaction_category_id,20260919131000)
  RETURNING * INTO v_reversal_event;
  INSERT INTO public.backoffice_sales_customer_refunds(id,company_id,credit_note_id,
    return_id,source_invoice_id,customer_id,store_id,warehouse_id,refund_no,
    document_kind,status,refund_date,amount,payment_method_id,
    payment_method_name_snapshot,payment_method_type_snapshot,
    settlement_route_snapshot,settlement_account_function_snapshot,reference_no,
    notes,reversal_of_refund_id,financial_event_id,created_by,posted_by)
  VALUES(v_reversal_id,v_note.company_id,v_refund.credit_note_id,v_refund.return_id,
    v_refund.source_invoice_id,v_refund.customer_id,v_refund.store_id,v_refund.warehouse_id,
    v_refund_no,'REVERSAL','POSTED',v_reversal_date,v_refund.amount,
    v_refund.payment_method_id,v_refund.payment_method_name_snapshot,
    v_refund.payment_method_type_snapshot,v_refund.settlement_route_snapshot,
    v_refund.settlement_account_function_snapshot,v_refund.reference_no,
    'Koreksi Refund salah klasifikasi: Retur mengurangi piutang Invoice',v_refund.id,
    v_reversal_event.id,v_actor,v_actor);
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,reversal_of_journal_id,created_by)
  VALUES(v_note.company_id,'RFRJ-'||replace(v_reversal_id::text,'-',''),'REVERSAL',
    v_period.id,v_accounting_date,v_reversal_date,'backoffice_sales_customer_refunds',
    v_reversal_id,1,v_reversal_event.id,
    'BACKOFFICE_CUSTOMER_REFUND_REVERSAL_JOURNAL|'||v_note.company_id||'|'||v_reversal_id,
    'BACKOFFICE_CUSTOMER_REFUND',v_refund_event.transaction_category_id,20260919131000,
    v_refund.store_id,v_refund.warehouse_id,
    'Reversal Refund salah klasifikasi '||v_refund.refund_no,'DRAFT',
    v_refund_journal.id,v_actor) RETURNING * INTO v_reversal_journal;
  FOR v_line IN SELECT line.* FROM public.finance_journal_lines line
    WHERE line.company_id=v_note.company_id AND line.journal_id=v_refund_journal.id
    ORDER BY line.line_no
  LOOP
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,supplier_id,description)
    VALUES(v_note.company_id,v_reversal_journal.id,v_line.line_no,v_line.account_id,
      v_line.credit,v_line.debit,v_line.store_id,v_line.warehouse_id,v_line.customer_id,
      v_line.supplier_id,'Reversal koreksi: '||COALESCE(v_line.description,''));
  END LOOP;
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp() WHERE company_id=v_note.company_id
      AND id=v_reversal_journal.id RETURNING * INTO v_reversal_journal;
  IF v_reversal_journal.total_debit<>v_refund_journal.total_credit
    OR v_reversal_journal.total_credit<>v_refund_journal.total_debit THEN
    RAISE EXCEPTION 'MIGRATION_RECONCILIATION_FAILED: Refund reversal Journal mismatch';
  END IF;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=clock_timestamp(),error_message=NULL,
    transaction_rule_version=20260919131000
  WHERE company_id=v_note.company_id AND id=v_reversal_event.id;
  v_refund_snapshot:=private.backoffice_sales_customer_refund_snapshot(
    v_note.company_id,v_reversal_id);
  INSERT INTO public.backoffice_sales_customer_refund_operations(company_id,operation_id,
    operation_type,credit_note_id,refund_id,expected_version,request_hash,
    response_snapshot,actor_id)
  VALUES(v_note.company_id,v_reversal_operation,'REVERSE',v_note.id,v_reversal_id,
    v_refund.master_version,encode(extensions.digest(convert_to(jsonb_build_object(
      'refundId',v_refund.id,'reversalDate',v_reversal_date,
      'reason','Koreksi Refund salah klasifikasi AR')::text,'UTF8'),'sha256'),'hex'),
    jsonb_build_object('companyId',v_note.company_id,'data',v_refund_snapshot,
      'exactRetry',false),v_actor);
  INSERT INTO public.backoffice_sales_customer_refund_audit(company_id,credit_note_id,
    refund_id,operation_id,action,actor_id,after_state)
  VALUES(v_note.company_id,v_note.id,v_reversal_id,v_reversal_operation,'REVERSE',
    v_actor,v_refund_snapshot);
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_receipts
  FROM public.customer_receipt_allocations allocation
  JOIN public.customer_receipt_documents receipt ON receipt.company_id=allocation.company_id
    AND receipt.id=allocation.document_id AND receipt.status='POSTED'
    AND receipt.receipt_date<=v_note.credit_note_date
  WHERE allocation.company_id=v_note.company_id AND allocation.sales_id=v_sale.id;
  SELECT round(COALESCE(sum(other.ar_reduction_amount),0),4) INTO v_prior_ar
  FROM public.backoffice_sales_credit_notes other
  WHERE other.company_id=v_note.company_id AND other.source_kind='RETAINED_RETAIL'
    AND other.source_retail_sales_id=v_sale.id AND other.status='POSTED'
    AND other.id<>v_note.id
    AND (other.credit_note_date,other.posted_at,other.id)
      <(v_note.credit_note_date,v_note.posted_at,v_note.id);
  v_outstanding:=greatest(0,round(private.odr6d_dispatched_receivable_before_receipts(
    v_note.company_id,v_sale.id,v_note.credit_note_date)-v_receipts-v_prior_ar,4));
  v_expected_ar:=least(v_note.grand_total,v_outstanding);
  v_delta:=round(v_expected_ar-v_note.ar_reduction_amount,4);
  IF v_delta<=0 OR v_delta>v_note.refund_liability_amount THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: exact correction delta invalid %',v_delta;
  END IF;
  SELECT * INTO STRICT v_event FROM public.financial_events event
  WHERE event.company_id=v_note.company_id AND event.id=v_note.financial_event_id;
  SELECT * INTO STRICT v_source_journal FROM public.finance_journals journal
  WHERE journal.company_id=v_note.company_id AND journal.financial_event_id=v_event.id
    AND journal.status='POSTED';
  v_refund_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_REFUND_LIABILITY');
  v_ar_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=v_note.company_id AND v_note.credit_note_date
    BETWEEN period.start_date AND period.end_date AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO STRICT v_period FROM public.accounting_periods period
    WHERE period.company_id=v_note.company_id AND period.start_date>v_note.credit_note_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  END IF;
  v_actor:=COALESCE(v_note.posted_by,v_source_journal.posted_by,v_source_journal.created_by);
  v_before:=private.backoffice_sales_credit_note_snapshot(v_note.company_id,v_note.id);
  INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,idempotency_key,system_event_key,transaction_category_id,
    transaction_rule_version,store_id,warehouse_id,description,status,created_by)
  VALUES(v_journal,v_note.company_id,'CNRC-'||replace(v_note.id::text,'-',''),
    'PRIOR_PERIOD_ADJUSTMENT',v_period.id,greatest(v_note.credit_note_date,v_period.start_date),
    v_note.credit_note_date,'RETAINED_CREDIT_SPLIT_RECLASSIFICATION',v_note.id,
    v_note.master_version,'RETAINED_CREDIT_SPLIT_RECLASS|'||v_note.company_id||'|'||v_note.id,
    'CUSTOMER_CREDIT_NOTE',v_event.transaction_category_id,v_event.transaction_rule_version,
    v_note.store_id,v_note.warehouse_id,
    'Reklasifikasi kewajiban refund menjadi pengurang piutang '||v_note.credit_note_no,
    'DRAFT',v_actor);
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,warehouse_id,customer_id,description) VALUES
    (v_note.company_id,v_journal,10,v_refund_account,v_delta,0,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Koreksi kewajiban refund Customer'),
    (v_note.company_id,v_journal,20,v_ar_account,0,v_delta,v_note.store_id,
      v_note.warehouse_id,v_note.customer_id,'Koreksi pengurang piutang Customer');
  UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp() WHERE company_id=v_note.company_id AND id=v_journal;
  UPDATE public.backoffice_sales_credit_notes SET
    ar_reduction_amount=ar_reduction_amount+v_delta,
    refund_liability_amount=refund_liability_amount-v_delta,
    master_version=master_version+1,updated_by=v_actor,updated_at=clock_timestamp()
  WHERE company_id=v_note.company_id AND id=v_note.id;
  UPDATE public.backoffice_sales_returns document SET status=CASE
    WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=document.company_id AND note.return_id=document.id
        AND note.status='DRAFT') THEN 'CREDIT_PENDING'
    WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_credit_notes note
      WHERE note.company_id=document.company_id AND note.return_id=document.id
        AND note.status='POSTED' AND note.refund_liability_amount>0) THEN 'REFUND_PENDING'
    ELSE 'COMPLETED' END,master_version=master_version+1,
    updated_by=v_actor,updated_at=clock_timestamp()
  WHERE document.company_id=v_note.company_id AND document.id=v_note.return_id;
  IF (SELECT total_debit FROM public.finance_journals WHERE id=v_journal)<>v_delta
    OR (SELECT total_credit FROM public.finance_journals WHERE id=v_journal)<>v_delta THEN
    RAISE EXCEPTION 'MIGRATION_RECONCILIATION_FAILED: correction Journal unbalanced';
  END IF;
END
$repair$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919131000','retained_credit_note_ar_split_fix',
  'Uses dispatch-effective Retail receivable for future retained Credit Note AR/refund splits, reverses the erroneous posted Refund append-only, and reclassifies exact CN-20260919-0000000012 / INV-20260904-0000000236 from Refund Liability to Customer Receivable without rewriting original Journals');
NOTIFY pgrst,'reload schema';
COMMIT;
