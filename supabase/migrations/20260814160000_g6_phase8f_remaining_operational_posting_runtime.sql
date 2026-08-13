-- G6 phase 8F: atomic runtime for the seven remaining operational contracts.
-- Historical HOLD events remain untouched until a separate controlled queue.

BEGIN;
DO $guard$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
  WHERE version='20260814150000') THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8E required'; END IF;
 IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
  WHERE version='20260814160000') THEN
  RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814160000'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue exists';
 END IF;
END
$guard$;

CREATE FUNCTION private.g6_require_active_postable_snapshot_account(
 p_event public.financial_events,p_account_id UUID
) RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_account public.chart_of_accounts%ROWTYPE;
BEGIN
 IF p_account_id IS NULL THEN RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_REQUIRED'; END IF;
 SELECT * INTO v_account FROM public.chart_of_accounts account
 WHERE account.company_id=p_event.company_id AND account.id=p_account_id;
 IF NOT FOUND OR NOT v_account.is_active OR NOT v_account.is_postable THEN
  RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INVALID'; END IF;
 RETURN v_account.id;
END
$$;

CREATE FUNCTION private.post_remaining_operational_financial_event_core(
 p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
 v_event public.financial_events%ROWTYPE;
 v_adjustment public.stock_adjustment_documents%ROWTYPE;
 v_disbursement public.expense_disbursements%ROWTYPE;
 v_expense public.expense_documents%ROWTYPE;
 v_deposit public.cash_deposit_documents%ROWTYPE;
 v_request public.deposit_variance_resolution_requests%ROWTYPE;
 v_allocation public.deposit_variance_allocations%ROWTYPE;
 v_exception public.deposit_variance_exceptions%ROWTYPE;
 v_period public.accounting_periods%ROWTYPE;
 v_journal public.finance_journals%ROWTYPE;
 v_account_1 UUID; v_account_2 UUID; v_account_3 UUID;
 v_store UUID; v_warehouse UUID; v_accounting_date DATE;
 v_journal_type TEXT:='AUTOMATIC'; v_now TIMESTAMPTZ:=clock_timestamp();
 v_amount NUMERIC(20,4); v_expected NUMERIC(20,4);
 v_actual NUMERIC(20,4); v_variance NUMERIC(20,4); v_line_total NUMERIC(20,4);
 v_debit NUMERIC(20,4):=0; v_credit NUMERIC(20,4):=0; v_line_no INTEGER:=0;
BEGIN
 IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 SELECT * INTO v_event FROM public.financial_events event
 WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
 IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
  RAISE EXCEPTION 'EVENT_VERSION_CONFLICT'; END IF;
 IF v_event.status::TEXT='POSTED' THEN
  SELECT * INTO STRICT v_journal FROM public.finance_journals journal
  WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
   AND journal.status='POSTED';
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
   'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',TRUE);
 END IF;
 IF v_event.status::TEXT<>'HOLD' THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_HOLD'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(
  'G6_FINANCIAL_EVENT|'||p_company_id||'|'||p_event_id,0));
 IF EXISTS(SELECT 1 FROM public.finance_journals journal
  WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id) THEN
  RAISE EXCEPTION 'FINANCIAL_EVENT_JOURNAL_IDENTITY_CONFLICT'; END IF;

 SELECT * INTO v_period FROM public.accounting_periods period
 WHERE period.company_id=p_company_id
  AND v_event.event_date::DATE BETWEEN period.start_date AND period.end_date
  AND period.status IN('OPEN','REOPENED')
 ORDER BY period.start_date LIMIT 1 FOR SHARE;
 IF NOT FOUND THEN
  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id AND period.start_date>v_event.event_date::DATE
   AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
  v_journal_type:='PRIOR_PERIOD_ADJUSTMENT'; v_accounting_date:=v_period.start_date;
 ELSE v_accounting_date:=v_event.event_date::DATE; END IF;

 IF v_event.system_event_key='STOCK_GAIN' THEN
  IF v_event.event_type::TEXT<>'STOCK_GAIN'
   OR v_event.source_table<>'stock_adjustment_documents' THEN
   RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
  SELECT * INTO v_adjustment FROM public.stock_adjustment_documents document
  WHERE document.company_id=p_company_id AND document.id=v_event.source_id
   AND document.status='POSTED' AND document.gain_financial_event_id=v_event.id
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT round(COALESCE(sum(line.total_value),0),4) INTO v_line_total
  FROM public.stock_adjustment_lines line
  WHERE line.company_id=p_company_id AND line.document_id=v_adjustment.id
   AND line.calculated_difference>0;
  v_amount:=round(v_adjustment.total_gain_value,4);
  IF v_amount<=0 OR v_amount<>v_line_total
   OR v_amount<>round((v_event.amounts->>'inventoryDebit')::NUMERIC,4)
   OR v_amount<>round((v_event.amounts->>'stockGainCredit')::NUMERIC,4) THEN
   RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
  v_account_1:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'inventoryAccountId','')::UUID);
  v_account_2:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'counterAccountId','')::UUID);
  v_store:=v_event.store_id; v_warehouse:=v_adjustment.warehouse_id;

 ELSIF v_event.system_event_key='EXPENSE_DISBURSEMENT' THEN
  IF v_event.event_type::TEXT<>'EXPENSE_DISBURSEMENT'
   OR v_event.source_table<>'expense_disbursements' THEN
   RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
  SELECT * INTO v_disbursement FROM public.expense_disbursements disbursement
  WHERE disbursement.company_id=p_company_id AND disbursement.id=v_event.source_id
   AND disbursement.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT * INTO v_expense FROM public.expense_documents document
  WHERE document.company_id=p_company_id AND document.id=v_disbursement.document_id
   AND document.status IN('DISBURSED','PARTIALLY_SETTLED','SETTLED','SETTLED_NO_EXPENSE')
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FINAL'; END IF;
  v_amount:=round(v_disbursement.amount,4);
  IF v_amount<=0 OR v_amount<>round((v_event.amounts->>'disbursedAmount')::NUMERIC,4)
   OR round(v_expense.requested_amount,4)<>
      round((v_event.amounts->>'requestedAmount')::NUMERIC,4)
   OR v_expense.disbursed_amount<v_disbursement.amount
   OR v_disbursement.cashier_session_id IS DISTINCT FROM
      NULLIF(v_event.amounts->>'cashierSessionId','')::UUID THEN
   RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
  v_account_1:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'outstandingAccountId','')::UUID);
  v_account_2:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'paymentAccountId','')::UUID);
  v_store:=v_expense.store_id;

 ELSIF v_event.system_event_key='CASH_DEPOSIT' THEN
  IF v_event.event_type::TEXT<>'BANK_DEPOSIT'
   OR v_event.source_table<>'cash_deposit_documents' THEN
   RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
  SELECT * INTO v_deposit FROM public.cash_deposit_documents document
  WHERE document.company_id=p_company_id AND document.id=v_event.source_id
   AND document.status='APPROVED' AND document.financial_event_id=v_event.id
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT round(COALESCE(sum(line.expected_deposit_amount),0),4) INTO v_line_total
  FROM public.cash_deposit_session_lines line
  WHERE line.company_id=p_company_id AND line.deposit_document_id=v_deposit.id
   AND line.allocation_status='POSTED';
  v_actual:=round(v_deposit.actual_deposit_amount,4);
  v_expected:=round(v_deposit.total_expected_deposit,4);
  v_variance:=round(v_deposit.deposit_variance,4);
  IF v_actual<=0 OR v_expected<>v_line_total OR v_variance<>v_actual-v_expected
   OR v_actual<>round((v_event.amounts->>'actualDeposit')::NUMERIC,4)
   OR v_expected<>round((v_event.amounts->>'expectedDeposit')::NUMERIC,4)
   OR v_variance<>round((v_event.amounts->>'depositVariance')::NUMERIC,4) THEN
   RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
  v_account_1:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'destinationAccountId','')::UUID);
  v_account_2:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'cashDrawerAccountId','')::UUID);
  IF v_variance<>0 THEN
   v_account_3:=private.g6_require_active_postable_snapshot_account(v_event,
    NULLIF(v_event.amounts->>'varianceAccountId','')::UUID); END IF;
  v_store:=v_deposit.store_id;

 ELSIF v_event.system_event_key='CASH_VARIANCE' THEN
  IF v_event.event_type::TEXT<>'DEPOSIT_VARIANCE_RESOLUTION'
   OR v_event.source_table<>'deposit_variance_resolution_requests' THEN
   RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
  SELECT * INTO v_request FROM public.deposit_variance_resolution_requests request
  WHERE request.company_id=p_company_id AND request.id=v_event.source_id
   AND request.status='APPROVED' AND request.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT * INTO v_allocation FROM public.deposit_variance_allocations allocation
  WHERE allocation.company_id=p_company_id AND allocation.id=v_request.allocation_id
   AND allocation.resolution_request_id=v_request.id
   AND allocation.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_ALLOCATION_NOT_FOUND'; END IF;
  SELECT * INTO v_exception FROM public.deposit_variance_exceptions exception
  WHERE exception.company_id=p_company_id AND exception.id=v_request.variance_exception_id
  FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_EXCEPTION_NOT_FOUND'; END IF;
  v_amount:=round(v_request.allocation_amount,4);
  IF v_amount<=0 OR v_amount<>round(v_allocation.allocation_amount,4)
   OR v_amount<>round((v_event.amounts->>'allocationAmount')::NUMERIC,4)
   OR v_request.resolution_type<>(v_event.amounts->>'resolutionType')
   OR v_exception.variance_type<>(v_event.amounts->>'varianceType') THEN
   RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
  v_account_1:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'controlAccountId','')::UUID);
  v_account_2:=private.g6_require_active_postable_snapshot_account(v_event,
   NULLIF(v_event.amounts->>'resolutionAccountId','')::UUID);
  v_store:=v_request.store_id;
 ELSE RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;

 INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
  accounting_period_id,accounting_date,original_event_date,source_type,source_id,
  source_version,financial_event_id,idempotency_key,system_event_key,
  transaction_category_id,transaction_rule_version,store_id,warehouse_id,
  description,status,created_by)
 VALUES(p_company_id,'G6-'||replace(v_event.id::TEXT,'-',''),v_journal_type,
  v_period.id,v_accounting_date,v_event.event_date::DATE,v_event.source_table,
  v_event.source_id,v_event.event_version,v_event.id,
  'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
  v_event.system_event_key,v_event.transaction_category_id,20260814160000,
  v_store,v_warehouse,'Automatic posting: '||v_event.event_code,'DRAFT',p_actor_id)
 RETURNING * INTO v_journal;

 IF v_event.system_event_key IN('STOCK_GAIN','EXPENSE_DISBURSEMENT') THEN
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
   account_id,debit,credit,store_id,warehouse_id,description) VALUES
   (p_company_id,v_journal.id,1,v_account_1,v_amount,0,v_store,v_warehouse,
    CASE v_event.system_event_key WHEN 'STOCK_GAIN' THEN 'INVENTORY_ASSET'
      ELSE 'OUTSTANDING_EXPENSE' END),
   (p_company_id,v_journal.id,2,v_account_2,0,v_amount,v_store,v_warehouse,
    CASE v_event.system_event_key WHEN 'STOCK_GAIN' THEN 'STOCK_GAIN_INCOME'
      ELSE 'EXPENSE_PAYMENT_SOURCE' END);
  v_line_no:=2; v_debit:=v_amount; v_credit:=v_amount;

 ELSIF v_event.system_event_key='CASH_DEPOSIT' THEN
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
   account_id,debit,credit,store_id,description)
  VALUES(p_company_id,v_journal.id,1,v_account_1,v_actual,0,v_store,
   'CASH_DEPOSIT_DESTINATION');
  v_line_no:=1; v_debit:=v_actual;
  IF v_variance<0 THEN
   v_line_no:=v_line_no+1;
   INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
    account_id,debit,credit,store_id,description)
   VALUES(p_company_id,v_journal.id,v_line_no,v_account_3,abs(v_variance),0,
    v_store,'UNDER_DEPOSIT_CONTROL');
   v_debit:=v_debit+abs(v_variance);
  END IF;
  v_line_no:=v_line_no+1;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
   account_id,debit,credit,store_id,description)
  VALUES(p_company_id,v_journal.id,v_line_no,v_account_2,0,v_expected,v_store,
   'CASH_DRAWER');
  v_credit:=v_expected;
  IF v_variance>0 THEN
   v_line_no:=v_line_no+1;
   INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
    account_id,debit,credit,store_id,description)
   VALUES(p_company_id,v_journal.id,v_line_no,v_account_3,0,v_variance,v_store,
    'CASH_OVERAGE_LIABILITY');
   v_credit:=v_credit+v_variance;
  END IF;

 ELSE
  IF v_exception.variance_type='UNDER_DEPOSIT' THEN
   INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
    account_id,debit,credit,store_id,description) VALUES
    (p_company_id,v_journal.id,1,v_account_2,v_amount,0,v_store,
     'VARIANCE_RESOLUTION'),
    (p_company_id,v_journal.id,2,v_account_1,0,v_amount,v_store,
     'UNDER_DEPOSIT_CONTROL');
  ELSE
   INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
    account_id,debit,credit,store_id,description) VALUES
    (p_company_id,v_journal.id,1,v_account_1,v_amount,0,v_store,
     'CASH_OVERAGE_LIABILITY'),
    (p_company_id,v_journal.id,2,v_account_2,0,v_amount,v_store,
     'VARIANCE_RESOLUTION');
  END IF;
  v_line_no:=2; v_debit:=v_amount; v_credit:=v_amount;
 END IF;

 IF v_line_no<2 OR v_debit<=0 OR round(v_debit,4)<>round(v_credit,4) THEN
  RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
 UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,
  posted_at=v_now WHERE company_id=p_company_id AND id=v_journal.id
 RETURNING * INTO v_journal;
 UPDATE public.financial_events SET status='POSTED'::public.event_status,
  processed_at=v_now,error_message=NULL,transaction_rule_version=20260814160000
 WHERE company_id=p_company_id AND id=v_event.id;
 RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
  'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',FALSE);
