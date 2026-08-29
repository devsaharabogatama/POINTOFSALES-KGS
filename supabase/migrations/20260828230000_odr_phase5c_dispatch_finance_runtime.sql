-- ODR-5C: atomic Dispatch Finance capture and controlled posting runtime.
-- Payment verification and automatic posting remain outside this migration.
BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828140000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828210000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828220000') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ODR-3C, ODR-5A and ODR-5B required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828230000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828230000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_company_policies
      WHERE posting_mode='AUTOMATIC') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ODR-5C requires CONTROLLED posting';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Dispatch Finance source must be empty';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.sales_dispatch_allocations allocation
    JOIN public.sales_delivery_documents delivery
      ON delivery.company_id=allocation.company_id
     AND delivery.id=allocation.delivery_document_id
    WHERE delivery.reservation_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: ODR Dispatch operation requires reviewed capture';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure
  ) INTO v_definition;
  IF v_definition IS NULL
    OR v_definition!~'INSERT INTO public.sales_dispatch_allocations'
    OR v_definition~'sales_dispatch_financial_effects' THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: canonical Dispatch stock core changed';
  END IF;
END
$guard$;

-- The advance leg is zero until ODR-5D verifies a pre-dispatch receipt. It is
-- present now so the immutable Dispatch source already has its final shape.
ALTER TABLE public.sales_dispatch_financial_effects
  ADD COLUMN advance_applied_amount NUMERIC(24,4) NOT NULL DEFAULT 0,
  ADD CONSTRAINT sales_dispatch_financial_effects_advance_amount_check
    CHECK(advance_applied_amount>=0);

-- Keep automatic mode closed until Payment verification and its reconciliation
-- gate are installed. Controlled preview/approve/process remains available.
CREATE FUNCTION private.trg_odr5c_guard_automatic_posting_policy()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.posting_mode='AUTOMATIC'
    AND NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828240000') THEN
    RAISE EXCEPTION 'ODR_AUTOMATIC_POSTING_NOT_READY';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER odr5c_guard_automatic_posting_policy
BEFORE INSERT OR UPDATE OF posting_mode ON public.finance_company_policies
FOR EACH ROW EXECUTE FUNCTION private.trg_odr5c_guard_automatic_posting_policy();

ALTER FUNCTION private.dispatch_sales_delivery_core(
  UUID,BIGINT,UUID,JSONB,TEXT
) RENAME TO dispatch_sales_delivery_stock_core_odr3c;

