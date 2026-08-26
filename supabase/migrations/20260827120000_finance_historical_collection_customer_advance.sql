-- F3 Historical collection and explicit Customer advance.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260827110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt posting runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260827120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.customer_receipt_documents) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt documents require dedicated backfill review';
  END IF;
END
$guard$;

ALTER TABLE public.customer_receipt_documents
  ADD COLUMN received_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN unapplied_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
  ADD COLUMN unapplied_disposition TEXT NOT NULL DEFAULT 'NONE',
  ADD COLUMN customer_balance_ledger_entry_id UUID,
  ADD COLUMN advance_liability_account_id_snapshot UUID;

ALTER TABLE public.customer_receipt_documents
  DROP CONSTRAINT customer_receipt_lifecycle_check,
  ADD CONSTRAINT customer_receipt_unapplied_disposition_check
    CHECK(unapplied_disposition IN('NONE','CUSTOMER_BALANCE')),
  ADD CONSTRAINT customer_receipt_received_amount_check CHECK(received_amount>=0),
  ADD CONSTRAINT customer_receipt_unapplied_amount_check CHECK(unapplied_amount>=0),
  ADD CONSTRAINT customer_receipt_amount_disposition_check CHECK(
    received_amount=total_amount+unapplied_amount AND (
      (unapplied_disposition='NONE' AND unapplied_amount=0
        AND customer_balance_ledger_entry_id IS NULL
        AND advance_liability_account_id_snapshot IS NULL)
      OR
      (unapplied_disposition='CUSTOMER_BALANCE' AND total_amount=0
        AND unapplied_amount=received_amount AND received_amount>0
        AND ((status='POSTED' AND customer_balance_ledger_entry_id IS NOT NULL
          AND advance_liability_account_id_snapshot IS NOT NULL)
          OR (status<>'POSTED' AND customer_balance_ledger_entry_id IS NULL
            AND advance_liability_account_id_snapshot IS NULL)))
    )
  ),
  ADD CONSTRAINT customer_receipt_lifecycle_check CHECK(
    (status='DRAFT' AND posted_at IS NULL AND canceled_at IS NULL
      AND financial_event_id IS NULL)
    OR (status='POSTED' AND posted_by IS NOT NULL AND posted_at IS NOT NULL
      AND posting_idempotency_key IS NOT NULL AND financial_event_id IS NOT NULL
      AND receipt_account_id_snapshot IS NOT NULL
      AND ((unapplied_disposition='NONE' AND receivable_account_id_snapshot IS NOT NULL)
        OR (unapplied_disposition='CUSTOMER_BALANCE'
          AND advance_liability_account_id_snapshot IS NOT NULL
          AND customer_balance_ledger_entry_id IS NOT NULL)))
    OR (status='CANCELED' AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
      AND btrim(COALESCE(cancel_reason,''))<>'' AND financial_event_id IS NULL)
  ),
  ADD CONSTRAINT customer_receipt_advance_liability_fk
    FOREIGN KEY(company_id,advance_liability_account_id_snapshot)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT customer_receipt_balance_ledger_fk
    FOREIGN KEY(company_id,customer_balance_ledger_entry_id)
    REFERENCES public.customer_balance_ledger_entries(company_id,id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX uq_customer_receipt_balance_ledger
  ON public.customer_receipt_documents(company_id,customer_balance_ledger_entry_id)
  WHERE customer_balance_ledger_entry_id IS NOT NULL;

CREATE FUNCTION private.trg_f3_normalize_allocated_receipt_amount()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.unapplied_disposition='NONE' AND NEW.unapplied_amount=0
    AND NEW.received_amount=OLD.received_amount
    AND OLD.received_amount=OLD.total_amount THEN
    NEW.received_amount:=NEW.total_amount;
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER f3_normalize_allocated_receipt_amount
BEFORE UPDATE OF total_amount ON public.customer_receipt_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_f3_normalize_allocated_receipt_amount();

ALTER TABLE public.customer_balance_ledger_entries
  DROP CONSTRAINT customer_balance_ledger_source_check,
  ADD CONSTRAINT customer_balance_ledger_source_check CHECK(
    source_type IN('MANUAL_CORRECTION','SALE_OVERPAYMENT','SALE_PAYMENT','CUSTOMER_RECEIPT'));

CREATE OR REPLACE FUNCTION private.trg_g4_customer_balance_source_integrity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.source_type='MANUAL_CORRECTION' THEN
    IF NOT EXISTS(SELECT 1 FROM public.customer_balance_correction_requests request
      WHERE request.company_id=NEW.company_id AND request.id=NEW.source_id) THEN
      RAISE EXCEPTION 'CUSTOMER_BALANCE_CORRECTION_SOURCE_NOT_FOUND';
    END IF;
  ELSIF NEW.source_type IN('SALE_OVERPAYMENT','SALE_PAYMENT') THEN
    IF NOT EXISTS(SELECT 1 FROM public.sales_payments payment
      WHERE payment.company_id=NEW.company_id AND payment.id=NEW.source_id
        AND NOT payment.is_reversal) THEN
      RAISE EXCEPTION 'CUSTOMER_BALANCE_SALE_PAYMENT_SOURCE_NOT_FOUND';
    END IF;
  ELSIF NEW.source_type='CUSTOMER_RECEIPT' THEN
    IF NOT EXISTS(SELECT 1 FROM public.customer_receipt_documents document
      WHERE document.company_id=NEW.company_id AND document.id=NEW.source_id
        AND document.unapplied_disposition='CUSTOMER_BALANCE') THEN
      RAISE EXCEPTION 'CUSTOMER_BALANCE_RECEIPT_SOURCE_NOT_FOUND';
    END IF;
  ELSE RAISE EXCEPTION 'CUSTOMER_BALANCE_SOURCE_NOT_SUPPORTED'; END IF;
  RETURN NEW;
END
$$;

ALTER TABLE public.customer_balance_audit
  DROP CONSTRAINT customer_balance_audit_action_check,
  ADD CONSTRAINT customer_balance_audit_action_check CHECK(action IN(
    'POLICY_PROVISION','POLICY_SYNC','REQUEST_CORRECTION','APPROVE_CORRECTION',
    'REJECT_CORRECTION','AUTO_DISABLE','SALE_OVERPAYMENT_CREDIT',
    'SALE_PAYMENT_DEBIT','CUSTOMER_RECEIPT_CREDIT'));

CREATE FUNCTION public.get_customer_receipt_advance_policy()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_state TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','VIEW');
  SELECT policy.lifecycle_state INTO v_state FROM public.customer_balance_company_policies policy
  WHERE policy.company_id=v_company;
  RETURN jsonb_build_object('lifecycleState',COALESCE(v_state,'DISABLED'),
    'advanceEnabled',COALESCE(v_state='ACTIVE',FALSE));
END
$$;

CREATE FUNCTION public.save_customer_receipt_draft_with_disposition(
  p_document_id UUID,p_master_version BIGINT,p_customer_id UUID,p_receipt_date DATE,
  p_payment_method_id UUID,p_reference_no TEXT,p_evidence_url TEXT,p_notes TEXT,
  p_received_amount NUMERIC,p_unapplied_disposition TEXT,p_allocations JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_disposition TEXT:=upper(btrim(COALESCE(p_unapplied_disposition,'NONE')));
  v_document public.customer_receipt_documents%ROWTYPE;v_method public.payment_methods%ROWTYPE;
  v_before JSONB;v_policy TEXT;v_result JSONB;
BEGIN
  IF v_disposition='NONE' THEN
    v_result:=public.save_customer_receipt_draft(p_document_id,p_master_version,
      p_customer_id,p_receipt_date,p_payment_method_id,p_reference_no,p_evidence_url,
      p_notes,p_allocations);
    SELECT * INTO v_document FROM public.customer_receipt_documents document
    WHERE document.company_id=v_company AND document.id=(v_result->>'documentId')::UUID;
    RETURN v_result||jsonb_build_object('receivedAmount',v_document.received_amount,
      'unappliedAmount',v_document.unapplied_amount,'unappliedDisposition','NONE');
  END IF;
  IF v_disposition<>'CUSTOMER_BALANCE' THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DISPOSITION_INVALID'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts',
    CASE WHEN p_document_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
  IF p_received_amount IS NULL OR p_received_amount<=0 THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_AMOUNT_INVALID'; END IF;
  IF jsonb_typeof(COALESCE(p_allocations,'[]'::JSONB))<>'array'
    OR jsonb_array_length(COALESCE(p_allocations,'[]'::JSONB))<>0 THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_ADVANCE_MUST_BE_UNALLOCATED';
  END IF;
  IF p_receipt_date IS NULL OR p_receipt_date>current_date THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_INVALID'; END IF;
  IF p_evidence_url IS NOT NULL AND p_evidence_url!~*'^https://' THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_EVIDENCE_MUST_USE_HTTPS'; END IF;
  SELECT policy.lifecycle_state INTO v_policy FROM public.customer_balance_company_policies policy
  WHERE policy.company_id=v_company;
  IF v_policy<>'ACTIVE' THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_DISABLED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=p_customer_id AND customer.is_active AND NOT customer.is_system_customer) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_CUSTOMER_INVALID';
  END IF;
  SELECT * INTO v_method FROM public.payment_methods method WHERE method.company_id=v_company
    AND method.id=p_payment_method_id AND method.is_active
    AND method.settlement_route IN('CASH_DRAWER','DIRECT_BANK');
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_PAYMENT_METHOD_INVALID'; END IF;
  IF p_document_id IS NULL THEN
    INSERT INTO public.customer_receipt_documents(company_id,receipt_no,customer_id,
      receipt_date,payment_method_id,payment_method_name_snapshot,payment_method_type_snapshot,
      settlement_route_snapshot,reference_no,evidence_url,notes,total_amount,received_amount,
      unapplied_amount,unapplied_disposition,created_by)
    VALUES(v_company,'CR/'||to_char(p_receipt_date,'YYYY/MM')||'/'||
      lpad(nextval('private.customer_receipt_no_seq')::TEXT,6,'0'),p_customer_id,
      p_receipt_date,p_payment_method_id,v_method.payment_method_name,v_method.method_type,
      v_method.settlement_route,NULLIF(btrim(p_reference_no),''),p_evidence_url,
      NULLIF(btrim(p_notes),''),0,p_received_amount,p_received_amount,
      'CUSTOMER_BALANCE',v_actor) RETURNING * INTO v_document;
    INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,after_state)
    VALUES(v_company,v_document.id,'CREATE',v_actor,to_jsonb(v_document));
  ELSE
    SELECT * INTO v_document FROM public.customer_receipt_documents document
    WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
    IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE'; END IF;
    IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
    v_before:=to_jsonb(v_document);
    DELETE FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id;
    UPDATE public.customer_receipt_documents SET customer_id=p_customer_id,
      receipt_date=p_receipt_date,payment_method_id=p_payment_method_id,
      payment_method_name_snapshot=v_method.payment_method_name,
      payment_method_type_snapshot=v_method.method_type,
      settlement_route_snapshot=v_method.settlement_route,
      reference_no=NULLIF(btrim(p_reference_no),''),evidence_url=p_evidence_url,
      notes=NULLIF(btrim(p_notes),''),total_amount=0,received_amount=p_received_amount,
      unapplied_amount=p_received_amount,unapplied_disposition='CUSTOMER_BALANCE',
      master_version=master_version+1,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
    INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,before_state,after_state)
    VALUES(v_company,v_document.id,'UPDATE',v_actor,v_before,to_jsonb(v_document));
  END IF;
  RETURN jsonb_build_object('documentId',v_document.id,'receiptNo',v_document.receipt_no,
    'status',v_document.status,'totalAmount',0,'receivedAmount',v_document.received_amount,
    'unappliedAmount',v_document.unapplied_amount,'unappliedDisposition','CUSTOMER_BALANCE',
    'masterVersion',v_document.master_version);