END
$$;

CREATE OR REPLACE FUNCTION private.post_financial_event_core(
 p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_key TEXT;
BEGIN
 SELECT event.system_event_key INTO v_key FROM public.financial_events event
 WHERE event.company_id=p_company_id AND event.id=p_event_id;
 IF v_key IN('SALE_POSTED','SALES_RETURN') THEN
  RETURN private.post_sale_return_financial_event_core(
   p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 ELSIF v_key IN('GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT') THEN
  RETURN private.post_purchase_ap_financial_event_core(
   p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 ELSIF v_key IN('STOCK_GAIN','EXPENSE_DISBURSEMENT','CASH_DEPOSIT','CASH_VARIANCE') THEN
  RETURN private.post_remaining_operational_financial_event_core(
   p_company_id,p_event_id,p_expected_event_version,p_actor_id);
 END IF;
 RETURN private.post_financial_event_stock_opening_core(
  p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

REVOKE ALL ON FUNCTION
 private.g6_require_active_postable_snapshot_account(public.financial_events,UUID),
 private.post_remaining_operational_financial_event_core(UUID,UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
 private.g6_require_active_postable_snapshot_account(public.financial_events,UUID),
 private.post_remaining_operational_financial_event_core(UUID,UUID,BIGINT,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814160000','g6_phase8f_remaining_operational_posting_runtime',
 'Atomic source-verified posting for Stock Gain, Expense Disbursement, Cash Deposit and Cash Variance; historical HOLD remains controlled');
COMMIT;
