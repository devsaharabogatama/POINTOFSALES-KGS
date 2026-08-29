-- ODR-5E: apply verified pre-dispatch Customer Advance and immutable payment
-- surcharge to the Dispatch Finance source in the same atomic transaction.
BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828230000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828240000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5C and ODR-5D required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828250000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828250000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_company_policies
      WHERE posting_mode='AUTOMATIC') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: CONTROLLED posting required';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects)
    OR EXISTS(SELECT 1 FROM public.sales_payment_verification_requests) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR Finance runtime must be empty';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_sales_delivery_core(uuid,bigint,uuid,jsonb,text)'::regprocedure)
  INTO v_definition;
  IF v_definition IS NULL
    OR v_definition!~'dispatch_sales_delivery_core_pre_odr5d'
    OR v_definition!~'ODR_PREDISPATCH_ADVANCE_APPLICATION_NOT_READY'
    OR v_definition!~'ODR_PAYMENT_SURCHARGE_DISPATCH_APPLICATION_NOT_READY' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5D Dispatch guard changed';
  END IF;
END
$guard$;

ALTER TABLE public.sales_dispatch_financial_effects
  ADD COLUMN settlement_rebalance_version BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN settlement_rebalanced_at TIMESTAMPTZ,
  ADD CONSTRAINT sales_dispatch_effect_rebalance_version_check CHECK(
    settlement_rebalance_version IN(0,1)),
  ADD CONSTRAINT sales_dispatch_effect_rebalance_state_check CHECK(
    (settlement_rebalance_version=0 AND settlement_rebalanced_at IS NULL)
    OR (settlement_rebalance_version=1 AND settlement_rebalanced_at IS NOT NULL));

ALTER TABLE public.sales_dispatch_financial_effect_audit
  DROP CONSTRAINT sales_dispatch_financial_effect_audit_action_check,
  ADD CONSTRAINT sales_dispatch_financial_effect_audit_action_check
    CHECK(action IN('CAPTURE','EVENT_CREATED','REBALANCE','POSTED','ERROR'));

