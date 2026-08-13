-- G6 phase 8D: atomic source-verified Purchase/AP journal posting runtime.
-- Historical HOLD events remain HOLD until a separate controlled operation.

BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8C required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814140000';
  END IF;
END
$guard$;

CREATE FUNCTION private.g6_require_event_snapshot_account(
  p_event public.financial_events,p_account_id UUID,p_function_key TEXT,
  p_require_function_compatibility BOOLEAN DEFAULT TRUE
) RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_account public.chart_of_accounts%ROWTYPE;
  v_function public.account_functions%ROWTYPE;
BEGIN
  IF p_account_id IS NULL THEN RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_REQUIRED'; END IF;
  SELECT * INTO v_account FROM public.chart_of_accounts account
  WHERE account.company_id=p_event.company_id AND account.id=p_account_id;
  IF NOT FOUND OR NOT v_account.is_active OR NOT v_account.is_postable THEN
    RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INVALID'; END IF;
  IF p_require_function_compatibility THEN
    SELECT * INTO v_function FROM public.account_functions function_state
    WHERE function_state.function_key=p_function_key AND function_state.is_active;
    IF NOT FOUND OR NOT (v_account.account_type=ANY(v_function.compatible_account_types)) THEN
      RAISE EXCEPTION 'EVENT_ACCOUNT_SNAPSHOT_INCOMPATIBLE'; END IF;
  ELSIF v_account.account_type<>'ASSET' THEN
    RAISE EXCEPTION 'PAYMENT_SOURCE_ACCOUNT_MUST_BE_ASSET';
  END IF;
  RETURN v_account.id;
END
$$;

