-- Finance forward-fix: canonical Sale posting supports unpaid and partial TEMPO.
-- Existing HOLD Events remain untouched until an explicit controlled queue retry.

BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: F4B posting policy closure required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827141000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260827141000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance posting queue';
  END IF;
  IF to_regprocedure(
    'private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Sale posting runtime missing';
  END IF;
END
$guard$;

-- Fill only the missing historical interval. A later active fallback remains
-- unchanged and keeps governing from its original effective date.
DO $receivable_mapping$
DECLARE
  v_actor UUID;
  v_scope RECORD;
  v_account UUID;
  v_effective_to TIMESTAMPTZ;
  v_candidate_count BIGINT;
  v_version BIGINT;
  v_id UUID;
BEGIN
  SELECT profile.id INTO v_actor FROM public.profiles profile
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Super Admin profile required';
  END IF;

  IF EXISTS(
    WITH event_scope AS (
      SELECT event.* FROM public.financial_events event
      JOIN public.sales_headers sale ON sale.company_id=event.company_id
        AND sale.id=event.source_id AND sale.document_status='POSTED'
      WHERE event.status::TEXT='HOLD' AND event.system_event_key='SALE_POSTED'
        AND event.event_type::TEXT='SALE_POSTED'
        AND event.source_table='sales_headers' AND sale.sisa_piutang>0
    )
    SELECT 1 FROM event_scope event WHERE
      (SELECT count(*) FROM public.transaction_account_rules rule
        WHERE rule.company_id=event.company_id
          AND rule.transaction_category_id=event.transaction_category_id
          AND rule.system_key=event.system_event_key
          AND rule.account_function_key='CUSTOMER_RECEIVABLE'
          AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
          AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date))>1
      OR (SELECT count(*) FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id=event.company_id
          AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
          AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
          AND (fallback.effective_to IS NULL
            OR fallback.effective_to>event.event_date))>1
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ambiguous historical receivable mapping';
  END IF;

  FOR v_scope IN
    WITH unresolved AS (
      SELECT event.company_id,min(event.event_date) required_from
      FROM public.financial_events event
      JOIN public.sales_headers sale ON sale.company_id=event.company_id
        AND sale.id=event.source_id AND sale.document_status='POSTED'
      WHERE event.status::TEXT='HOLD' AND event.system_event_key='SALE_POSTED'
        AND event.event_type::TEXT='SALE_POSTED'
        AND event.source_table='sales_headers' AND sale.sisa_piutang>0
        AND NOT EXISTS(SELECT 1 FROM public.transaction_account_rules rule
          WHERE rule.company_id=event.company_id
            AND rule.transaction_category_id=event.transaction_category_id
            AND rule.system_key=event.system_event_key
            AND rule.account_function_key='CUSTOMER_RECEIVABLE'
            AND rule.status='ACTIVE' AND rule.effective_from<=event.event_date
            AND (rule.effective_to IS NULL OR rule.effective_to>event.event_date))
        AND NOT EXISTS(SELECT 1
          FROM public.company_account_function_fallbacks fallback
          WHERE fallback.company_id=event.company_id
            AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
            AND fallback.status='ACTIVE' AND fallback.effective_from<=event.event_date
            AND (fallback.effective_to IS NULL
              OR fallback.effective_to>event.event_date))
      GROUP BY event.company_id
    )
    SELECT * FROM unresolved ORDER BY company_id
  LOOP
    v_account:=NULL; v_effective_to:=NULL; v_candidate_count:=0;
    SELECT fallback.account_id,fallback.effective_from
      INTO v_account,v_effective_to
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=v_scope.company_id
      AND fallback.account_function_key='CUSTOMER_RECEIVABLE'
      AND fallback.status='ACTIVE'
      AND fallback.effective_from>v_scope.required_from
    ORDER BY fallback.effective_from,fallback.fallback_version,fallback.id LIMIT 1;

    IF v_account IS NULL THEN
      SELECT count(*),(array_agg(account.id ORDER BY account.id))[1]
        INTO v_candidate_count,v_account
      FROM public.chart_of_accounts account
      JOIN public.account_functions function_state
        ON function_state.function_key='CUSTOMER_RECEIVABLE'
        AND function_state.is_active
      WHERE account.company_id=v_scope.company_id
        AND account.system_function_key='CUSTOMER_RECEIVABLE'
        AND account.is_system_account AND account.is_active AND account.is_postable
        AND account.account_type=ANY(function_state.compatible_account_types);
      IF v_candidate_count<>1 OR v_account IS NULL THEN
        RAISE EXCEPTION
          'MIGRATION_PRECONDITION_FAILED: Company % requires one receivable account; found %',
          v_scope.company_id,v_candidate_count;
      END IF;
    END IF;

    IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      JOIN public.account_functions function_state
        ON function_state.function_key='CUSTOMER_RECEIVABLE'
        AND function_state.is_active
      WHERE account.company_id=v_scope.company_id AND account.id=v_account
        AND account.is_active AND account.is_postable
        AND account.account_type=ANY(function_state.compatible_account_types)) THEN
      RAISE EXCEPTION
        'MIGRATION_PRECONDITION_FAILED: invalid receivable account candidate';
    END IF;

    SELECT COALESCE(max(fallback.fallback_version),0)+1 INTO v_version
    FROM public.company_account_function_fallbacks fallback
    WHERE fallback.company_id=v_scope.company_id
      AND fallback.account_function_key='CUSTOMER_RECEIVABLE';
    INSERT INTO public.company_account_function_fallbacks(
      company_id,account_function_key,account_id,effective_from,effective_to,
      fallback_version,status,approved_by,approved_at,created_by,updated_by)
    VALUES(v_scope.company_id,'CUSTOMER_RECEIVABLE',v_account,
      TIMESTAMPTZ '2000-01-01 00:00:00+00',v_effective_to,v_version,
      'ACTIVE',v_actor,clock_timestamp(),v_actor,v_actor)
    RETURNING id INTO v_id;
    INSERT INTO public.finance_master_audit(
      company_id,entity_type,entity_id,action,actor_id,after_state)
    SELECT fallback.company_id,'FALLBACK',fallback.id,'CREATE',v_actor,
      to_jsonb(fallback) FROM public.company_account_function_fallbacks fallback
    WHERE fallback.id=v_id;
  END LOOP;