END
$$;

CREATE FUNCTION private.post_customer_advance_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_event public.financial_events%ROWTYPE;v_document public.customer_receipt_documents%ROWTYPE;
  v_ledger public.customer_balance_ledger_entries%ROWTYPE;v_period public.accounting_periods%ROWTYPE;
  v_journal public.finance_journals%ROWTYPE;v_accounting_date DATE;v_type TEXT:='AUTOMATIC';
  v_amount NUMERIC(20,4);v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  SELECT * INTO v_event FROM public.financial_events event WHERE event.company_id=p_company_id
    AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN RAISE EXCEPTION 'EVENT_VERSION_CONFLICT'; END IF;
  IF v_event.status::TEXT='POSTED' THEN
    SELECT * INTO STRICT v_journal FROM public.finance_journals journal WHERE journal.company_id=p_company_id
      AND journal.financial_event_id=v_event.id AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',TRUE);
  END IF;
  IF v_event.status::TEXT<>'HOLD' OR v_event.system_event_key<>'CUSTOMER_BALANCE_RECEIPT'
    OR v_event.source_table<>'customer_receipt_documents' THEN RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('G6_FINANCIAL_EVENT|'||p_company_id||'|'||p_event_id,0));
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=p_company_id AND document.id=v_event.source_id
    AND document.status='POSTED' AND document.financial_event_id=v_event.id
    AND document.unapplied_disposition='CUSTOMER_BALANCE' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FINAL'; END IF;
  SELECT * INTO v_ledger FROM public.customer_balance_ledger_entries ledger
  WHERE ledger.company_id=p_company_id AND ledger.id=v_document.customer_balance_ledger_entry_id
    AND ledger.source_type='CUSTOMER_RECEIPT' AND ledger.source_id=v_document.id
    AND ledger.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_LEDGER_SOURCE_NOT_FOUND'; END IF;
  v_amount:=round(v_document.unapplied_amount,4);
  IF v_amount<=0 OR v_amount<>round(v_ledger.amount,4)
    OR v_amount<>round((v_event.amounts->>'amount')::NUMERIC,4)
    OR v_document.customer_id IS DISTINCT FROM v_ledger.customer_id THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;
  PERFORM 1 FROM public.chart_of_accounts account WHERE account.company_id=p_company_id
    AND account.id IN(v_document.receipt_account_id_snapshot,v_document.advance_liability_account_id_snapshot)
    AND account.is_active AND account.is_postable GROUP BY account.company_id HAVING count(*)=2;
  IF NOT FOUND THEN RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INVALID'; END IF;
  SELECT * INTO v_period FROM public.accounting_periods period WHERE period.company_id=p_company_id
    AND v_event.event_date::DATE BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period WHERE period.company_id=p_company_id
      AND period.start_date>v_event.event_date::DATE AND period.status IN('OPEN','REOPENED')
      ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_event.event_date::DATE; END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,accounting_period_id,
    accounting_date,original_event_date,source_type,source_id,source_version,
    financial_event_id,idempotency_key,system_event_key,transaction_category_id,
    transaction_rule_version,description,status,created_by)
  VALUES(p_company_id,'G6-'||replace(v_event.id::TEXT,'-',''),v_type,v_period.id,
    v_accounting_date,v_event.event_date::DATE,v_event.source_table,v_event.source_id,
    v_event.event_version,v_event.id,'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,20260827120000,
    'Advance Customer: '||v_document.receipt_no,'DRAFT',p_actor_id) RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,customer_id,description) VALUES
    (p_company_id,v_journal.id,1,v_document.receipt_account_id_snapshot,v_amount,0,v_document.customer_id,'PENERIMAAN_ADVANCE_CUSTOMER'),
    (p_company_id,v_journal.id,2,v_document.advance_liability_account_id_snapshot,0,v_amount,v_document.customer_id,'CUSTOMER_BALANCE_LIABILITY');
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
  WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,processed_at=v_now,
    error_message=NULL,transaction_rule_version=20260827120000
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',FALSE);
END
$$;