CREATE FUNCTION private.capture_dispatch_financial_effect_core(
  p_delivery_document_id UUID,p_idempotency_key UUID,
  p_actor_id UUID,p_stock_result JSONB
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_delivery public.sales_delivery_documents%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;
  v_effect public.sales_dispatch_financial_effects%ROWTYPE;
  v_event public.financial_events%ROWTYPE;
  v_category UUID;v_category_count BIGINT;v_timezone TEXT;
  v_dispatch_at TIMESTAMPTZ;
  v_effective_date DATE;v_final BOOLEAN;
  v_dispatched NUMERIC(24,6);v_cost NUMERIC(24,4);
  v_fifo_cost NUMERIC(24,4);v_negative_cost_total NUMERIC(24,4);
  v_negative_rows BIGINT;v_negative_missing BIGINT;
  v_net NUMERIC(24,4);v_tax NUMERIC(24,4);
  v_delivery_fee NUMERIC(24,4):=0;v_surcharge NUMERIC(24,4):=0;
  v_rounding NUMERIC(24,4):=0;v_receivable NUMERIC(24,4):=0;
  v_clearing NUMERIC(24,4):=0;v_advance NUMERIC(24,4):=0;
  v_prior_net NUMERIC(24,4);v_prior_tax NUMERIC(24,4);
  v_prior_delivery NUMERIC(24,4);v_prior_surcharge NUMERIC(24,4);
  v_prior_rounding NUMERIC(24,4);v_target_net NUMERIC(24,4);
  v_target_tax NUMERIC(24,4);v_target_surcharge NUMERIC(24,4);
  v_settlement NUMERIC(24,4);v_effect_id UUID:=gen_random_uuid();
  v_event_id UUID:=gen_random_uuid();v_snapshot JSONB;
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;

  SELECT effect.* INTO v_effect
  FROM public.sales_dispatch_financial_effects effect
  WHERE effect.company_id=v_company
    AND effect.delivery_document_id=p_delivery_document_id
    AND effect.dispatch_idempotency_key=p_idempotency_key;
  IF FOUND THEN
    SELECT event.* INTO STRICT v_event FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=v_effect.financial_event_id;
    RETURN jsonb_build_object('dispatchFinancialEffectId',v_effect.id,
      'financialEventId',v_event.id,'financialEventStatus',v_event.status,
      'effectiveDate',v_effect.effective_date,'commercialAmount',
      v_effect.commercial_amount,'taxAmount',v_effect.tax_amount,
      'deliveryFeeAmount',v_effect.delivery_fee_amount,
      'paymentSurchargeAmount',v_effect.payment_surcharge_amount,
      'roundingAdjustment',v_effect.rounding_adjustment,
      'receivableAmount',v_effect.receivable_amount,
      'clearingAmount',v_effect.clearing_amount,
      'advanceAppliedAmount',v_effect.advance_applied_amount,
      'fifoCostTotal',v_effect.fifo_cost_total,'exactRetry',TRUE);
  END IF;

  SELECT delivery.* INTO v_delivery
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id
  FOR UPDATE;
  IF NOT FOUND OR v_delivery.reservation_id IS NULL THEN
    RAISE EXCEPTION 'DISPATCH_FINANCE_SOURCE_NOT_FOUND';
  END IF;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_delivery.sales_id FOR SHARE;

  SELECT COALESCE(company.timezone,'Asia/Jakarta') INTO v_timezone
  FROM public.companies company WHERE company.id=v_company;
  SELECT max(allocation.created_at),sum(allocation.dispatched_base_qty),
    round(COALESCE(sum(allocation.dispatched_base_qty*
      allocation.unit_cost_snapshot) FILTER(
        WHERE allocation.allocation_kind='FIFO'),0),4),
    count(*) FILTER(WHERE allocation.allocation_kind='NEGATIVE'),
    count(*) FILTER(WHERE allocation.allocation_kind='NEGATIVE'
      AND negative_allocation.id IS NULL)
  INTO v_dispatch_at,v_dispatched,v_fifo_cost,v_negative_rows,v_negative_missing
  FROM public.sales_dispatch_allocations allocation
  JOIN public.sales_stock_reservation_lines reservation_line
    ON reservation_line.company_id=allocation.company_id
   AND reservation_line.id=allocation.reservation_line_id
  LEFT JOIN public.negative_stock_sale_allocations negative_allocation
    ON negative_allocation.company_id=reservation_line.company_id
   AND negative_allocation.stock_requirement_id=reservation_line.stock_requirement_id
  WHERE allocation.company_id=v_company
    AND allocation.delivery_document_id=v_delivery.id
    AND allocation.reservation_id=v_delivery.reservation_id
    AND allocation.dispatch_idempotency_key=p_idempotency_key;
  v_cost:=round(COALESCE((p_stock_result->>'fifoCostTotal')::NUMERIC,-1),4);
  IF v_dispatched IS NULL OR v_dispatched<=0 OR v_cost<0
    OR v_negative_missing<>0 THEN
    RAISE EXCEPTION 'DISPATCH_FINANCE_ALLOCATION_INCOMPLETE';
  END IF;
  IF round(COALESCE((p_stock_result->>'dispatchedBaseQty')::NUMERIC,-1),6)
      IS DISTINCT FROM round(v_dispatched,6) THEN
    RAISE EXCEPTION 'DISPATCH_FINANCE_STOCK_RESULT_MISMATCH';
  END IF;
  v_negative_cost_total:=round(v_cost-v_fifo_cost,4);
  IF (v_negative_rows=0 AND v_negative_cost_total<>0)
    OR v_negative_cost_total<0 THEN
    RAISE EXCEPTION 'DISPATCH_FINANCE_COST_RECONCILIATION_FAILED';
  END IF;
  v_effective_date:=(v_dispatch_at AT TIME ZONE v_timezone)::DATE;
  v_final:=v_delivery.status='DISPATCHED';

  IF EXISTS(
    WITH per_requirement AS (
      SELECT reservation_line.sales_detail_id,reservation_line.id,
        sum(allocation.dispatched_base_qty)/reservation_line.reserved_base_qty ratio
      FROM public.sales_dispatch_allocations allocation
      JOIN public.sales_stock_reservation_lines reservation_line
        ON reservation_line.company_id=allocation.company_id
       AND reservation_line.id=allocation.reservation_line_id
      WHERE allocation.company_id=v_company
        AND allocation.delivery_document_id=v_delivery.id
        AND allocation.dispatch_idempotency_key=p_idempotency_key
      GROUP BY reservation_line.sales_detail_id,reservation_line.id,
        reservation_line.reserved_base_qty
    )
    SELECT 1 FROM per_requirement GROUP BY sales_detail_id
    HAVING max(ratio)-min(ratio)>0.000001 OR min(ratio)<=0 OR max(ratio)>1
  ) THEN RAISE EXCEPTION 'DISPATCH_COMMERCIAL_LINEAGE_INVALID'; END IF;

  SELECT COALESCE(sum(line.line_total-COALESCE(line.tax_amount,0)),0),
    COALESCE(sum(line.tax_amount),0)
  INTO v_target_net,v_target_tax FROM public.sales_details line
  WHERE line.company_id=v_company AND line.sales_id=v_sale.id;
  SELECT COALESCE(sum(effect.commercial_amount),0),
    COALESCE(sum(effect.tax_amount),0),COALESCE(sum(effect.delivery_fee_amount),0),
    COALESCE(sum(effect.payment_surcharge_amount),0),
    COALESCE(sum(effect.rounding_adjustment),0)
  INTO v_prior_net,v_prior_tax,v_prior_delivery,v_prior_surcharge,v_prior_rounding
  FROM public.sales_dispatch_financial_effects effect
  WHERE effect.company_id=v_company AND effect.sales_id=v_sale.id;
  SELECT COALESCE(sum(payment.customer_surcharge_amount),0)
  INTO v_target_surcharge FROM public.sales_payments payment
  WHERE payment.company_id=v_company AND payment.sales_id=v_sale.id
    AND NOT payment.is_reversal;

  IF v_final THEN
    v_net:=round(v_target_net-v_prior_net,4);
    v_tax:=round(v_target_tax-v_prior_tax,4);
    v_delivery_fee:=round(COALESCE(v_sale.delivery_fee_amount,0)-v_prior_delivery,4);
    v_surcharge:=round(v_target_surcharge-v_prior_surcharge,4);
    v_rounding:=round(COALESCE(v_sale.rounding_adjustment,0)-v_prior_rounding,4);
  ELSE
    WITH per_requirement AS (
      SELECT reservation_line.sales_detail_id,reservation_line.id,
        sum(allocation.dispatched_base_qty)/reservation_line.reserved_base_qty ratio
      FROM public.sales_dispatch_allocations allocation
      JOIN public.sales_stock_reservation_lines reservation_line
        ON reservation_line.company_id=allocation.company_id
       AND reservation_line.id=allocation.reservation_line_id
      WHERE allocation.company_id=v_company
        AND allocation.delivery_document_id=v_delivery.id
        AND allocation.dispatch_idempotency_key=p_idempotency_key
      GROUP BY reservation_line.sales_detail_id,reservation_line.id,
        reservation_line.reserved_base_qty
    ),commercial_ratio AS (
      SELECT sales_detail_id,min(ratio) ratio FROM per_requirement
      GROUP BY sales_detail_id
    )
    SELECT round(COALESCE(sum(
        (line.line_total-COALESCE(line.tax_amount,0))*ratio.ratio),0),4),
      round(COALESCE(sum(COALESCE(line.tax_amount,0)*ratio.ratio),0),4)
    INTO v_net,v_tax FROM commercial_ratio ratio
    JOIN public.sales_details line ON line.company_id=v_company
      AND line.id=ratio.sales_detail_id AND line.sales_id=v_sale.id;
  END IF;

  IF v_net<=0 OR v_tax<0 OR v_delivery_fee<0 OR v_surcharge<0 THEN
    RAISE EXCEPTION 'DISPATCH_COMMERCIAL_AMOUNT_INVALID';
  END IF;
  v_settlement:=round(v_net+v_tax+v_delivery_fee+v_surcharge+v_rounding,4);
  IF v_settlement<=0 THEN RAISE EXCEPTION 'DISPATCH_SETTLEMENT_AMOUNT_INVALID'; END IF;
  IF v_sale.is_tempo THEN v_receivable:=v_settlement;
  ELSE v_clearing:=v_settlement; END IF;

  SELECT count(*),(array_agg(category.id ORDER BY category.id))[1]
  INTO v_category_count,v_category
  FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='SALE_DISPATCHED'
    AND category.is_active;
  IF v_category_count<>1 OR v_category IS NULL THEN
    RAISE EXCEPTION 'DISPATCH_TRANSACTION_CATEGORY_MISSING_OR_AMBIGUOUS';
  END IF;

  v_snapshot:=jsonb_build_object('snapshotVersion',1,
    'sourceContract','ODR_DISPATCH_OPERATION','salesId',v_sale.id,
    'invoiceNo',v_sale.invoice_no,'deliveryDocumentId',v_delivery.id,
    'deliveryNo',v_delivery.delivery_no,'reservationId',v_delivery.reservation_id,
    'dispatchIdempotencyKey',p_idempotency_key,
    'dispatchVersion',v_delivery.dispatch_version,'dispatchAt',v_dispatch_at,
    'effectiveDate',v_effective_date,'finalDispatch',v_final,
    'isTempo',v_sale.is_tempo,'customerId',v_sale.customer_id,
    'storeId',v_sale.store_id,'warehouseId',v_sale.sales_warehouse_id,
    'dispatchedBaseQty',v_dispatched,'commercialAmount',v_net,
    'taxAmount',v_tax,'deliveryFeeAmount',v_delivery_fee,
    'paymentSurchargeAmount',v_surcharge,'roundingAdjustment',v_rounding,
    'receivableAmount',v_receivable,'clearingAmount',v_clearing,
    'advanceAppliedAmount',v_advance,'fifoCostTotal',v_cost,
    'costBreakdown',jsonb_build_object('fifoCost',v_fifo_cost,
      'negativeProvisionalCost',v_negative_cost_total,
      'negativeAllocationRows',v_negative_rows),
    'stockResult',p_stock_result);

  INSERT INTO public.financial_events(id,event_code,event_type,source_table,
    source_id,root_sales_id,event_date,event_version,idempotency_key,
    payment_method,amounts,status,created_by,company_id,store_id,
    system_event_key,transaction_category_id,transaction_rule_version)
  VALUES(v_event_id,'ODR-DSP-'||upper(replace(v_company::TEXT,'-',''))||'-'||
    upper(replace(p_idempotency_key::TEXT,'-','')),
    'SALE_POSTED'::public.event_type,'sales_dispatch_financial_effects',v_effect_id,
    v_sale.id,v_dispatch_at,1,'ODR_DISPATCH|'||v_company||'|'||p_idempotency_key,
    CASE WHEN v_sale.is_tempo THEN 'TEMPO' ELSE 'PENDING_VERIFICATION' END,
    jsonb_build_object('commercialAmount',v_net,'taxAmount',v_tax,
      'deliveryFeeAmount',v_delivery_fee,'paymentSurchargeAmount',v_surcharge,
      'roundingAdjustment',v_rounding,'receivableAmount',v_receivable,
      'clearingAmount',v_clearing,'advanceAppliedAmount',v_advance,
      'fifoCostTotal',v_cost,'settlementAmount',v_settlement),
    'HOLD'::public.event_status,p_actor_id,v_company,v_sale.store_id,
    'SALE_DISPATCHED',v_category,1)
  RETURNING * INTO v_event;

  INSERT INTO public.sales_dispatch_financial_effects(id,company_id,sales_id,
    delivery_document_id,reservation_id,dispatch_idempotency_key,
    dispatch_version,effective_date,dispatched_base_qty,commercial_amount,
    tax_amount,delivery_fee_amount,payment_surcharge_amount,rounding_adjustment,
    receivable_amount,clearing_amount,advance_applied_amount,fifo_cost_total,
    source_snapshot,financial_event_id,created_by,created_at)
  VALUES(v_effect_id,v_company,v_sale.id,v_delivery.id,v_delivery.reservation_id,
    p_idempotency_key,v_delivery.dispatch_version,v_effective_date,v_dispatched,
    v_net,v_tax,v_delivery_fee,v_surcharge,v_rounding,v_receivable,v_clearing,
    v_advance,v_cost,v_snapshot,v_event.id,p_actor_id,v_dispatch_at)
  RETURNING * INTO v_effect;
  INSERT INTO public.sales_dispatch_financial_effect_audit(company_id,
    dispatch_financial_effect_id,action,actor_id,idempotency_key,state)
  VALUES(v_company,v_effect.id,'CAPTURE',p_actor_id,p_idempotency_key,v_snapshot),
    (v_company,v_effect.id,'EVENT_CREATED',p_actor_id,p_idempotency_key,
      jsonb_build_object('financialEventId',v_event.id,
        'financialEventStatus',v_event.status,'eventCode',v_event.event_code));
  RETURN jsonb_build_object('dispatchFinancialEffectId',v_effect.id,
    'financialEventId',v_event.id,'financialEventStatus',v_event.status,
    'effectiveDate',v_effect.effective_date,'commercialAmount',v_net,
    'taxAmount',v_tax,'deliveryFeeAmount',v_delivery_fee,
    'paymentSurchargeAmount',v_surcharge,'roundingAdjustment',v_rounding,
    'receivableAmount',v_receivable,'clearingAmount',v_clearing,
    'advanceAppliedAmount',v_advance,'fifoCostTotal',v_cost,'exactRetry',FALSE);
END
$$;

CREATE FUNCTION private.dispatch_sales_delivery_core(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_idempotency_key UUID,p_lines JSONB,p_notes TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_stock JSONB;v_finance JSONB;
BEGIN
  v_stock:=private.dispatch_sales_delivery_stock_core_odr3c(
    p_delivery_document_id,p_master_version,p_idempotency_key,p_lines,p_notes);
  v_finance:=private.capture_dispatch_financial_effect_core(
    p_delivery_document_id,p_idempotency_key,auth.uid(),v_stock);
  RETURN v_stock||jsonb_build_object('finance',v_finance);
END
$$;

CREATE FUNCTION private.post_odr_dispatch_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_event public.financial_events%ROWTYPE;
  v_effect public.sales_dispatch_financial_effects%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;v_period public.accounting_periods%ROWTYPE;
  v_journal public.finance_journals%ROWTYPE;v_component RECORD;
  v_account UUID;v_line_no INTEGER:=0;v_debit NUMERIC(24,4):=0;
  v_credit NUMERIC(24,4):=0;v_amount NUMERIC(24,4);
  v_rule_version BIGINT;v_journal_type TEXT:='AUTOMATIC';
  v_rule_count BIGINT;
  v_accounting_date DATE;v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT event.* INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF p_expected_event_version IS DISTINCT FROM v_event.event_version THEN
    RAISE EXCEPTION 'EVENT_VERSION_CONFLICT';
  END IF;
  IF v_event.status::TEXT='POSTED' THEN
    SELECT journal.* INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id
      AND journal.financial_event_id=v_event.id AND journal.status='POSTED';
    RETURN jsonb_build_object('financialEventId',v_event.id,
      'journalId',v_journal.id,'journalNo',v_journal.journal_no,
      'status','POSTED','idempotentReplay',TRUE);
  END IF;
  IF v_event.status::TEXT<>'HOLD' OR v_event.system_event_key<>'SALE_DISPATCHED'
    OR v_event.event_type::TEXT<>'SALE_POSTED'
    OR v_event.source_table<>'sales_dispatch_financial_effects' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;
  SELECT effect.* INTO v_effect FROM public.sales_dispatch_financial_effects effect
  WHERE effect.company_id=p_company_id AND effect.id=v_event.source_id
    AND effect.financial_event_id=v_event.id FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_SOURCE_NOT_FOUND'; END IF;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=v_effect.sales_id FOR SHARE;
  IF round((v_event.amounts->>'commercialAmount')::NUMERIC,4)<>v_effect.commercial_amount
    OR round((v_event.amounts->>'taxAmount')::NUMERIC,4)<>v_effect.tax_amount
    OR round((v_event.amounts->>'deliveryFeeAmount')::NUMERIC,4)<>v_effect.delivery_fee_amount
    OR round((v_event.amounts->>'paymentSurchargeAmount')::NUMERIC,4)<>
      v_effect.payment_surcharge_amount
    OR round((v_event.amounts->>'roundingAdjustment')::NUMERIC,4)<>
      v_effect.rounding_adjustment
    OR round((v_event.amounts->>'receivableAmount')::NUMERIC,4)<>
      v_effect.receivable_amount
    OR round((v_event.amounts->>'clearingAmount')::NUMERIC,4)<>
      v_effect.clearing_amount
    OR round((v_event.amounts->>'advanceAppliedAmount')::NUMERIC,4)<>
      v_effect.advance_applied_amount
    OR round((v_event.amounts->>'fifoCostTotal')::NUMERIC,4)<>
      v_effect.fifo_cost_total
    OR round(v_effect.receivable_amount+v_effect.clearing_amount+
      v_effect.advance_applied_amount,4)<>round(v_effect.commercial_amount+
      v_effect.tax_amount+v_effect.delivery_fee_amount+
      v_effect.payment_surcharge_amount+v_effect.rounding_adjustment,4) THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;

  SELECT period.* INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_effect.effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT period.* INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id
      AND period.start_date>v_effect.effective_date
      AND period.status IN('OPEN','REOPENED')
    ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';
    v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_effect.effective_date; END IF;

  SELECT count(*),max(rule_set.rule_set_version)
  INTO v_rule_count,v_rule_version
  FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id
    AND rule_set.transaction_category_id=v_event.transaction_category_id
    AND rule_set.system_key='SALE_DISPATCHED' AND rule_set.status='APPROVED'
    AND rule_set.effective_from<=v_event.event_date
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_event.event_date);
  IF v_rule_count<>1 OR v_rule_version IS NULL THEN
    RAISE EXCEPTION 'POSTING_RULE_SET_MISSING_OR_AMBIGUOUS';
  END IF;

  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,warehouse_id,
    description,status,created_by)
  VALUES(p_company_id,'ODR-'||replace(v_event.id::TEXT,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_effect.effective_date,v_event.source_table,
    v_effect.id,v_effect.dispatch_version,v_event.id,
    'ODR_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,v_rule_version,
    v_sale.store_id,v_sale.sales_warehouse_id,
    'ODR Dispatch: '||v_event.event_code,'DRAFT',p_actor_id)
  RETURNING * INTO v_journal;

  FOR v_component IN SELECT * FROM (VALUES
    ('CUSTOMER_RECEIVABLE'::TEXT,v_effect.receivable_amount,'DEBIT'::TEXT),
    ('PAYMENT_CLEARING',v_effect.clearing_amount,'DEBIT'),
    ('CUSTOMER_ADVANCE_LIABILITY',v_effect.advance_applied_amount,'DEBIT'),
    ('SALES_REVENUE',v_effect.commercial_amount,'CREDIT'),
    ('OUTPUT_TAX',v_effect.tax_amount,'CREDIT'),
    ('DELIVERY_FEE_REVENUE',v_effect.delivery_fee_amount,'CREDIT'),
    ('PAYMENT_SURCHARGE_INCOME',v_effect.payment_surcharge_amount,'CREDIT'),
    ('ROUNDING_GAIN',GREATEST(v_effect.rounding_adjustment,0),'CREDIT'),
    ('ROUNDING_LOSS',GREATEST(-v_effect.rounding_adjustment,0),'DEBIT'),
    ('COGS',v_effect.fifo_cost_total,'DEBIT'),
    ('INVENTORY_ASSET',v_effect.fifo_cost_total,'CREDIT')
  ) component(function_key,amount,side) WHERE component.amount>0
  LOOP
    v_account:=private.resolve_financial_event_account(
      v_event,v_component.function_key);
    v_line_no:=v_line_no+1;v_amount:=round(v_component.amount,4);
    INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,
      account_id,debit,credit,store_id,warehouse_id,customer_id,description)
    VALUES(p_company_id,v_journal.id,v_line_no,v_account,
      CASE WHEN v_component.side='DEBIT' THEN v_amount ELSE 0 END,
      CASE WHEN v_component.side='CREDIT' THEN v_amount ELSE 0 END,
      v_sale.store_id,v_sale.sales_warehouse_id,v_sale.customer_id,
      v_component.function_key);
    IF v_component.side='DEBIT' THEN v_debit:=v_debit+v_amount;
    ELSE v_credit:=v_credit+v_amount; END IF;
  END LOOP;
  IF v_line_no<2 OR v_debit<=0 OR round(v_debit,4)<>round(v_credit,4) THEN
    RAISE EXCEPTION 'JOURNAL_UNBALANCED';
  END IF;
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,
    posted_at=v_now WHERE company_id=p_company_id AND id=v_journal.id
  RETURNING * INTO v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=v_rule_version
  WHERE company_id=p_company_id AND id=v_event.id;
  INSERT INTO public.sales_dispatch_financial_effect_audit(company_id,
    dispatch_financial_effect_id,action,actor_id,idempotency_key,state)
  VALUES(p_company_id,v_effect.id,'POSTED',p_actor_id,
    v_effect.dispatch_idempotency_key,jsonb_build_object(
      'financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'accountingDate',v_journal.accounting_date,
      'totalDebit',v_journal.total_debit,'totalCredit',v_journal.total_credit));
  RETURN jsonb_build_object('financialEventId',v_event.id,
    'journalId',v_journal.id,'journalNo',v_journal.journal_no,'status','POSTED',
    'journalType',v_journal.journal_type,'accountingDate',v_journal.accounting_date,
    'totalDebit',v_journal.total_debit,'totalCredit',v_journal.total_credit,
    'idempotentReplay',FALSE);
