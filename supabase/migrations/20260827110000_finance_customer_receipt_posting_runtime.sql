-- F2B Customer Receipt / SALE_PAYMENT atomic journal runtime.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260827100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Receipt foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260827110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827110000';
  END IF;
  IF to_regprocedure('private.post_financial_event_core(uuid,uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Finance dispatcher required';
  END IF;
END
$guard$;

CREATE FUNCTION private.post_customer_receipt_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_document public.customer_receipt_documents%ROWTYPE;
  v_period public.accounting_periods%ROWTYPE;
  v_journal public.finance_journals%ROWTYPE;
  v_receipt_account public.chart_of_accounts%ROWTYPE;
  v_ar_account public.chart_of_accounts%ROWTYPE;
  v_accounting_date DATE;v_journal_type TEXT:='AUTOMATIC';
  v_allocation_total NUMERIC(20,4);v_amount NUMERIC(20,4);v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN RAISE EXCEPTION 'EVENT_VERSION_CONFLICT'; END IF;
  IF v_event.status::TEXT='POSTED' THEN
    SELECT * INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',TRUE);
  END IF;
  IF v_event.status::TEXT<>'HOLD' OR v_event.system_event_key<>'SALE_PAYMENT'
    OR v_event.event_type::TEXT<>'PAYMENT_RECEIVED'
    OR v_event.source_table<>'customer_receipt_documents' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('G6_FINANCIAL_EVENT|'||p_company_id||'|'||p_event_id,0));
  IF EXISTS(SELECT 1 FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_JOURNAL_IDENTITY_CONFLICT';
  END IF;
  SELECT * INTO v_document FROM public.customer_receipt_documents document
  WHERE document.company_id=p_company_id AND document.id=v_event.source_id
    AND document.status='POSTED' AND document.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FINAL'; END IF;
  SELECT round(COALESCE(sum(allocation.allocated_amount),0),4) INTO v_allocation_total
  FROM public.customer_receipt_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.document_id=v_document.id;
  v_amount:=round(v_document.total_amount,4);
  IF v_amount<=0 OR v_amount<>v_allocation_total
    OR v_amount<>round((v_event.amounts->>'receiptAmount')::NUMERIC,4)
    OR v_document.customer_id IS DISTINCT FROM NULLIF(v_event.amounts->>'customerId','')::UUID
    OR v_document.receipt_account_id_snapshot IS DISTINCT FROM NULLIF(v_event.amounts->>'receiptAccountId','')::UUID
    OR v_document.receivable_account_id_snapshot IS DISTINCT FROM NULLIF(v_event.amounts->>'receivableAccountId','')::UUID THEN
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
  WHERE period.company_id=p_company_id AND v_event.event_date::DATE BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_event.event_date::DATE
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_event.event_date::DATE; END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,description,status,created_by)
  VALUES(p_company_id,'G6-'||replace(v_event.id::TEXT,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_event.event_date::DATE,v_event.source_table,
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
    'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',FALSE);
END
$$;

CREATE OR REPLACE FUNCTION private.post_financial_event_core(
 p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_key TEXT;
BEGIN
 SELECT event.system_event_key INTO v_key FROM public.financial_events event
 WHERE event.company_id=p_company_id AND event.id=p_event_id;
 IF v_key='SALE_PAYMENT' THEN
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

ALTER FUNCTION public.post_customer_receipt(UUID,BIGINT,UUID) SET SCHEMA private;
ALTER FUNCTION private.post_customer_receipt(UUID,BIGINT,UUID) RENAME TO f2_post_customer_receipt_hold_core;

CREATE FUNCTION public.post_customer_receipt(
  p_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_result JSONB;v_event public.financial_events%ROWTYPE;v_posting JSONB;
BEGIN
  v_result:=private.f2_post_customer_receipt_hold_core(
    p_document_id,p_master_version,p_idempotency_key);
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=v_company AND event.id=(v_result->>'financialEventId')::UUID;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  v_posting:=private.post_financial_event_core(v_company,v_event.id,v_event.event_version,v_actor);
  RETURN v_result||jsonb_build_object('journalId',v_posting->>'journalId',
    'journalNo',v_posting->>'journalNo','financeStatus',v_posting->>'status');
END
$$;

REVOKE ALL ON FUNCTION private.post_customer_receipt_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.f2_post_customer_receipt_hold_core(UUID,BIGINT,UUID) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.post_customer_receipt_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.f2_post_customer_receipt_hold_core(UUID,BIGINT,UUID) TO service_role;
REVOKE ALL ON FUNCTION public.post_customer_receipt(UUID,BIGINT,UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.post_customer_receipt(UUID,BIGINT,UUID) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827110000','finance_customer_receipt_posting_runtime',
  'Atomic source-verified SALE_PAYMENT journal: debit Cash/Bank, credit Customer Receivable; exact replay and prior-period fallback');
COMMIT;