CREATE OR REPLACE FUNCTION private.post_financial_event_core(
 p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_key TEXT;v_source TEXT;
BEGIN
 SELECT event.system_event_key,event.source_table INTO v_key,v_source FROM public.financial_events event
 WHERE event.company_id=p_company_id AND event.id=p_event_id;
 IF v_key='CUSTOMER_BALANCE_RECEIPT' AND v_source='customer_receipt_documents' THEN
  RETURN private.post_customer_advance_financial_event_core(p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 ELSIF v_key='SALE_PAYMENT' THEN
  RETURN private.post_customer_receipt_financial_event_core(p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 ELSIF v_key IN('SALE_POSTED','SALES_RETURN') THEN
  RETURN private.post_sale_return_financial_event_core(p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 ELSIF v_key IN('GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT') THEN
  RETURN private.post_purchase_ap_financial_event_core(p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 ELSIF v_key IN('STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE') THEN
  RETURN private.post_remaining_operational_financial_event_core(p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 END IF;
 RETURN private.post_financial_event_stock_opening_core(p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

CREATE FUNCTION public.post_customer_receipt_with_disposition(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_document public.customer_receipt_documents%ROWTYPE;v_customer public.customers%ROWTYPE;
  v_category UUID;v_source_function TEXT;v_source UUID;v_liability UUID;
  v_event UUID;v_entry UUID;v_entry_no BIGINT;v_before NUMERIC(20,4);v_after NUMERIC(20,4);
  v_timezone TEXT;v_event_at TIMESTAMPTZ;v_hash TEXT;v_posting JSONB;v_result JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,'finance.customer_receipts','POST');
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOT_FOUND'; END IF;
  IF v_document.unapplied_disposition='NONE' THEN
    RETURN public.post_customer_receipt(p_document_id,p_master_version,p_idempotency_key);
  END IF;
  IF v_document.status='POSTED' AND v_document.posting_idempotency_key=p_idempotency_key THEN
    v_posting:=private.post_financial_event_core(v_company,
      v_document.financial_event_id,1,v_actor);
    RETURN jsonb_build_object('documentId',v_document.id,'status','POSTED',
      'financialEventId',v_document.financial_event_id,'journalId',v_posting->>'journalId',
      'journalNo',v_posting->>'journalNo','idempotentReplay',TRUE);
  END IF;
  IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'FINAL_CUSTOMER_RECEIPT_IMMUTABLE'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF EXISTS(SELECT 1 FROM public.customer_receipt_allocations allocation
    WHERE allocation.company_id=v_company AND allocation.document_id=v_document.id) THEN
    RAISE EXCEPTION 'CUSTOMER_RECEIPT_ADVANCE_MUST_BE_UNALLOCATED';
  END IF;
  PERFORM 1 FROM public.customer_balance_company_policies policy
  WHERE policy.company_id=v_company AND policy.lifecycle_state='ACTIVE' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_CREDIT_DISABLED'; END IF;
  SELECT * INTO v_customer FROM public.customers customer WHERE customer.company_id=v_company
    AND customer.id=v_document.customer_id AND customer.is_active
    AND NOT customer.is_system_customer FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_CUSTOMER_INVALID'; END IF;
  PERFORM 1 FROM public.accounting_periods period WHERE period.company_id=v_company
    AND v_document.receipt_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED');
  IF NOT FOUND THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_PERIOD_NOT_OPEN'; END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  v_event_at:=(v_document.receipt_date::TEXT||' 12:00:00')::TIMESTAMP AT TIME ZONE v_timezone;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='CUSTOMER_BALANCE_RECEIPT'
    AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
  IF v_category IS NULL THEN RAISE EXCEPTION 'CUSTOMER_BALANCE_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
  v_source_function:=CASE v_document.settlement_route_snapshot WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER' ELSE 'BANK' END;
  v_source:=private.resolve_customer_balance_account(v_company,v_category,v_source_function,v_event_at);
  v_liability:=private.resolve_customer_balance_account(v_company,v_category,'CUSTOMER_BALANCE_LIABILITY',v_event_at);
  v_before:=v_customer.current_balance;v_after:=v_before+v_document.unapplied_amount;
  INSERT INTO public.financial_events(event_code,event_type,source_table,source_id,event_date,
    event_version,idempotency_key,payment_method,amounts,status,created_by,company_id,
    system_event_key,transaction_category_id)
  VALUES('CR-ADV-'||replace(p_idempotency_key::TEXT,'-',''),
    'CUSTOMER_BALANCE_ADJUSTMENT'::public.event_type,'customer_receipt_documents',v_document.id,
    v_event_at,1,'CUSTOMER_RECEIPT_ADVANCE|'||v_company||'|'||p_idempotency_key,
    v_document.payment_method_type_snapshot,jsonb_build_object('receiptNo',v_document.receipt_no,
      'customerId',v_document.customer_id,'direction','CREDIT','amount',v_document.unapplied_amount,
      'balanceBefore',v_before,'balanceAfter',v_after,'sourceAccountId',v_source,
      'liabilityAccountId',v_liability,'sourceAccountFunction',v_source_function,
      'financePostingState','HOLD'),'HOLD',v_actor,v_company,'CUSTOMER_BALANCE_RECEIPT',v_category)
  RETURNING id INTO v_event;
  v_hash:=encode(extensions.digest(convert_to(concat_ws('|',v_company,v_document.id,
    v_document.customer_id,v_document.unapplied_amount,p_idempotency_key),'UTF8'),'sha256'),'hex');
  v_entry_no:=nextval('private.customer_balance_request_no_seq');
  INSERT INTO public.customer_balance_ledger_entries(company_id,customer_id,store_id,entry_no,
    direction,amount,source_type,source_id,source_reference,reason,evidence_url,balance_before,
    balance_after,transaction_category_id,liability_account_id,source_account_id,
    source_account_function,financial_event_id,idempotency_key,payload_hash,created_by)
  VALUES(v_company,v_document.customer_id,NULL,v_entry_no,'CREDIT',v_document.unapplied_amount,
    'CUSTOMER_RECEIPT',v_document.id,v_document.receipt_no,
    'Penerimaan advance disimpan sebagai Saldo Customer',v_document.evidence_url,v_before,v_after,
    v_category,v_liability,v_source,v_source_function,v_event,p_idempotency_key,v_hash,v_actor)
  RETURNING id INTO v_entry;
  UPDATE public.customers SET current_balance=v_after,updated_by=v_actor
  WHERE company_id=v_company AND id=v_customer.id;
  UPDATE public.customer_receipt_documents SET status='POSTED',posted_by=v_actor,
    posted_at=clock_timestamp(),posting_idempotency_key=p_idempotency_key,financial_event_id=v_event,
    receipt_account_function_snapshot=v_source_function,receipt_account_id_snapshot=v_source,
    advance_liability_account_id_snapshot=v_liability,customer_balance_ledger_entry_id=v_entry,
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_document.id RETURNING * INTO v_document;
  INSERT INTO public.customer_receipt_audit(company_id,document_id,action,actor_id,after_state)
  VALUES(v_company,v_document.id,'POST',v_actor,to_jsonb(v_document));
  INSERT INTO public.customer_balance_audit(company_id,customer_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_document.customer_id,'CUSTOMER_RECEIPT_CREDIT',v_actor,
    jsonb_build_object('balance',v_before,'receiptId',v_document.id),
    jsonb_build_object('balance',v_after,'receiptId',v_document.id,'ledgerEntryId',v_entry,
      'amount',v_document.unapplied_amount));
  v_posting:=private.post_financial_event_core(v_company,v_event,1,v_actor);
  RETURN jsonb_build_object('documentId',v_document.id,'status','POSTED',
    'financialEventId',v_event,'journalId',v_posting->>'journalId',
    'journalNo',v_posting->>'journalNo','masterVersion',v_document.master_version,
    'idempotentReplay',FALSE);
END
$$;

REVOKE ALL ON FUNCTION public.get_customer_receipt_advance_policy(),
  public.save_customer_receipt_draft_with_disposition(UUID,BIGINT,UUID,DATE,UUID,TEXT,TEXT,TEXT,NUMERIC,TEXT,JSONB),
  public.post_customer_receipt_with_disposition(UUID,BIGINT,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_customer_receipt_advance_policy(),
  public.save_customer_receipt_draft_with_disposition(UUID,BIGINT,UUID,DATE,UUID,TEXT,TEXT,TEXT,NUMERIC,TEXT,JSONB),
  public.post_customer_receipt_with_disposition(UUID,BIGINT,UUID) TO authenticated,service_role;
REVOKE ALL ON FUNCTION private.trg_f3_normalize_allocated_receipt_amount(),
  private.post_customer_advance_financial_event_core(UUID,UUID,BIGINT,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_f3_normalize_allocated_receipt_amount(),
  private.post_customer_advance_financial_event_core(UUID,UUID,BIGINT,UUID) TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827120000','finance_historical_collection_customer_advance',
  'Backorder receipt dates remain actual; explicit unallocated receipt credits Customer Balance only when policy ACTIVE; no automatic revenue');
COMMIT;
