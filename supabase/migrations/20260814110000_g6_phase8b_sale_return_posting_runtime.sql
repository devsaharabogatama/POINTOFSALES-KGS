-- G6 phase 8B: atomic dynamic Sale and Sales Return journal posting runtime.
-- Historical HOLD events remain HOLD until an explicit controlled operation.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 8A mapping required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260814110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260814110000';
  END IF;
END
$guard$;

ALTER TABLE public.sales_payments
  ADD COLUMN settlement_account_function_snapshot TEXT;
ALTER TABLE public.sales_return_refunds
  ADD COLUMN settlement_account_function_snapshot TEXT;

UPDATE public.sales_payments payment SET
  settlement_account_function_snapshot=CASE payment.settlement_route_snapshot
    WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
    WHEN 'DIRECT_BANK' THEN method.bank_account_function
    WHEN 'CLEARING' THEN method.clearing_account_function
    WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
    WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
  END
FROM public.payment_methods method
WHERE method.company_id=payment.company_id AND method.id=payment.payment_method_id;

ALTER TABLE public.sales_return_refunds DISABLE TRIGGER guard_final_sales_return_refunds;
UPDATE public.sales_return_refunds refund SET
  settlement_account_function_snapshot=CASE refund.settlement_route_snapshot
    WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
    WHEN 'DIRECT_BANK' THEN method.bank_account_function
    WHEN 'CLEARING' THEN method.clearing_account_function
    WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
    WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
  END
FROM public.payment_methods method
WHERE method.company_id=refund.company_id AND method.id=refund.payment_method_id;
ALTER TABLE public.sales_return_refunds ENABLE TRIGGER guard_final_sales_return_refunds;

DO $snapshot_check$
BEGIN
  IF EXISTS(SELECT 1 FROM public.sales_payments
      WHERE settlement_account_function_snapshot IS NULL)
    OR EXISTS(SELECT 1 FROM public.sales_return_refunds
      WHERE settlement_account_function_snapshot IS NULL) THEN
    RAISE EXCEPTION 'SETTLEMENT_ACCOUNT_FUNCTION_BACKFILL_INCOMPLETE';
  END IF;
END
$snapshot_check$;

ALTER TABLE public.sales_payments
  ALTER COLUMN settlement_account_function_snapshot SET NOT NULL,
  ADD CONSTRAINT sales_payments_settlement_function_fk FOREIGN KEY(
    settlement_account_function_snapshot)
    REFERENCES public.account_functions(function_key);
ALTER TABLE public.sales_return_refunds
  ALTER COLUMN settlement_account_function_snapshot SET NOT NULL,
  ADD CONSTRAINT sales_return_refunds_settlement_function_fk FOREIGN KEY(
    settlement_account_function_snapshot)
    REFERENCES public.account_functions(function_key);

CREATE FUNCTION private.trg_g6_set_settlement_function_snapshot()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_expected TEXT;
BEGIN
  IF TG_OP='UPDATE' THEN
    IF NEW.settlement_account_function_snapshot IS DISTINCT FROM
       OLD.settlement_account_function_snapshot THEN
      RAISE EXCEPTION 'SETTLEMENT_ACCOUNT_FUNCTION_SNAPSHOT_IMMUTABLE';
    END IF;
    RETURN NEW;
  END IF;
  SELECT CASE NEW.settlement_route_snapshot
    WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
    WHEN 'DIRECT_BANK' THEN method.bank_account_function
    WHEN 'CLEARING' THEN method.clearing_account_function
    WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
    WHEN 'INTERNAL_LIABILITY' THEN 'CUSTOMER_BALANCE_LIABILITY'
  END INTO v_expected
  FROM public.payment_methods method
  WHERE method.company_id=NEW.company_id AND method.id=NEW.payment_method_id;
  IF v_expected IS NULL THEN RAISE EXCEPTION 'SETTLEMENT_ACCOUNT_FUNCTION_REQUIRED'; END IF;
  IF NEW.settlement_account_function_snapshot IS NOT NULL
     AND NEW.settlement_account_function_snapshot<>v_expected THEN
    RAISE EXCEPTION 'SETTLEMENT_ACCOUNT_FUNCTION_SNAPSHOT_MISMATCH';
  END IF;
  NEW.settlement_account_function_snapshot:=v_expected;
  RETURN NEW;
END
$$;

CREATE TRIGGER g6_sale_payment_settlement_snapshot
BEFORE INSERT OR UPDATE ON public.sales_payments FOR EACH ROW
EXECUTE FUNCTION private.trg_g6_set_settlement_function_snapshot();
CREATE TRIGGER g6_sale_refund_settlement_snapshot
BEFORE INSERT OR UPDATE ON public.sales_return_refunds FOR EACH ROW
EXECUTE FUNCTION private.trg_g6_set_settlement_function_snapshot();

ALTER FUNCTION private.post_financial_event_core(UUID,UUID,BIGINT,UUID)
RENAME TO post_financial_event_stock_opening_core;