END
$$;

ALTER FUNCTION private.post_financial_event_core(UUID,UUID,BIGINT,UUID)
RENAME TO post_financial_event_core_pre_odr5c;

CREATE FUNCTION private.post_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_key TEXT;v_source TEXT;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key='SALE_DISPATCHED'
    AND v_source='sales_dispatch_financial_effects' THEN
    RETURN private.post_odr_dispatch_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  RETURN private.post_financial_event_core_pre_odr5c(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

CREATE OR REPLACE FUNCTION private.f4b_financial_event_supported(
  p_event public.financial_events
) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT p_event.status::TEXT='HOLD' AND CASE p_event.system_event_key
    WHEN 'STOCK_OPENING' THEN p_event.source_table='opening_stock_documents'
    WHEN 'SALE_POSTED' THEN p_event.source_table='sales_headers'
    WHEN 'SALES_RETURN' THEN p_event.source_table='sales_return_documents'
    WHEN 'GOODS_RECEIPT' THEN p_event.source_table='goods_receipt_documents'
    WHEN 'SUPPLIER_INVOICE' THEN p_event.source_table='supplier_invoice_documents'
    WHEN 'SUPPLIER_PAYMENT' THEN p_event.source_table='supplier_payment_documents'
    WHEN 'STOCK_GAIN' THEN p_event.source_table='stock_adjustment_documents'
    WHEN 'EXPENSE_DISBURSEMENT' THEN p_event.source_table='expense_disbursements'
    WHEN 'CASH_DEPOSIT' THEN p_event.source_table='cash_deposit_documents'
    WHEN 'CASH_VARIANCE' THEN p_event.source_table='deposit_variance_resolution_requests'
    WHEN 'SALE_PAYMENT' THEN p_event.source_table='customer_receipt_documents'
    WHEN 'CUSTOMER_BALANCE_RECEIPT' THEN p_event.source_table='customer_receipt_documents'
    WHEN 'SALE_DISPATCHED' THEN
      p_event.source_table='sales_dispatch_financial_effects'
    ELSE FALSE END
$$;

ALTER TABLE public.sales_dispatch_financial_effects
  ALTER COLUMN financial_event_id SET NOT NULL;

REVOKE ALL ON FUNCTION
  private.dispatch_sales_delivery_stock_core_odr3c(UUID,BIGINT,UUID,JSONB,TEXT),
  private.capture_dispatch_financial_effect_core(UUID,UUID,UUID,JSONB),
  private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.post_odr_dispatch_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core_pre_odr5c(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.f4b_financial_event_supported(public.financial_events),
  private.trg_odr5c_guard_automatic_posting_policy()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.dispatch_sales_delivery_stock_core_odr3c(UUID,BIGINT,UUID,JSONB,TEXT),
  private.capture_dispatch_financial_effect_core(UUID,UUID,UUID,JSONB),
  private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.post_odr_dispatch_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core_pre_odr5c(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.f4b_financial_event_supported(public.financial_events),
  private.trg_odr5c_guard_automatic_posting_policy()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828230000','odr_phase5c_dispatch_finance_runtime',
  'Atomically wrap ODR Dispatch stock core with immutable proportional commercial and actual FIFO Finance capture, create one HOLD SALE_DISPATCHED event per operation, add controlled canonical posting, preserve legacy dispatcher, and keep automatic mode blocked until ODR-5D');

NOTIFY pgrst,'reload schema';
COMMIT;