CREATE OR REPLACE FUNCTION private.trg_odr5_guard_dispatch_financial_effect()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_sales UUID;v_reservation UUID;v_event_status TEXT;
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_IMMUTABLE'; END IF;
  IF TG_OP='UPDATE' THEN
    IF COALESCE(current_setting(
      'kgs.odr5e_dispatch_finance_rebalance',TRUE),'')<>'1' THEN
      RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_IMMUTABLE';
    END IF;
    IF (NEW.company_id,NEW.sales_id,NEW.delivery_document_id,NEW.reservation_id,
        NEW.dispatch_idempotency_key,NEW.dispatch_version,NEW.effective_date,
        NEW.dispatched_base_qty,NEW.commercial_amount,NEW.tax_amount,
        NEW.delivery_fee_amount,NEW.rounding_adjustment,NEW.fifo_cost_total,
        NEW.financial_event_id,NEW.created_by,NEW.created_at) IS DISTINCT FROM
       (OLD.company_id,OLD.sales_id,OLD.delivery_document_id,OLD.reservation_id,
        OLD.dispatch_idempotency_key,OLD.dispatch_version,OLD.effective_date,
        OLD.dispatched_base_qty,OLD.commercial_amount,OLD.tax_amount,
        OLD.delivery_fee_amount,OLD.rounding_adjustment,OLD.fifo_cost_total,
        OLD.financial_event_id,OLD.created_by,OLD.created_at)
      OR OLD.settlement_rebalance_version<>0
      OR NEW.settlement_rebalance_version<>1
      OR NEW.settlement_rebalanced_at IS NULL THEN
      RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_REBALANCE_INVALID';
    END IF;
    SELECT event.status::TEXT INTO v_event_status FROM public.financial_events event
    WHERE event.company_id=OLD.company_id AND event.id=OLD.financial_event_id;
    IF v_event_status<>'HOLD' OR EXISTS(SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=OLD.company_id
        AND journal.financial_event_id=OLD.financial_event_id) THEN
      RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_ALREADY_POSTED';
    END IF;
    RETURN NEW;
  END IF;
  SELECT delivery.sales_id,delivery.reservation_id INTO v_sales,v_reservation
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=NEW.company_id AND delivery.id=NEW.delivery_document_id;
  IF v_sales IS DISTINCT FROM NEW.sales_id
    OR v_reservation IS DISTINCT FROM NEW.reservation_id THEN
    RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_SOURCE_MISMATCH';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_dispatch_allocations allocation
    WHERE allocation.company_id=NEW.company_id
      AND allocation.delivery_document_id=NEW.delivery_document_id
      AND allocation.reservation_id=NEW.reservation_id
      AND allocation.dispatch_idempotency_key=NEW.dispatch_idempotency_key) THEN
    RAISE EXCEPTION 'DISPATCH_OPERATION_NOT_FOUND';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.rebalance_dispatch_settlement_odr5e(
  p_company_id UUID,p_delivery_document_id UUID,p_idempotency_key UUID,
  p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_effect public.sales_dispatch_financial_effects%ROWTYPE;
  v_event public.financial_events%ROWTYPE;v_sale public.sales_headers%ROWTYPE;
  v_target_surcharge NUMERIC(24,4);v_prior_surcharge NUMERIC(24,4);
  v_surcharge NUMERIC(24,4);v_verified_advance NUMERIC(24,4);
  v_prior_advance NUMERIC(24,4);v_advance NUMERIC(24,4);
  v_settlement NUMERIC(24,4);v_remaining NUMERIC(24,4);
  v_receivable NUMERIC(24,4):=0;v_clearing NUMERIC(24,4):=0;
  v_final BOOLEAN;v_now TIMESTAMPTZ:=clock_timestamp();v_snapshot JSONB;
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT effect.* INTO v_effect FROM public.sales_dispatch_financial_effects effect
  WHERE effect.company_id=p_company_id
    AND effect.delivery_document_id=p_delivery_document_id
    AND effect.dispatch_idempotency_key=p_idempotency_key FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DISPATCH_FINANCIAL_EFFECT_NOT_FOUND'; END IF;
  SELECT event.* INTO STRICT v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=v_effect.financial_event_id
  FOR UPDATE;
  IF v_effect.settlement_rebalance_version=1 THEN
    RETURN jsonb_build_object('dispatchFinancialEffectId',v_effect.id,
      'financialEventId',v_event.id,'financialEventStatus',v_event.status,
      'effectiveDate',v_effect.effective_date,
      'commercialAmount',v_effect.commercial_amount,'taxAmount',v_effect.tax_amount,
      'deliveryFeeAmount',v_effect.delivery_fee_amount,
      'paymentSurchargeAmount',v_effect.payment_surcharge_amount,
      'roundingAdjustment',v_effect.rounding_adjustment,
      'receivableAmount',v_effect.receivable_amount,
      'clearingAmount',v_effect.clearing_amount,
      'advanceAppliedAmount',v_effect.advance_applied_amount,
      'fifoCostTotal',v_effect.fifo_cost_total,'settlementRebalanced',TRUE,
      'exactRetry',TRUE);
  END IF;
  IF v_event.status::TEXT<>'HOLD' THEN RAISE EXCEPTION 'DISPATCH_EVENT_NOT_HOLD'; END IF;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=v_effect.sales_id FOR SHARE;
  v_final:=COALESCE((v_effect.source_snapshot->>'finalDispatch')::BOOLEAN,FALSE);

  SELECT round(COALESCE(sum(COALESCE(
      (request.intent_snapshot->>'customerSurchargeAmount')::NUMERIC,0)),0),4)
  INTO v_target_surcharge
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=p_company_id AND request.sales_id=v_effect.sales_id
    AND request.status<>'CANCELED';
  SELECT round(COALESCE(sum(effect.payment_surcharge_amount),0),4),
    round(COALESCE(sum(effect.advance_applied_amount),0),4)
  INTO v_prior_surcharge,v_prior_advance
  FROM public.sales_dispatch_financial_effects effect
  WHERE effect.company_id=p_company_id AND effect.sales_id=v_effect.sales_id
    AND effect.id<>v_effect.id;
  v_surcharge:=CASE WHEN v_final
    THEN round(v_target_surcharge-v_prior_surcharge,4) ELSE 0 END;
  IF v_surcharge<0 THEN RAISE EXCEPTION 'DISPATCH_SURCHARGE_RECONCILIATION_FAILED'; END IF;

  SELECT round(COALESCE(sum(request.amount),0),4) INTO v_verified_advance
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=p_company_id AND request.sales_id=v_effect.sales_id
    AND request.status='VERIFIED' AND request.receipt_timing='PRE_DISPATCH'
    AND request.settlement_target='CUSTOMER_ADVANCE';
  v_settlement:=round(v_effect.commercial_amount+v_effect.tax_amount+
    v_effect.delivery_fee_amount+v_surcharge+v_effect.rounding_adjustment,4);
  IF v_settlement<=0 THEN RAISE EXCEPTION 'DISPATCH_SETTLEMENT_AMOUNT_INVALID'; END IF;
  v_advance:=LEAST(v_settlement,GREATEST(v_verified_advance-v_prior_advance,0));
  v_remaining:=round(v_settlement-v_advance,4);
  IF v_sale.is_tempo THEN v_receivable:=v_remaining;
  ELSE v_clearing:=v_remaining; END IF;
  v_snapshot:=v_effect.source_snapshot||jsonb_build_object(
    'paymentSurchargeAmount',v_surcharge,'receivableAmount',v_receivable,
    'clearingAmount',v_clearing,'advanceAppliedAmount',v_advance,
    'settlementRebalance',jsonb_build_object('version',1,
      'verifiedPredispatchAdvance',v_verified_advance,
      'priorAdvanceApplied',v_prior_advance,'targetPaymentSurcharge',
      v_target_surcharge,'priorPaymentSurcharge',v_prior_surcharge,
      'rebalancedAt',v_now));

  PERFORM set_config('kgs.odr5e_dispatch_finance_rebalance','1',TRUE);
  UPDATE public.sales_dispatch_financial_effects SET
    payment_surcharge_amount=v_surcharge,receivable_amount=v_receivable,
    clearing_amount=v_clearing,advance_applied_amount=v_advance,
    source_snapshot=v_snapshot,settlement_rebalance_version=1,
    settlement_rebalanced_at=v_now
  WHERE company_id=p_company_id AND id=v_effect.id RETURNING * INTO v_effect;
  PERFORM set_config('kgs.odr5e_dispatch_finance_rebalance','',TRUE);

  UPDATE public.financial_events SET amounts=amounts||jsonb_build_object(
      'paymentSurchargeAmount',v_surcharge,'receivableAmount',v_receivable,
      'clearingAmount',v_clearing,'advanceAppliedAmount',v_advance,
      'settlementAmount',v_settlement),event_version=event_version+1
  WHERE company_id=p_company_id AND id=v_event.id AND status='HOLD'::public.event_status
  RETURNING * INTO v_event;
  IF NOT FOUND THEN RAISE EXCEPTION 'DISPATCH_EVENT_REBALANCE_FAILED'; END IF;
  INSERT INTO public.sales_dispatch_financial_effect_audit(company_id,
    dispatch_financial_effect_id,action,actor_id,idempotency_key,state)
  VALUES(p_company_id,v_effect.id,'REBALANCE',p_actor_id,p_idempotency_key,
    jsonb_build_object('financialEventId',v_event.id,
      'financialEventVersion',v_event.event_version,'settlementAmount',v_settlement,
      'paymentSurchargeAmount',v_surcharge,'receivableAmount',v_receivable,
      'clearingAmount',v_clearing,'advanceAppliedAmount',v_advance));
  RETURN jsonb_build_object('dispatchFinancialEffectId',v_effect.id,
    'financialEventId',v_event.id,'financialEventStatus',v_event.status,
    'financialEventVersion',v_event.event_version,
    'effectiveDate',v_effect.effective_date,
    'commercialAmount',v_effect.commercial_amount,'taxAmount',v_effect.tax_amount,
    'deliveryFeeAmount',v_effect.delivery_fee_amount,
    'paymentSurchargeAmount',v_surcharge,
    'roundingAdjustment',v_effect.rounding_adjustment,
    'receivableAmount',v_receivable,'clearingAmount',v_clearing,
    'advanceAppliedAmount',v_advance,'fifoCostTotal',v_effect.fifo_cost_total,
    'settlementRebalanced',TRUE,'exactRetry',FALSE);
END
$$;

CREATE OR REPLACE FUNCTION private.dispatch_sales_delivery_core(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_idempotency_key UUID,p_lines JSONB,p_notes TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_result JSONB;v_finance JSONB;
BEGIN
  v_result:=private.dispatch_sales_delivery_core_pre_odr5d(
    p_delivery_document_id,p_master_version,p_idempotency_key,p_lines,p_notes);
  v_finance:=private.rebalance_dispatch_settlement_odr5e(
    v_company,p_delivery_document_id,p_idempotency_key,auth.uid());
  RETURN v_result||jsonb_build_object('finance',v_finance);
END
$$;

CREATE OR REPLACE FUNCTION private.post_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_key TEXT;v_source TEXT;v_sales UUID;v_advance NUMERIC(24,4);
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key='SALE_PAYMENT_VERIFIED'
    AND v_source='sales_payment_verification_requests' THEN
    RETURN private.post_odr_payment_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  IF v_key='SALE_DISPATCHED' AND v_source='sales_dispatch_financial_effects' THEN
    SELECT effect.sales_id,effect.advance_applied_amount INTO v_sales,v_advance
    FROM public.sales_dispatch_financial_effects effect
    WHERE effect.company_id=p_company_id AND effect.id=(SELECT event.source_id
      FROM public.financial_events event
      WHERE event.company_id=p_company_id AND event.id=p_event_id);
    IF COALESCE(v_advance,0)>0 AND EXISTS(SELECT 1
      FROM public.sales_payment_verification_requests request
      JOIN public.financial_events payment_event
        ON payment_event.company_id=request.company_id
       AND payment_event.id=request.financial_event_id
      WHERE request.company_id=p_company_id AND request.sales_id=v_sales
        AND request.status='VERIFIED' AND request.receipt_timing='PRE_DISPATCH'
        AND request.settlement_target='CUSTOMER_ADVANCE'
        AND payment_event.status::TEXT<>'POSTED') THEN
      RAISE EXCEPTION 'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED';
    END IF;
  END IF;
  RETURN private.post_financial_event_core_pre_odr5d(
    p_company_id,p_event_id,p_expected_event_version,p_actor_id);
END
$$;

-- Runtime is complete, but automatic policy remains fail-closed until the
-- ODR-5F authenticated reconciliation/closure gate is installed.
CREATE OR REPLACE FUNCTION private.trg_odr5c_guard_automatic_posting_policy()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.posting_mode='AUTOMATIC'
    AND NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828260000') THEN
    RAISE EXCEPTION 'ODR_AUTOMATIC_POSTING_NOT_READY';
  END IF;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION
  private.trg_odr5_guard_dispatch_financial_effect(),
  private.rebalance_dispatch_settlement_odr5e(UUID,UUID,UUID,UUID),
  private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.trg_odr5c_guard_automatic_posting_policy()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_odr5_guard_dispatch_financial_effect(),
  private.rebalance_dispatch_settlement_odr5e(UUID,UUID,UUID,UUID),
  private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.trg_odr5c_guard_automatic_posting_policy()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828250000','odr_phase5e_dispatch_advance_reconciliation',
  'Atomically rebalance each newly captured Dispatch effect with immutable Order payment surcharge and available verified pre-dispatch Customer Advance, preserve Clearing/AR residual, exact retry and audit, remove temporary Dispatch guards, and keep automatic posting closed until ODR-5F reconciliation');

NOTIFY pgrst,'reload schema';
COMMIT;