CREATE FUNCTION private.post_purchase_ap_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_receipt public.goods_receipt_documents%ROWTYPE;
  v_invoice public.supplier_invoice_documents%ROWTYPE;
  v_payment public.supplier_payment_documents%ROWTYPE;
  v_period public.accounting_periods%ROWTYPE;
  v_journal public.finance_journals%ROWTYPE;
  v_account UUID; v_inventory_account UUID; v_ap_provisional_account UUID;
  v_ap_final_account UUID; v_variance_account UUID; v_tax_account UUID;
  v_settlement_account UUID; v_supplier UUID; v_store UUID; v_warehouse UUID;
  v_line_no INTEGER:=0; v_journal_type TEXT:='AUTOMATIC';
  v_accounting_date DATE; v_now TIMESTAMPTZ:=clock_timestamp();
  v_debit NUMERIC(20,4):=0; v_credit NUMERIC(20,4):=0;
  v_receipt_total NUMERIC(20,4); v_line_total NUMERIC(20,4);
  v_batch_total NUMERIC(20,4); v_provisional NUMERIC(20,4);
  v_actual NUMERIC(20,4); v_variance NUMERIC(20,4);
  v_recoverable_tax NUMERIC(20,4); v_nonrecoverable_tax NUMERIC(20,4);
  v_allocation_total NUMERIC(20,4); v_amount NUMERIC(20,4);
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
    RETURN jsonb_build_object('financialEventId',v_event.id,
      'journalId',v_journal.id,'journalNo',v_journal.journal_no,
      'status','POSTED','idempotentReplay',TRUE);
  END IF;
  IF v_event.status::TEXT<>'HOLD' THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_HOLD'; END IF;
  IF v_event.system_event_key NOT IN(
    'GOODS_RECEIPT','SUPPLIER_INVOICE','SUPPLIER_PAYMENT') THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;

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

  IF v_event.system_event_key='GOODS_RECEIPT' THEN
    IF v_event.event_type::TEXT<>'PURCHASE_POSTED'
       OR v_event.source_table<>'goods_receipt_documents' THEN
      RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
    SELECT * INTO v_receipt FROM public.goods_receipt_documents document
    WHERE document.company_id=p_company_id AND document.id=v_event.source_id
      AND document.status='POSTED' AND document.financial_event_id=v_event.id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    SELECT order_document.supplier_id INTO v_supplier
    FROM public.supplier_order_documents order_document
    WHERE order_document.company_id=p_company_id
      AND order_document.id=v_receipt.supplier_order_id;
    v_store:=v_receipt.store_id; v_warehouse:=v_receipt.warehouse_id;
    v_receipt_total:=round(v_receipt.provisional_ap_total,4);
    SELECT round(COALESCE(sum(line.provisional_ap_amount),0),4)
      INTO v_line_total FROM public.goods_receipt_lines line
    WHERE line.company_id=p_company_id AND line.document_id=v_receipt.id;
    SELECT round(COALESCE(sum(batch.qty_purchased*batch.cogs_unit),0),4)
      INTO v_batch_total FROM public.product_batches batch
    JOIN public.goods_receipt_condition_allocations allocation
      ON allocation.company_id=batch.company_id
     AND allocation.id=batch.goods_receipt_condition_allocation_id
    JOIN public.goods_receipt_lines line ON line.company_id=allocation.company_id
     AND line.id=allocation.receipt_line_id
    WHERE line.company_id=p_company_id AND line.document_id=v_receipt.id;
    IF v_receipt_total<=0 OR v_receipt_total<>v_line_total
      OR v_receipt_total<>v_batch_total
      OR v_receipt_total<>round((v_event.amounts->>'inventoryDebit')::NUMERIC,4)
      OR v_receipt_total<>round((v_event.amounts->>'supplierApProvisionalCredit')::NUMERIC,4)
    THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
    v_inventory_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'inventoryAccountId','')::UUID,'INVENTORY_ASSET');
    v_ap_provisional_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'supplierApAccountId','')::UUID,
      'SUPPLIER_AP_PROVISIONAL');

  ELSIF v_event.system_event_key='SUPPLIER_INVOICE' THEN
    IF v_event.event_type::TEXT<>'SUPPLIER_INVOICE_VALIDATED'
       OR v_event.source_table<>'supplier_invoice_documents' THEN
      RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
    SELECT * INTO v_invoice FROM public.supplier_invoice_documents document
    WHERE document.company_id=p_company_id AND document.id=v_event.source_id
      AND document.status='VALIDATED' AND document.financial_event_id=v_event.id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    v_supplier:=v_invoice.supplier_id;
    SELECT round(COALESCE(sum(allocation.provisional_value),0),4),
      round(COALESCE(sum(allocation.actual_value),0),4)
      INTO v_provisional,v_actual FROM public.supplier_invoice_allocations allocation
    WHERE allocation.company_id=p_company_id AND allocation.document_id=v_invoice.id;
    SELECT round(COALESCE(sum(line.tax_amount) FILTER(
        WHERE line.tax_is_recoverable_snapshot),0),4),
      round(COALESCE(sum(line.tax_amount) FILTER(
        WHERE line.tax_is_recoverable_snapshot=FALSE),0),4)
      INTO v_recoverable_tax,v_nonrecoverable_tax
    FROM public.supplier_invoice_lines line
    WHERE line.company_id=p_company_id AND line.document_id=v_invoice.id;
    v_variance:=round(v_actual-v_provisional,4);
    IF v_provisional<>round(v_invoice.provisional_value_allocated,4)
      OR v_actual<>round(v_invoice.actual_value_allocated,4)
      OR v_variance<>round(v_invoice.purchase_price_variance,4)
      OR round(v_invoice.grand_total,4)<>
         round(v_actual+v_recoverable_tax+v_nonrecoverable_tax,4)
      OR v_provisional<>round((v_event.amounts->>'apProvisionalDebit')::NUMERIC,4)
      OR round(v_invoice.grand_total,4)<>
         round((v_event.amounts->>'apFinalCredit')::NUMERIC,4)
      OR v_variance<>round((v_event.amounts->>'purchasePriceVariance')::NUMERIC,4)
      OR v_recoverable_tax<>
         round((v_event.amounts->>'recoverableInputTaxDebit')::NUMERIC,4)
      OR v_nonrecoverable_tax<>
         round((v_event.amounts->>'nonrecoverablePurchaseTax')::NUMERIC,4)
    THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
    v_ap_provisional_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'apProvisionalAccountId','')::UUID,
      'SUPPLIER_AP_PROVISIONAL');
    v_ap_final_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'apFinalAccountId','')::UUID,'SUPPLIER_AP_FINAL');
    v_variance_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'purchasePriceVarianceAccountId','')::UUID,
      'PURCHASE_PRICE_VARIANCE');
    IF v_recoverable_tax>0 THEN
      v_tax_account:=private.g6_require_event_snapshot_account(v_event,
        NULLIF(v_event.amounts->>'inputTaxAccountId','')::UUID,'INPUT_TAX');
    END IF;

  ELSE
    IF v_event.event_type::TEXT<>'SUPPLIER_PAYMENT_VALIDATED'
       OR v_event.source_table<>'supplier_payment_documents' THEN
      RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
    SELECT * INTO v_payment FROM public.supplier_payment_documents document
    WHERE document.company_id=p_company_id AND document.id=v_event.source_id
      AND document.status='VALIDATED' AND document.financial_event_id=v_event.id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    v_supplier:=v_payment.supplier_id;
    SELECT round(COALESCE(sum(allocation.allocated_amount),0),4)
      INTO v_allocation_total FROM public.supplier_payment_allocations allocation
    JOIN public.supplier_invoice_documents invoice
      ON invoice.company_id=allocation.company_id AND invoice.id=allocation.invoice_id
     AND invoice.status='VALIDATED' AND invoice.supplier_id=v_payment.supplier_id
    WHERE allocation.company_id=p_company_id AND allocation.document_id=v_payment.id;
    v_amount:=round(v_payment.total_amount,4);
    IF v_amount<=0 OR v_amount<>v_allocation_total
      OR v_amount<>round((v_event.amounts->>'totalAmount')::NUMERIC,4)
    THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
    v_ap_final_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'apFinalDebitAccount','')::UUID,'SUPPLIER_AP_FINAL');
    v_settlement_account:=private.g6_require_event_snapshot_account(v_event,
      NULLIF(v_event.amounts->>'cashOrBankCreditAccount','')::UUID,
      'PAYMENT_SOURCE',FALSE);
  END IF;

  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(p_company_id,'G6-'||replace(v_event.id::TEXT,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_event.event_date::DATE,v_event.source_table,
    v_event.source_id,v_event.event_version,v_event.id,
    'G6_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,20260814140000,
    v_store,v_warehouse,'Automatic posting: '||v_event.event_code,
    'DRAFT',p_actor_id) RETURNING * INTO v_journal;

  IF v_event.system_event_key='GOODS_RECEIPT' THEN
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,supplier_id,description)
    VALUES
      (p_company_id,v_journal.id,1,v_inventory_account,v_receipt_total,0,
       v_store,v_warehouse,v_supplier,'INVENTORY_ASSET'),
      (p_company_id,v_journal.id,2,v_ap_provisional_account,0,v_receipt_total,
       v_store,v_warehouse,v_supplier,'SUPPLIER_AP_PROVISIONAL');
    v_line_no:=2; v_debit:=v_receipt_total; v_credit:=v_receipt_total;

  ELSIF v_event.system_event_key='SUPPLIER_INVOICE' THEN
    IF v_provisional>0 THEN
      v_line_no:=v_line_no+1;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
        account_id,debit,credit,supplier_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_ap_provisional_account,
        v_provisional,0,v_supplier,'SUPPLIER_AP_PROVISIONAL');
      v_debit:=v_debit+v_provisional;
    END IF;
    IF v_variance<>0 OR v_nonrecoverable_tax>0 THEN
      v_amount:=round(v_variance+v_nonrecoverable_tax,4);
      IF v_amount<>0 THEN
        v_line_no:=v_line_no+1;
        INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
          account_id,debit,credit,supplier_id,description)
        VALUES(p_company_id,v_journal.id,v_line_no,v_variance_account,
          CASE WHEN v_amount>0 THEN v_amount ELSE 0 END,
          CASE WHEN v_amount<0 THEN abs(v_amount) ELSE 0 END,
          v_supplier,'PURCHASE_PRICE_VARIANCE_AND_NONRECOVERABLE_TAX');
        IF v_amount>0 THEN v_debit:=v_debit+v_amount;
        ELSE v_credit:=v_credit+abs(v_amount); END IF;
      END IF;
    END IF;
    IF v_recoverable_tax>0 THEN
      v_line_no:=v_line_no+1;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
        account_id,debit,credit,supplier_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_tax_account,
        v_recoverable_tax,0,v_supplier,'INPUT_TAX');
      v_debit:=v_debit+v_recoverable_tax;
    END IF;
    v_line_no:=v_line_no+1; v_amount:=round(v_invoice.grand_total,4);
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,supplier_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_ap_final_account,
      0,v_amount,v_supplier,'SUPPLIER_AP_FINAL');
    v_credit:=v_credit+v_amount;

  ELSE
    v_line_no:=2;
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,supplier_id,description)
    VALUES
      (p_company_id,v_journal.id,1,v_ap_final_account,v_amount,0,
       v_supplier,'SUPPLIER_AP_FINAL'),
      (p_company_id,v_journal.id,2,v_settlement_account,0,v_amount,
       v_supplier,'SUPPLIER_PAYMENT_SOURCE');
    v_debit:=v_amount; v_credit:=v_amount;
  END IF;

  IF v_line_no<2 OR v_debit<=0 OR round(v_debit,4)<>round(v_credit,4) THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,
    posted_at=v_now WHERE company_id=p_company_id AND id=v_journal.id
    RETURNING * INTO v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=20260814140000
  WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,
    'journalId',v_journal.id,'journalNo',v_journal.journal_no,'status','POSTED',
    'journalType',v_journal.journal_type,'accountingDate',v_journal.accounting_date,
    'totalDebit',v_journal.total_debit,'totalCredit',v_journal.total_credit,
    'idempotentReplay',FALSE);
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
  END IF;
  RETURN private.post_financial_event_stock_opening_core(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

REVOKE ALL ON FUNCTION
  private.g6_require_event_snapshot_account(public.financial_events,UUID,TEXT,BOOLEAN),
  private.post_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.g6_require_event_snapshot_account(public.financial_events,UUID,TEXT,BOOLEAN),
  private.post_purchase_ap_financial_event_core(UUID,UUID,BIGINT,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814140000','g6_phase8d_purchase_ap_posting_runtime',
  'Atomic source-verified Goods Receipt, Supplier Invoice and Supplier Payment journal posting runtime using immutable account snapshots; historical HOLD remains controlled');
COMMIT;
