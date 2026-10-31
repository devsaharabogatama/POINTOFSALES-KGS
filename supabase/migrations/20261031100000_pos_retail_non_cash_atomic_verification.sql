-- Direct Retail POS non-cash verification: capture persisted payment legs and
-- post the verification financial effect atomically with Finance approval.
BEGIN;

DO $guard$
DECLARE
  v_definition text;
  v_invalid bigint;
BEGIN
  IF (SELECT count(DISTINCT version) FROM private.kgs_schema_migrations
      WHERE version IN ('20260923100000','20261030120000','20261030130000'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required POS payment/runtime chain';
  END IF;
  IF EXISTS (SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261031100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261031100000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.sales_headers sale
    JOIN public.sales_payments payment
      ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
     AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
    WHERE sale.sales_origin='POS'
      AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.document_status='POSTED'
      AND sale.order_runtime_status='LEGACY_POSTED'
      AND NOT EXISTS (SELECT 1 FROM public.accounting_periods period
        WHERE period.company_id=sale.company_id
          AND current_date BETWEEN period.start_date AND period.end_date
          AND period.status IN ('OPEN','REOPENED'))
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: current postable accounting period required';
  END IF;

  SELECT pg_get_functiondef(
    'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'PAYMENT_VERIFICATION_FINAL'
    OR v_definition!~'MAKER_CHECKER_REQUIRED'
    OR v_definition!~'SALE_PAYMENT_VERIFIED'
    OR v_definition!~'kgs.odr5_payment_verification_mutation' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: payment review runtime drift';
  END IF;

  SELECT pg_get_functiondef(
    'private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'FINANCIAL_EVENT_GROSS_DISCOUNT_MISMATCH'
    OR v_definition!~'kgs_retail_sale_category_components'
    OR v_definition!~'payment\.settlement_account_function_snapshot[[:space:]]+(AS[[:space:]]+)?function_key' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Sale posting composition drift';
  END IF;

  SELECT count(*) INTO v_invalid
  FROM public.sales_headers sale
  JOIN public.sales_payments payment
    ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
   AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
  LEFT JOIN public.sales_payment_verification_requests request
    ON request.company_id=payment.company_id AND request.sales_id=payment.sales_id
   AND request.client_payment_key=payment.client_payment_key
  WHERE sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
    AND request.id IS NULL
    AND (SELECT count(*) FROM public.financial_events event
      WHERE event.company_id=sale.company_id AND event.source_table='sales_headers'
        AND event.source_id=sale.id AND event.system_event_key='SALE_POSTED')<>1;
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: direct non-cash Sale Event identity (%)',v_invalid;
  END IF;

  SELECT count(*) INTO v_invalid
  FROM public.sales_headers sale
  JOIN public.sales_payments payment
    ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
   AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
  LEFT JOIN public.sales_payment_verification_requests request
    ON request.company_id=payment.company_id AND request.sales_id=payment.sales_id
   AND request.client_payment_key=payment.client_payment_key
  JOIN public.financial_events event
    ON event.company_id=sale.company_id AND event.source_table='sales_headers'
   AND event.source_id=sale.id AND event.system_event_key='SALE_POSTED'
  WHERE sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
    AND request.id IS NULL
    AND NOT (
      (event.status='HOLD' AND NOT EXISTS (
        SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id=event.company_id
          AND journal.financial_event_id=event.id))
      OR
      (event.status='POSTED' AND (SELECT count(*)
        FROM public.finance_journals journal
        WHERE journal.company_id=event.company_id
          AND journal.financial_event_id=event.id
          AND journal.status='POSTED')=1)
    );
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous direct non-cash accounting ownership (%)',v_invalid;
  END IF;
END
$guard$;

CREATE FUNCTION private.capture_direct_retail_non_cash_payment_requests(
  p_company_id uuid,p_sales_id uuid,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%rowtype;
  v_session public.cashier_sessions%rowtype;
  v_payment public.sales_payments%rowtype;
  v_existing public.sales_payment_verification_requests%rowtype;
  v_request_id uuid;
  v_snapshot jsonb;
  v_created integer:=0;
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND
    OR v_sale.sales_origin<>'POS'
    OR v_sale.sales_process_mode<>'RETAIL_CONFIRM_INVOICE'
    OR v_sale.document_status<>'POSTED'
    OR v_sale.order_runtime_status<>'LEGACY_POSTED' THEN
    RAISE EXCEPTION 'DIRECT_RETAIL_POSTED_SALE_REQUIRED';
  END IF;
  SELECT session.* INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=p_company_id AND session.id=v_sale.session_id;
  IF NOT FOUND OR v_session.store_id<>v_sale.store_id
    OR v_session.pos_id IS DISTINCT FROM v_sale.pos_id THEN
    RAISE EXCEPTION 'DIRECT_RETAIL_SESSION_SCOPE_MISMATCH';
  END IF;

  FOR v_payment IN
    SELECT payment.* FROM public.sales_payments payment
    WHERE payment.company_id=p_company_id AND payment.sales_id=p_sales_id
      AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
    ORDER BY payment.id
  LOOP
    IF v_payment.client_payment_key IS NULL
      OR v_payment.amount<=0
      OR nullif(btrim(v_payment.settlement_account_function_snapshot),'') IS NULL THEN
      RAISE EXCEPTION 'DIRECT_RETAIL_PAYMENT_SNAPSHOT_INVALID';
    END IF;
    v_snapshot:=jsonb_build_object(
      'snapshotVersion',1,
      'sourceContract','DIRECT_RETAIL_POSTED_PAYMENT',
      'salesPaymentId',v_payment.id,
      'clientPaymentKey',v_payment.client_payment_key,
      'baseAmount',round(v_payment.amount-v_payment.customer_surcharge_amount,4),
      'configuredFeeAmount',v_payment.configured_fee_amount,
      'customerSurchargeAmount',v_payment.customer_surcharge_amount,
      'settlementAmount',v_payment.amount,
      'tenderedAmount',v_payment.tendered_amount,
      'changeAmount',v_payment.change_amount,
      'proofMode','PERSISTED_PAYMENT_SNAPSHOT',
      'feeBearer',v_payment.fee_bearer_snapshot,
      'feeType',v_payment.fee_type_snapshot,
      'feePercent',v_payment.fee_percent_snapshot,
      'feeFixedAmount',v_payment.fee_fixed_amount_snapshot,
      'storeId',v_sale.store_id,
      'cashierSessionId',v_session.id,
      'posTerminalId',v_session.pos_id);
    SELECT request.* INTO v_existing
    FROM public.sales_payment_verification_requests request
    WHERE request.company_id=p_company_id AND request.sales_id=p_sales_id
      AND request.client_payment_key=v_payment.client_payment_key;
    IF FOUND THEN
      IF v_existing.payment_method_id<>v_payment.payment_method_id
        OR v_existing.amount<>v_payment.amount
        OR v_existing.intent_snapshot<>v_snapshot
        OR v_existing.settlement_route_snapshot<>v_payment.settlement_route_snapshot
        OR v_existing.settlement_account_function_snapshot<>
          v_payment.settlement_account_function_snapshot THEN
        RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
      END IF;
      CONTINUE;
    END IF;

    v_request_id:=gen_random_uuid();
    INSERT INTO public.sales_payment_verification_requests(
      id,company_id,sales_id,client_payment_key,payment_method_id,amount,
      proof_url,status,payment_method_code_snapshot,payment_method_name_snapshot,
      payment_method_type_snapshot,settlement_route_snapshot,
      settlement_account_function_snapshot,intent_snapshot,requested_by,
      cashier_session_id,store_id,pos_terminal_id,verification_mode)
    VALUES(
      v_request_id,p_company_id,p_sales_id,v_payment.client_payment_key,
      v_payment.payment_method_id,v_payment.amount,v_payment.proof_url,'PENDING',
      v_payment.payment_method_code_snapshot,v_payment.payment_method_name_snapshot,
      v_payment.payment_method_type_snapshot,v_payment.settlement_route_snapshot,
      v_payment.settlement_account_function_snapshot,v_snapshot,p_actor_id,
      v_session.id,v_sale.store_id,v_session.pos_id,'MANUAL_REVIEW');
    INSERT INTO public.sales_payment_verification_audit(
      company_id,verification_request_id,action,actor_id,idempotency_key,after_state)
    VALUES(p_company_id,v_request_id,'CREATE',p_actor_id,
      v_payment.client_payment_key,jsonb_build_object(
        'status','PENDING','sourceContract','DIRECT_RETAIL_POSTED_PAYMENT',
        'salesPaymentId',v_payment.id,'amount',v_payment.amount,
        'paymentMethodId',v_payment.payment_method_id));
    v_created:=v_created+1;
  END LOOP;
  RETURN jsonb_build_object('createdCount',v_created,'exactRetry',v_created=0);
END
$$;

CREATE FUNCTION private.resolve_direct_retail_sale_payment_function(
  p_company_id uuid,p_sales_id uuid,p_client_payment_key uuid,p_original text
) RETURNS text LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE WHEN EXISTS (
    SELECT 1
    FROM public.sales_headers sale
    JOIN public.sales_payment_verification_requests request
      ON request.company_id=sale.company_id AND request.sales_id=sale.id
     AND request.client_payment_key=p_client_payment_key
     AND request.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
    WHERE sale.company_id=p_company_id AND sale.id=p_sales_id
      AND sale.sales_origin='POS'
      AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.document_status='POSTED'
      AND sale.order_runtime_status='LEGACY_POSTED'
  ) THEN 'PAYMENT_CLEARING' ELSE p_original END
$$;

CREATE FUNCTION private.trg_capture_direct_retail_non_cash_payment_requests()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.sales_origin='POS'
    AND NEW.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND NEW.document_status='POSTED'
    AND NEW.order_runtime_status='LEGACY_POSTED'
    AND (OLD.document_status,OLD.order_runtime_status)
      IS DISTINCT FROM (NEW.document_status,NEW.order_runtime_status) THEN
    PERFORM private.capture_direct_retail_non_cash_payment_requests(
      NEW.company_id,NEW.id,COALESCE(auth.uid(),NEW.created_by));
  END IF;
  RETURN NULL;
END
$$;

CREATE TRIGGER capture_direct_retail_non_cash_payment_requests
AFTER UPDATE OF document_status,order_runtime_status ON public.sales_headers
FOR EACH ROW EXECUTE FUNCTION
  private.trg_capture_direct_retail_non_cash_payment_requests();

DO $patch_sale_posting$
DECLARE
  v_definition text;
  v_pattern text:='payment\.settlement_account_function_snapshot[[:space:]]+(AS[[:space:]]+)?function_key';
  v_replacement text:='private.resolve_direct_retail_sale_payment_function(p_company_id, payment.sales_id, payment.client_payment_key, payment.settlement_account_function_snapshot) AS function_key';
  v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_definition:=replace(v_definition,chr(13),'');
  SELECT count(*) INTO v_count FROM regexp_matches(v_definition,v_pattern,'g');
  IF v_count<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sale settlement anchor drift (%)',v_count;
  END IF;
  EXECUTE regexp_replace(v_definition,v_pattern,v_replacement,'g');
END
$patch_sale_posting$;

CREATE OR REPLACE FUNCTION public.review_sales_payment_verification(
  p_request_id uuid,p_master_version bigint,p_action text,p_note text,
  p_idempotency_key uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_action text:=upper(btrim(coalesce(p_action,'')));
  v_request public.sales_payment_verification_requests%rowtype;
  v_sale public.sales_headers%rowtype;v_event uuid:=gen_random_uuid();
  v_category uuid;v_category_count bigint;v_timing text;v_target text;
  v_timezone text;v_effective date;v_now timestamptz:=clock_timestamp();
  v_before jsonb;v_after jsonb;v_expected numeric(24,4);v_reversal uuid;
  v_posting jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF v_action NOT IN ('VERIFY','REJECT') THEN RAISE EXCEPTION 'INVALID_REVIEW_ACTION'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,
    'finance.sales_payment_verification',
    CASE WHEN v_action='VERIFY' THEN 'APPROVE' ELSE 'REVIEW' END);
  SELECT request.* INTO v_request
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=v_company AND request.id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.sales_payment_verification_audit audit
    WHERE audit.company_id=v_company AND audit.verification_request_id=p_request_id
      AND audit.action=v_action AND audit.idempotency_key=p_idempotency_key) THEN
    IF v_action='VERIFY' AND v_request.status='VERIFIED'
      AND v_request.financial_event_id IS NOT NULL THEN
      v_posting:=private.post_financial_event_core(
        v_company,v_request.financial_event_id,1,v_actor);
    END IF;
    RETURN jsonb_build_object('requestId',v_request.id,'status',v_request.status,
      'masterVersion',v_request.master_version,
      'financialEventId',v_request.financial_event_id,
      'posting',v_posting,'exactRetry',true);
  END IF;
  IF v_request.status<>'PENDING' THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_FINAL'; END IF;
  IF v_request.master_version<>p_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_request.requested_by=v_actor THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_request.sales_id FOR SHARE;
  v_before:=to_jsonb(v_request);
  IF v_action='REJECT' THEN
    IF v_request.settlement_route_snapshot='CASH_DRAWER' THEN
      IF NOT EXISTS (SELECT 1 FROM public.cashier_sessions session
        WHERE session.company_id=v_company AND session.id=v_request.cashier_session_id
          AND session.status='OPEN'::public.session_status) THEN
        RAISE EXCEPTION 'CASH_PAYMENT_REJECTION_REQUIRES_OPEN_SESSION';
      END IF;
      v_expected:=private.calculate_cashier_session_expected_cash(
        v_company,v_request.cashier_session_id)-v_request.amount;
      INSERT INTO public.cash_drawer_movements(company_id,store_id,pos_terminal_id,
        cashier_session_id,direction,movement_type,amount,source_table,source_id,
        expected_cash_after,actor_id)
      VALUES(v_company,v_request.store_id,v_request.pos_terminal_id,
        v_request.cashier_session_id,'OUT','REVERSAL',v_request.amount,
        'sales_payment_verification_reversal',v_request.id,v_expected,v_actor)
      RETURNING id INTO v_reversal;
    END IF;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','1',true);
    UPDATE public.sales_payment_verification_requests SET status='REJECTED',
      reviewed_by=v_actor,reviewed_at=v_now,review_note=nullif(btrim(p_note),''),
      cash_drawer_reversal_movement_id=v_reversal,master_version=master_version+1,
      updated_at=v_now WHERE company_id=v_company AND id=v_request.id
    RETURNING * INTO v_request;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','',true);
  ELSE
    SELECT coalesce(company.timezone,'Asia/Jakarta') INTO v_timezone
    FROM public.companies company WHERE company.id=v_company;
    v_effective:=(v_now AT TIME ZONE v_timezone)::date;
    IF (v_sale.sales_origin='POS'
        AND v_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
        AND v_sale.document_status='POSTED'
        AND v_sale.order_runtime_status='LEGACY_POSTED')
      OR EXISTS (SELECT 1 FROM public.sales_dispatch_financial_effects effect
        WHERE effect.company_id=v_company AND effect.sales_id=v_sale.id) THEN
      v_timing:='POST_DISPATCH';
      v_target:=CASE
        WHEN v_sale.sales_origin='POS'
          AND v_sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
          AND v_sale.document_status='POSTED'
          AND v_sale.order_runtime_status='LEGACY_POSTED'
        THEN 'PAYMENT_CLEARING'
        WHEN v_sale.is_tempo THEN 'CUSTOMER_RECEIVABLE'
        ELSE 'PAYMENT_CLEARING' END;
    ELSE
      v_timing:='PRE_DISPATCH';v_target:='CUSTOMER_ADVANCE';
    END IF;
    SELECT count(*),(array_agg(category.id ORDER BY category.id))[1]
    INTO v_category_count,v_category FROM public.transaction_categories category
    WHERE category.company_id=v_company
      AND category.system_key='SALE_PAYMENT_VERIFIED' AND category.is_active;
    IF v_category_count<>1 OR v_category IS NULL THEN
      RAISE EXCEPTION 'PAYMENT_TRANSACTION_CATEGORY_MISSING_OR_AMBIGUOUS';
    END IF;
    INSERT INTO public.financial_events(id,event_code,event_type,source_table,
      source_id,root_sales_id,event_date,event_version,idempotency_key,
      payment_method,amounts,status,created_by,company_id,store_id,
      system_event_key,transaction_category_id,transaction_rule_version)
    VALUES(v_event,'ODR-PAY-'||upper(replace(v_request.id::text,'-','')),
      'PAYMENT_RECEIVED'::public.event_type,'sales_payment_verification_requests',
      v_request.id,v_sale.id,v_now,1,
      'ODR_PAYMENT_VERIFY|'||v_company||'|'||v_request.id,
      v_request.payment_method_type_snapshot,jsonb_build_object(
        'settlementAmount',v_request.amount,'sourceAccountFunction',
        v_request.settlement_account_function_snapshot,'settlementTarget',v_target,
        'receiptTiming',v_timing),'HOLD'::public.event_status,v_actor,v_company,
      v_request.store_id,'SALE_PAYMENT_VERIFIED',v_category,1);
    PERFORM set_config('kgs.odr5_payment_verification_mutation','1',true);
    UPDATE public.sales_payment_verification_requests SET status='VERIFIED',
      receipt_timing=v_timing,settlement_target=v_target,effective_date=v_effective,
      financial_event_id=v_event,reviewed_by=v_actor,reviewed_at=v_now,
      review_note=nullif(btrim(p_note),''),master_version=master_version+1,
      updated_at=v_now WHERE company_id=v_company AND id=v_request.id
    RETURNING * INTO v_request;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','',true);
  END IF;
  v_after:=to_jsonb(v_request);
  INSERT INTO public.sales_payment_verification_audit(company_id,
    verification_request_id,action,actor_id,idempotency_key,before_state,after_state)
  VALUES(v_company,v_request.id,v_action,v_actor,p_idempotency_key,v_before,v_after);
  IF v_action='VERIFY' THEN
    v_posting:=private.post_financial_event_core(
      v_company,v_request.financial_event_id,1,v_actor);
  END IF;
  RETURN jsonb_build_object('requestId',v_request.id,'status',v_request.status,
    'receiptTiming',v_request.receipt_timing,
    'settlementTarget',v_request.settlement_target,
    'financialEventId',v_request.financial_event_id,'posting',v_posting,
    'masterVersion',v_request.master_version,'exactRetry',false);
END
$$;

DO $backfill$
DECLARE v_sale record;
BEGIN
  FOR v_sale IN
    SELECT DISTINCT sale.company_id,sale.id,sale.created_by
    FROM public.sales_headers sale
    JOIN public.sales_payments payment
      ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
     AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
    JOIN public.financial_events event
      ON event.company_id=sale.company_id AND event.source_table='sales_headers'
     AND event.source_id=sale.id AND event.system_event_key='SALE_POSTED'
     AND event.status='HOLD'
    WHERE sale.sales_origin='POS'
      AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
      AND sale.document_status='POSTED'
      AND sale.order_runtime_status='LEGACY_POSTED'
      AND NOT EXISTS (SELECT 1 FROM public.finance_journals journal
        WHERE journal.company_id=event.company_id
          AND journal.financial_event_id=event.id)
      AND NOT EXISTS (SELECT 1
        FROM public.sales_payment_verification_requests request
        WHERE request.company_id=payment.company_id
          AND request.sales_id=payment.sales_id
          AND request.client_payment_key=payment.client_payment_key)
    ORDER BY sale.company_id,sale.id
  LOOP
    PERFORM private.capture_direct_retail_non_cash_payment_requests(
      v_sale.company_id,v_sale.id,v_sale.created_by);
  END LOOP;
END
$backfill$;

DO $verify$
DECLARE v_invalid bigint;v_definition text;
BEGIN
  SELECT count(*) INTO v_invalid
  FROM public.sales_headers sale
  JOIN public.sales_payments payment
    ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
   AND payment.settlement_route_snapshot IN ('DIRECT_BANK','CLEARING')
  JOIN public.financial_events event
    ON event.company_id=sale.company_id AND event.source_table='sales_headers'
   AND event.source_id=sale.id AND event.system_event_key='SALE_POSTED'
   AND event.status='HOLD'
  LEFT JOIN public.sales_payment_verification_requests request
    ON request.company_id=payment.company_id AND request.sales_id=payment.sales_id
   AND request.client_payment_key=payment.client_payment_key
  WHERE sale.sales_origin='POS'
    AND sale.sales_process_mode='RETAIL_CONFIRM_INVOICE'
    AND sale.document_status='POSTED'
    AND sale.order_runtime_status='LEGACY_POSTED'
    AND NOT EXISTS (SELECT 1 FROM public.finance_journals journal
      WHERE journal.company_id=event.company_id AND journal.financial_event_id=event.id)
    AND request.id IS NULL;
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: safe backlog not captured (%)',v_invalid;
  END IF;
  SELECT pg_get_functiondef(
    'private.post_sale_return_financial_event_core(uuid,uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'resolve_direct_retail_sale_payment_function' THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: Sale settlement ownership patch';
  END IF;
  SELECT pg_get_functiondef(
    'public.review_sales_payment_verification(uuid,bigint,text,text,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'private.post_financial_event_core'
    OR v_definition!~'RETAIL_CONFIRM_INVOICE' THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: atomic verification runtime';
  END IF;
END
$verify$;

REVOKE ALL ON FUNCTION
  private.capture_direct_retail_non_cash_payment_requests(uuid,uuid,uuid),
  private.resolve_direct_retail_sale_payment_function(uuid,uuid,uuid,text),
  private.trg_capture_direct_retail_non_cash_payment_requests()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.capture_direct_retail_non_cash_payment_requests(uuid,uuid,uuid),
  private.resolve_direct_retail_sale_payment_function(uuid,uuid,uuid,text),
  private.trg_capture_direct_retail_non_cash_payment_requests()
TO service_role;
REVOKE ALL ON FUNCTION
  public.review_sales_payment_verification(uuid,bigint,text,text,uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.review_sales_payment_verification(uuid,bigint,text,text,uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261031100000','pos_retail_non_cash_atomic_verification',
  'Capture direct Retail POS DIRECT_BANK/CLEARING payment requests, route Sale settlement through PAYMENT_CLEARING, and atomically post SALE_PAYMENT_VERIFIED during Finance approval; preserve Cash, Customer Receipt Tempo, Backoffice, Stock/FIFO and immutable legacy Posted Journals');

NOTIFY pgrst,'reload schema';
COMMIT;
