-- ODR-5F: close controlled/automatic parity for Dispatch and Payment events.
-- Existing Company posting modes are preserved; this migration only unlocks
-- the already-versioned policy switch after all ODR Finance contracts exist.
BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828240000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828250000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5D and ODR-5E required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828260000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828260000';
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
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: authenticated ODR smoke required after closure';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_exceptions
      WHERE status<>'RESOLVED') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open Finance posting exception';
  END IF;
  SELECT pg_get_functiondef(
    'private.post_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
  INTO v_definition;
  IF v_definition IS NULL
    OR v_definition!~'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED'
    OR v_definition!~'post_odr_payment_financial_event_core'
    OR v_definition!~'post_financial_event_core_pre_odr5d' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5E dispatcher changed';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.post_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_key TEXT;v_source TEXT;v_sales UUID;v_advance NUMERIC(24,4);
  v_result JSONB;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key='SALE_PAYMENT_VERIFIED'
    AND v_source='sales_payment_verification_requests' THEN
    v_result:=private.post_odr_payment_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  ELSE
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
    v_result:=private.post_financial_event_core_pre_odr5d(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  IF v_result->>'status'='CANCELED'
    AND COALESCE((v_result->>'noFinancialEffect')::BOOLEAN,FALSE) THEN
    v_result:=v_result||jsonb_build_object('reason','NO_FINANCIAL_EFFECT');
  END IF;
  RETURN v_result;
END
$$;

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
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.trg_odr5c_guard_automatic_posting_policy()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.trg_odr5c_guard_automatic_posting_policy()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828260000','odr_phase5f_finance_runtime_closure',
  'Close controlled and automatic ODR Dispatch/Payment posting parity, normalize zero-effect result, retain advance-before-Dispatch dependency, preserve all existing Company CONTROLLED policies, and unlock the audited policy switch for explicit Owner/Admin use');

NOTIFY pgrst,'reload schema';
COMMIT;