END
$receivable_mapping$;

CREATE OR REPLACE FUNCTION private.post_sale_return_financial_event_core(
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
  v_receivable NUMERIC(20,4):=0;
  v_net NUMERIC(20,4):=0; v_delivery NUMERIC(20,4):=0;
  v_rounding NUMERIC(20,4):=0; v_debit NUMERIC(20,4):=0;
  v_credit NUMERIC(20,4):=0; v_amount NUMERIC(20,4);
  v_journal_type TEXT:='AUTOMATIC'; v_accounting_date DATE;
  v_customer UUID; v_store UUID; v_warehouse UUID;
  v_now TIMESTAMPTZ:=clock_timestamp();
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
    v_rounding:=v_sale.rounding_adjustment; v_receivable:=v_sale.sisa_piutang;
    SELECT COALESCE(sum(detail.tax_amount),0),COALESCE(sum(detail.fifo_cost_total),0)
      INTO v_tax,v_cost FROM public.sales_details detail
      WHERE detail.company_id=p_company_id AND detail.sales_id=v_sale.id;
    SELECT COALESCE(sum(payment.amount),0),COALESCE(sum(payment.customer_surcharge_amount),0)
      INTO v_settlement,v_surcharge FROM public.sales_payments payment
      WHERE payment.company_id=p_company_id AND payment.sales_id=v_sale.id;
    v_net:=round((v_event.amounts->>'netSalesInclusiveTax')::NUMERIC-v_tax,4);
    IF round((v_event.amounts->>'grandTotal')::NUMERIC,4)
         <>round(v_sale.grand_total_after_rounding,4)
      OR round(COALESCE((v_event.amounts->>'paymentTotal')::NUMERIC,-1),4)
         <>round(v_settlement,4)
      OR round(COALESCE((v_event.amounts->>'receivable')::NUMERIC,-1),4)
         <>round(v_receivable,4)
      OR round(v_sale.paid_amount,4)<>round(v_settlement,4)
      OR round(v_settlement+v_receivable,4)
         <>round(v_sale.grand_total_after_rounding+v_surcharge,4)
      OR round((v_event.amounts->>'fifoCostTotal')::NUMERIC,4)<>round(v_cost,4)
      OR v_receivable<0 OR (v_receivable>0 AND v_customer IS NULL)
      OR v_net<0 THEN RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH'; END IF;
  ELSE
    IF v_event.event_type::TEXT<>'SALES_REFUND'
       OR v_event.source_table<>'sales_return_documents' THEN
      RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT'; END IF;
    SELECT * INTO v_return FROM public.sales_return_documents document
    WHERE document.company_id=p_company_id AND document.id=v_event.source_id
      AND document.status='POSTED' AND document.financial_event_id=v_event.id FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
    v_customer:=v_return.customer_id; v_store:=v_return.store_id;
    v_delivery:=v_return.delivery_fee_refund_amount;
    v_rounding:=v_return.rounding_adjustment;
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
    v_event.system_event_key,v_event.transaction_category_id,20260827141000,
    v_store,v_warehouse,'Automatic posting: '||v_event.event_code,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;

  -- Actual Cash/Bank/Clearing/Customer Balance settlement legs.
  FOR v_payment IN
    SELECT payment.id,payment.amount,
      payment.settlement_account_function_snapshot function_key
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

  -- Unpaid or partially paid TEMPO is an asset, not a missing Payment row.
  IF v_event.system_event_key='SALE_POSTED' AND v_receivable>0 THEN
    v_account:=private.resolve_financial_event_account(v_event,'CUSTOMER_RECEIVABLE');
    v_line_no:=v_line_no+1; v_amount:=round(v_receivable,4);
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
      debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_account,v_amount,0,
      v_store,v_warehouse,v_customer,'CUSTOMER_RECEIVABLE');
    v_debit:=v_debit+v_amount;
  END IF;

  FOR v_component IN SELECT * FROM (VALUES
    (CASE WHEN v_event.system_event_key='SALE_POSTED'
      THEN 'SALES_REVENUE' ELSE 'SALES_RETURN_DISCOUNT' END,v_net,
      CASE WHEN v_event.system_event_key='SALE_POSTED' THEN 'CREDIT' ELSE 'DEBIT' END),
    ('OUTPUT_TAX',v_tax,CASE WHEN v_event.system_event_key='SALE_POSTED'
      THEN 'CREDIT' ELSE 'DEBIT' END),
    ('DELIVERY_FEE_REVENUE',v_delivery,CASE WHEN v_event.system_event_key='SALE_POSTED'
      THEN 'CREDIT' ELSE 'DEBIT' END),
    ('PAYMENT_SURCHARGE_INCOME',CASE WHEN v_event.system_event_key='SALE_POSTED'
      THEN v_surcharge ELSE 0 END,'CREDIT'),
    (CASE WHEN v_rounding>=0 THEN CASE WHEN v_event.system_event_key='SALE_POSTED'
       THEN 'ROUNDING_GAIN' ELSE 'ROUNDING_LOSS' END
      ELSE CASE WHEN v_event.system_event_key='SALE_POSTED'
       THEN 'ROUNDING_LOSS' ELSE 'ROUNDING_GAIN' END END,
      abs(v_rounding),CASE WHEN (v_event.system_event_key='SALE_POSTED' AND v_rounding>=0)
        OR (v_event.system_event_key='SALES_RETURN' AND v_rounding<0)
        THEN 'CREDIT' ELSE 'DEBIT' END),
    ('COGS',v_cost,CASE WHEN v_event.system_event_key='SALE_POSTED'
      THEN 'DEBIT' ELSE 'CREDIT' END),
    ('INVENTORY_ASSET',CASE WHEN v_event.system_event_key='SALE_POSTED'
      THEN v_cost ELSE 0 END,'CREDIT')
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

  IF v_event.system_event_key='SALES_RETURN' THEN
    FOR v_component IN
      SELECT 'INVENTORY_ASSET'::TEXT function_key,
        round(sum(line.fifo_cost_restored),4) amount,
        line.destination_warehouse_id warehouse_id
      FROM public.sales_return_lines line
      WHERE line.company_id=p_company_id AND line.document_id=v_return.id
        AND line.fifo_cost_restored>0 GROUP BY line.destination_warehouse_id
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
    processed_at=v_now,error_message=NULL,transaction_rule_version=20260827141000
    WHERE company_id=p_company_id AND id=v_event.id;
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','journalType',v_journal.journal_type,
    'accountingDate',v_journal.accounting_date,'totalDebit',v_journal.total_debit,
    'totalCredit',v_journal.total_credit,'idempotentReplay',FALSE);
END
$$;

REVOKE ALL ON FUNCTION
  private.post_sale_return_financial_event_core(UUID,UUID,BIGINT,UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.post_sale_return_financial_event_core(UUID,UUID,BIGINT,UUID)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260827141000','finance_tempo_sale_posting_fix',
  'Backfills audited historical CUSTOMER_RECEIVABLE mapping and adds its source-verified journal leg for unpaid and partial TEMPO Sale while preserving Cash, split Payment and Sales Return posting');

COMMIT;