CREATE FUNCTION private.post_sale_return_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;
  v_return public.sales_return_documents%ROWTYPE;
  v_period public.accounting_periods%ROWTYPE;
  v_journal public.finance_journals%ROWTYPE;
  v_payment RECORD; v_component RECORD;
  v_account UUID; v_line_no INTEGER:=0;
  v_tax NUMERIC(20,4):=0; v_cost NUMERIC(20,4):=0;
  v_settlement NUMERIC(20,4):=0; v_surcharge NUMERIC(20,4):=0;
  v_net NUMERIC(20,4):=0; v_delivery NUMERIC(20,4):=0;
  v_rounding NUMERIC(20,4):=0; v_debit NUMERIC(20,4):=0;
  v_credit NUMERIC(20,4):=0; v_amount NUMERIC(20,4);
  v_journal_type TEXT:='AUTOMATIC'; v_accounting_date DATE;
  v_customer UUID; v_store UUID; v_warehouse UUID; v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT * INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;
  IF v_event.status::TEXT='POSTED' THEN
    SELECT * INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id
      AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',TRUE);
  END IF;
  IF v_event.status::TEXT<>'HOLD' THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_HOLD'; END IF;
  IF v_event.system_event_key NOT IN('SALE_POSTED','SALES_RETURN') THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;

  SELECT * INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_event.event_date::DATE BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT * INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_event.event_date::DATE
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT'; v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_event.event_date::DATE; END IF;

  IF v_event.system_event_key='SALE_POSTED' THEN
    IF v_event.event_type::TEXT<>'SALE_POSTED' OR v_event.source_table<>'sales_headers' THEN
      RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
    SELECT * INTO v_sale FROM public.sales_headers sale
    WHERE sale.company_id=p_company_id AND sale.id=v_event.source_id
      AND sale.document_status='POSTED' FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    v_customer:=v_sale.customer_id; v_store:=v_event.store_id;
    v_warehouse:=v_sale.sales_warehouse_id; v_delivery:=v_sale.delivery_fee_amount;
    v_rounding:=v_sale.rounding_adjustment;
    SELECT COALESCE(sum(detail.tax_amount),0),COALESCE(sum(detail.fifo_cost_total),0)
      INTO v_tax,v_cost FROM public.sales_details detail
      WHERE detail.company_id=p_company_id AND detail.sales_id=v_sale.id;
    SELECT COALESCE(sum(payment.amount),0),COALESCE(sum(payment.customer_surcharge_amount),0)
      INTO v_settlement,v_surcharge FROM public.sales_payments payment
      WHERE payment.company_id=p_company_id AND payment.sales_id=v_sale.id;
    v_net:=round((v_event.amounts->>'netSalesInclusiveTax')::NUMERIC-v_tax,4);
    IF round((v_event.amounts->>'grandTotal')::NUMERIC,4)<>round(v_sale.grand_total_after_rounding,4)
      OR round(v_settlement,4)<>round(v_sale.grand_total_after_rounding+v_surcharge,4)
      OR round((v_event.amounts->>'fifoCostTotal')::NUMERIC,4)<>round(v_cost,4)
      OR v_net<0 THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
  ELSE
    IF v_event.event_type::TEXT<>'SALES_REFUND' OR
       v_event.source_table<>'sales_return_documents' THEN
      RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
    SELECT * INTO v_return FROM public.sales_return_documents document
    WHERE document.company_id=p_company_id AND document.id=v_event.source_id
      AND document.status='POSTED' AND document.financial_event_id=v_event.id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    v_customer:=v_return.customer_id; v_store:=v_return.store_id;
    v_delivery:=v_return.delivery_fee_refund_amount; v_rounding:=v_return.rounding_adjustment;
    SELECT COALESCE(sum(line.tax_refund_amount),0),COALESCE(sum(line.fifo_cost_restored),0)
      INTO v_tax,v_cost FROM public.sales_return_lines line
      WHERE line.company_id=p_company_id AND line.document_id=v_return.id;
    SELECT COALESCE(sum(refund.amount),0) INTO v_settlement
      FROM public.sales_return_refunds refund
      WHERE refund.company_id=p_company_id AND refund.document_id=v_return.id;
    v_net:=round(v_return.refund_before_rounding-v_tax,4);
    IF round(v_settlement,4)<>round(v_return.refund_total,4)
      OR round((v_event.amounts->>'fifoCostRestored')::NUMERIC,4)<>round(v_cost,4)
      OR v_net<0 THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
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
    v_event.system_event_key,v_event.transaction_category_id,20260814110000,
    v_store,v_warehouse,
    'Automatic posting: '||v_event.event_code,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;

  -- Settlement legs: Sale receives assets (debit), Return pays assets (credit).
  FOR v_payment IN
    SELECT payment.id,payment.amount,payment.settlement_account_function_snapshot function_key
    FROM public.sales_payments payment WHERE v_event.system_event_key='SALE_POSTED'
      AND payment.company_id=p_company_id AND payment.sales_id=v_sale.id
    UNION ALL
    SELECT refund.id,refund.amount,refund.settlement_account_function_snapshot
    FROM public.sales_return_refunds refund WHERE v_event.system_event_key='SALES_RETURN'
      AND refund.company_id=p_company_id AND refund.document_id=v_return.id
    ORDER BY id
  LOOP
    v_account:=private.resolve_financial_event_account(v_event,v_payment.function_key);
    v_line_no:=v_line_no+1; v_amount:=round(v_payment.amount,4);
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_account,
      CASE WHEN v_event.system_event_key='SALE_POSTED' THEN v_amount ELSE 0 END,
      CASE WHEN v_event.system_event_key='SALES_RETURN' THEN v_amount ELSE 0 END,
      v_store,v_warehouse,v_customer,v_payment.function_key||':'||v_payment.id);
    IF v_event.system_event_key='SALE_POSTED' THEN v_debit:=v_debit+v_amount;
    ELSE v_credit:=v_credit+v_amount; END IF;
  END LOOP;

  FOR v_component IN SELECT * FROM (VALUES
    (CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'SALES_REVENUE' ELSE 'SALES_RETURN_DISCOUNT' END,v_net,
      CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'CREDIT' ELSE 'DEBIT' END),
    ('OUTPUT_TAX',v_tax,CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'CREDIT' ELSE 'DEBIT' END),
    ('DELIVERY_FEE_REVENUE',v_delivery,CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'CREDIT' ELSE 'DEBIT' END),
    ('PAYMENT_SURCHARGE_INCOME',CASE WHEN v_event.system_event_key='SALE_POSTED' THEN v_surcharge ELSE 0 END,'CREDIT'),
    (CASE WHEN v_rounding>=0 THEN CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'ROUNDING_GAIN' ELSE 'ROUNDING_LOSS' END
      ELSE CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'ROUNDING_LOSS' ELSE 'ROUNDING_GAIN' END END,
      abs(v_rounding),CASE WHEN (v_event.system_event_key='SALE_POSTED' AND v_rounding>=0)
        OR (v_event.system_event_key='SALES_RETURN' AND v_rounding<0) THEN 'CREDIT' ELSE 'DEBIT' END),
    ('COGS',v_cost,CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'DEBIT' ELSE 'CREDIT' END),
    ('INVENTORY_ASSET',CASE WHEN v_event.system_event_key='SALE_POSTED' THEN v_cost ELSE 0 END,'CREDIT')
  ) component(function_key,amount,side) WHERE amount>0
  LOOP
    v_account:=private.resolve_financial_event_account(v_event,v_component.function_key);
    v_line_no:=v_line_no+1; v_amount:=round(v_component.amount,4);
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_account,
      CASE WHEN v_component.side='DEBIT' THEN v_amount ELSE 0 END,
      CASE WHEN v_component.side='CREDIT' THEN v_amount ELSE 0 END,
      v_store,v_warehouse,v_customer,v_component.function_key);
    IF v_component.side='DEBIT' THEN v_debit:=v_debit+v_amount;
    ELSE v_credit:=v_credit+v_amount; END IF;
  END LOOP;

  -- A Return may restore stock into several Warehouses. Preserve that
  -- dimensional split while keeping one source Event and one Journal.
  IF v_event.system_event_key='SALES_RETURN' THEN
    FOR v_component IN
      SELECT 'INVENTORY_ASSET'::TEXT function_key,
        round(sum(line.fifo_cost_restored),4) amount,
        line.destination_warehouse_id warehouse_id
      FROM public.sales_return_lines line
      WHERE line.company_id=p_company_id AND line.document_id=v_return.id
        AND line.fifo_cost_restored>0
      GROUP BY line.destination_warehouse_id
    LOOP
      v_account:=private.resolve_financial_event_account(v_event,v_component.function_key);
      v_line_no:=v_line_no+1; v_amount:=v_component.amount;
      INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
        debit,credit,store_id,warehouse_id,customer_id,description)
      VALUES(p_company_id,v_journal.id,v_line_no,v_account,v_amount,0,
        v_store,v_component.warehouse_id,v_customer,'INVENTORY_ASSET');
      v_debit:=v_debit+v_amount;
    END LOOP;
  END IF;
  IF v_line_no<2 OR v_debit<=0 OR round(v_debit,4)<>round(v_credit,4) THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED'; END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,posted_at=v_now
    WHERE company_id=p_company_id AND id=v_journal.id RETURNING * INTO v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,
    transaction_rule_version=20260814110000
    WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','journalType',v_journal.journal_type,
    'accountingDate',v_journal.accounting_date,'totalDebit',v_journal.total_debit,
    'totalCredit',v_journal.total_credit,'idempotentReplay',FALSE);
END
$$;

CREATE FUNCTION private.post_financial_event_core(
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
  END IF;
  RETURN private.post_financial_event_stock_opening_core(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

REVOKE ALL ON FUNCTION private.trg_g6_set_settlement_function_snapshot(),
  private.post_sale_return_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_stock_opening_core(UUID,UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g6_set_settlement_function_snapshot(),
  private.post_sale_return_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_stock_opening_core(UUID,UUID,BIGINT,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260814110000','g6_phase8b_sale_return_posting_runtime',
  'Atomic source-verified dynamic Sale and Sales Return Journal runtime with immutable settlement-function snapshots; historical HOLD processing remains controlled');
COMMIT;
