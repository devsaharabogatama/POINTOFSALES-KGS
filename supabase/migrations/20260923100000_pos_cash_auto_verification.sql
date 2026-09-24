BEGIN;

DO $guard$
DECLARE v_missing text[];v_invalid bigint;v_body text;v_composition text;
BEGIN
  SELECT array_agg(version ORDER BY version) INTO v_missing
  FROM (VALUES ('20260828240000'),('20260829130000'),('20260830120000'),
    ('20260903120000'),('20260907100000')) required(version)
  WHERE NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations ledger
    WHERE ledger.version=required.version);
  IF coalesce(cardinality(v_missing),0)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: missing dependencies %',v_missing;
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260923100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260923100000';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='sales_payment_verification_requests'
    AND column_name='verification_mode') OR
    to_regprocedure('private.auto_verify_pos_cash_payment_request(uuid,uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: object collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF to_regprocedure(
      'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)') IS NULL
    OR to_regprocedure('public.confirm_pos_sales_order(uuid,bigint,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Retail confirm chain missing';
  END IF;
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_body;
  SELECT pg_get_functiondef(
    'private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_composition;
  IF v_body!~'private.confirm_pos_sales_order_before_revision_core'
    OR v_body!~'sales_order_revisions'
    OR v_composition!~'private.confirm_pos_sales_order_core'
    OR v_composition!~'ensure_confirmed_order_invoice_identity'
    OR v_composition!~'ensure_confirmed_order_documents'
    OR v_composition!~'refresh_sales_order_procurement_demand'
    OR v_composition!~'capture_sales_order_payment_requests' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Retail confirm chain drift';
  END IF;
  SELECT pg_get_functiondef(
    'private.capture_sales_order_payment_requests(uuid,uuid,uuid)'::regprocedure)
  INTO v_body;
  IF v_body!~'SALE_PAYMENT_INTENT' OR v_body!~'IDEMPOTENCY_PAYLOAD_CONFLICT' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: payment capture anchor drift';
  END IF;
  SELECT pg_get_functiondef(
    'private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)'::regprocedure)
  INTO v_body;
  IF v_body!~'SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION'
    OR v_body!~'SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: cancellation anchor drift';
  END IF;
  SELECT pg_get_functiondef('public.get_sales_documents()'::regprocedure)
  INTO v_body;
  IF v_body!~'resolve_sales_invoice_display_date'
    OR v_body!~'session.cashier_id=v_actor' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales document list anchor drift';
  END IF;
  SELECT pg_get_functiondef(
    'public.get_sales_invoice_document(uuid)'::regprocedure) INTO v_body;
  IF v_body!~'resolve_sales_invoice_display_date'
    OR v_body!~'session.cashier_id=v_actor' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales document detail anchor drift';
  END IF;
  SELECT pg_get_functiondef(
    'public.get_finance_sales_payment_verifications()'::regprocedure) INTO v_body;
  IF v_body!~'finance.sales_payment_verification'
    OR v_body!~'effectiveCapabilities' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Finance verification read anchor drift';
  END IF;
  SELECT count(*) INTO v_invalid
  FROM public.sales_payment_verification_requests request
  LEFT JOIN public.sales_headers sale ON sale.company_id=request.company_id
    AND sale.id=request.sales_id
  LEFT JOIN public.cash_drawer_movements movement
    ON movement.company_id=request.company_id AND movement.id=request.cash_drawer_movement_id
  LEFT JOIN public.cashier_sessions session ON session.company_id=request.company_id
    AND session.id=request.cashier_session_id
  WHERE request.status='PENDING' AND request.settlement_route_snapshot='CASH_DRAWER'
    AND (sale.id IS NULL OR sale.order_runtime_status='CANCELED'
      OR request.cash_drawer_reversal_movement_id IS NOT NULL
      OR request.settlement_account_function_snapshot<>'CASH_DRAWER'
      OR movement.id IS NULL OR session.id IS NULL
      OR movement.cashier_session_id<>request.cashier_session_id
      OR movement.store_id<>request.store_id
      OR movement.pos_terminal_id IS DISTINCT FROM request.pos_terminal_id
      OR movement.amount<>request.amount OR movement.direction<>'IN'
      OR movement.movement_type<>'SALE_PAYMENT_INTENT'
      OR movement.source_table<>'sales_payment_verification_requests'
      OR movement.source_id<>request.id);
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: % ambiguous pending Cash requests',v_invalid;
  END IF;
  SELECT count(*) INTO v_invalid FROM (
    SELECT request.company_id
    FROM public.sales_payment_verification_requests request
    LEFT JOIN public.transaction_categories category
      ON category.company_id=request.company_id
     AND category.system_key='SALE_PAYMENT_VERIFIED' AND category.is_active
    WHERE request.status='PENDING' AND request.settlement_route_snapshot='CASH_DRAWER'
    GROUP BY request.company_id HAVING count(DISTINCT category.id)<>1
  ) invalid_company;
  IF v_invalid<>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Cash category missing or ambiguous for % Companies',v_invalid;
  END IF;
END
$guard$;

ALTER TABLE public.sales_payment_verification_requests
  ADD COLUMN verification_mode text NOT NULL DEFAULT 'MANUAL_REVIEW';
ALTER TABLE public.sales_payment_verification_requests
  ADD CONSTRAINT sales_payment_verification_mode_check CHECK(
    verification_mode IN('MANUAL_REVIEW','AUTO_CASH')),
  ADD CONSTRAINT sales_payment_verification_auto_cash_check CHECK(
    verification_mode<>'AUTO_CASH' OR settlement_route_snapshot='CASH_DRAWER');

ALTER TABLE public.sales_payment_verification_audit
  DROP CONSTRAINT sales_payment_verification_audit_action_check;
ALTER TABLE public.sales_payment_verification_audit
  ADD CONSTRAINT sales_payment_verification_audit_action_check CHECK(
    action IN('CREATE','VERIFY','AUTO_VERIFY_CASH','REJECT','CANCEL','POST','ERROR'));

CREATE OR REPLACE FUNCTION private.trg_odr5_guard_payment_verification()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_IMMUTABLE'; END IF;
  IF TG_OP='UPDATE' AND coalesce(current_setting(
    'kgs.odr5_payment_verification_mutation',true),'')<>'1' THEN
    RAISE EXCEPTION 'PAYMENT_VERIFICATION_GUARDED_MUTATION_REQUIRED';
  END IF;
  IF TG_OP='UPDATE' AND (NEW.company_id,NEW.sales_id,NEW.client_payment_key,
    NEW.payment_method_id,NEW.amount,NEW.intent_snapshot) IS DISTINCT FROM
    (OLD.company_id,OLD.sales_id,OLD.client_payment_key,
      OLD.payment_method_id,OLD.amount,OLD.intent_snapshot) THEN
    RAISE EXCEPTION 'PAYMENT_VERIFICATION_SOURCE_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND OLD.verification_mode='AUTO_CASH'
    AND NEW.verification_mode<>'AUTO_CASH' THEN
    RAISE EXCEPTION 'PAYMENT_VERIFICATION_MODE_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND OLD.status='PENDING'
    AND OLD.settlement_route_snapshot='CASH_DRAWER'
    AND NEW.status='VERIFIED' AND NEW.verification_mode<>'AUTO_CASH' THEN
    RAISE EXCEPTION 'POS_CASH_MANUAL_VERIFICATION_FORBIDDEN';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.auto_verify_pos_cash_payment_request(
  p_company_id uuid,p_request_id uuid,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_request public.sales_payment_verification_requests%rowtype;
  v_sale public.sales_headers%rowtype;v_event uuid:=gen_random_uuid();
  v_category uuid;v_category_count bigint;v_timing text;v_target text;
  v_timezone text;v_effective date;v_now timestamptz:=clock_timestamp();
  v_before jsonb;v_movement public.cash_drawer_movements%rowtype;
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT request.* INTO v_request
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=p_company_id AND request.id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_NOT_FOUND'; END IF;
  IF v_request.status='VERIFIED' AND v_request.verification_mode='AUTO_CASH' THEN
    RETURN jsonb_build_object('requestId',v_request.id,'status','VERIFIED',
      'financialEventId',v_request.financial_event_id,'masterVersion',v_request.master_version,
      'exactRetry',true);
  END IF;
  IF v_request.status<>'PENDING' THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_FINAL'; END IF;
  IF v_request.settlement_route_snapshot<>'CASH_DRAWER'
    OR v_request.settlement_account_function_snapshot<>'CASH_DRAWER'
    OR v_request.cash_drawer_movement_id IS NULL
    OR v_request.cash_drawer_reversal_movement_id IS NOT NULL THEN
    RAISE EXCEPTION 'CASH_AUTO_VERIFICATION_SOURCE_INVALID';
  END IF;
  SELECT movement.* INTO v_movement FROM public.cash_drawer_movements movement
  WHERE movement.company_id=p_company_id AND movement.id=v_request.cash_drawer_movement_id
    AND movement.cashier_session_id=v_request.cashier_session_id
    AND movement.store_id=v_request.store_id
    AND movement.pos_terminal_id IS NOT DISTINCT FROM v_request.pos_terminal_id
    AND movement.direction='IN' AND movement.movement_type='SALE_PAYMENT_INTENT'
    AND movement.source_table='sales_payment_verification_requests'
    AND movement.source_id=v_request.id AND movement.amount=v_request.amount FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'CASH_AUTO_VERIFICATION_DRAWER_MISMATCH'; END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=v_request.sales_id FOR SHARE;
  IF NOT FOUND OR v_sale.order_runtime_status='CANCELED' THEN
    RAISE EXCEPTION 'CASH_AUTO_VERIFICATION_SALE_INVALID';
  END IF;
  SELECT coalesce(company.timezone,'Asia/Jakarta') INTO v_timezone
  FROM public.companies company WHERE company.id=p_company_id;
  v_effective:=(v_now AT TIME ZONE v_timezone)::date;
  IF EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects effect
    WHERE effect.company_id=p_company_id AND effect.sales_id=v_sale.id) THEN
    v_timing:='POST_DISPATCH';
    v_target:=CASE WHEN v_sale.is_tempo THEN 'CUSTOMER_RECEIVABLE'
      ELSE 'PAYMENT_CLEARING' END;
  ELSE
    v_timing:='PRE_DISPATCH';v_target:='CUSTOMER_ADVANCE';
  END IF;
  SELECT count(*),(array_agg(category.id ORDER BY category.id))[1]
  INTO v_category_count,v_category FROM public.transaction_categories category
  WHERE category.company_id=p_company_id
    AND category.system_key='SALE_PAYMENT_VERIFIED' AND category.is_active;
  IF v_category_count<>1 OR v_category IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_TRANSACTION_CATEGORY_MISSING_OR_AMBIGUOUS';
  END IF;
  v_before:=to_jsonb(v_request);
  INSERT INTO public.financial_events(id,event_code,event_type,source_table,
    source_id,root_sales_id,event_date,event_version,idempotency_key,
    payment_method,amounts,status,created_by,company_id,store_id,
    system_event_key,transaction_category_id,transaction_rule_version)
  VALUES(v_event,'ODR-CASH-'||upper(replace(v_request.id::text,'-','')),
    'PAYMENT_RECEIVED'::public.event_type,'sales_payment_verification_requests',
    v_request.id,v_sale.id,v_now,1,
    'ODR_PAYMENT_AUTO_CASH|'||p_company_id||'|'||v_request.id,
    v_request.payment_method_type_snapshot,jsonb_build_object(
      'settlementAmount',v_request.amount,'sourceAccountFunction','CASH_DRAWER',
      'settlementTarget',v_target,'receiptTiming',v_timing,
      'verificationMode','AUTO_CASH'),'HOLD'::public.event_status,p_actor_id,
    p_company_id,v_request.store_id,'SALE_PAYMENT_VERIFIED',v_category,1);
  PERFORM set_config('kgs.odr5_payment_verification_mutation','1',true);
  UPDATE public.sales_payment_verification_requests SET status='VERIFIED',
    verification_mode='AUTO_CASH',receipt_timing=v_timing,
    settlement_target=v_target,effective_date=v_effective,financial_event_id=v_event,
    reviewed_by=p_actor_id,reviewed_at=v_now,
    review_note='Tunai diterima Kasir dan diverifikasi otomatis oleh sistem.',
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=p_company_id AND id=v_request.id RETURNING * INTO v_request;
  PERFORM set_config('kgs.odr5_payment_verification_mutation','',true);
  INSERT INTO public.sales_payment_verification_audit(company_id,
    verification_request_id,action,actor_id,idempotency_key,before_state,after_state)
  VALUES(p_company_id,v_request.id,'AUTO_VERIFY_CASH',p_actor_id,v_request.client_payment_key,
    v_before,to_jsonb(v_request));
  RETURN jsonb_build_object('requestId',v_request.id,'status','VERIFIED',
    'receiptTiming',v_timing,'settlementTarget',v_target,
    'financialEventId',v_event,'masterVersion',v_request.master_version,
    'exactRetry',false);
END
$$;

CREATE OR REPLACE FUNCTION private.capture_sales_order_payment_requests(
  p_company_id uuid,p_sales_id uuid,p_actor_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%rowtype;v_session public.cashier_sessions%rowtype;
  v_method public.payment_methods%rowtype;v_payment jsonb;v_request_id uuid;
  v_client_key uuid;v_base numeric(24,4);v_tendered numeric(24,4);
  v_fee numeric(24,4);v_surcharge numeric(24,4);v_amount numeric(24,4);
  v_base_total numeric(24,4):=0;v_count integer:=0;v_created integer:=0;
  v_auto integer:=0;v_proof text;v_function text;v_expected numeric(24,4);
  v_movement uuid;v_snapshot jsonb;
  v_existing public.sales_payment_verification_requests%rowtype;
BEGIN
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND OR v_sale.order_runtime_status NOT IN('CONFIRMED','RESERVED') THEN
    RAISE EXCEPTION 'CONFIRMED_SALES_ORDER_REQUIRED';
  END IF;
  SELECT session.* INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=p_company_id AND session.id=v_sale.session_id FOR UPDATE;
  IF NOT FOUND OR v_session.store_id<>v_sale.store_id THEN
    RAISE EXCEPTION 'SALES_ORDER_SESSION_SCOPE_MISMATCH';
  END IF;
  FOR v_payment IN SELECT value FROM jsonb_array_elements(
    coalesce(v_sale.payload_snapshot->'payments','[]'::jsonb)) LOOP
    BEGIN
      v_client_key:=(v_payment->>'clientPaymentKey')::uuid;
      v_base:=round((v_payment->>'amount')::numeric,4);
      v_tendered:=round(coalesce((v_payment->>'tenderedAmount')::numeric,v_base),4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_PAYMENT_INTENT'; END;
    IF v_client_key IS NULL OR v_base<=0 OR v_tendered<v_base THEN
      RAISE EXCEPTION 'INVALID_PAYMENT_AMOUNT';
    END IF;
    SELECT method.* INTO v_method FROM public.payment_methods method
    WHERE method.company_id=p_company_id
      AND method.id=(v_payment->>'paymentMethodId')::uuid
      AND method.is_active AND method.effective_from<=clock_timestamp()
      AND (method.effective_to IS NULL OR method.effective_to>=clock_timestamp())
      AND (method.available_all_stores OR EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=method.company_id
          AND assignment.payment_method_id=method.id AND assignment.store_id=v_sale.store_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'ELIGIBLE_PAYMENT_METHOD_REQUIRED'; END IF;
    IF v_method.settlement_route='INTERNAL_LIABILITY'
      OR v_method.method_type IN('CUSTOMER_BALANCE','KETUL_OFFSET') THEN
      RAISE EXCEPTION 'ODR_INTERNAL_LIABILITY_PAYMENT_NOT_SUPPORTED';
    END IF;
    IF v_method.method_type='TEMPO' THEN
      RAISE EXCEPTION 'TEMPO_IS_DOCUMENT_MODE_NOT_PAYMENT_LEG';
    END IF;
    v_proof:=nullif(btrim(v_payment->>'proofUrl'),'');
    IF v_method.proof_mode='REQUIRED' AND v_proof IS NULL THEN
      RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED';
    END IF;
    IF v_proof IS NOT NULL AND v_proof!~*'^https://' THEN
      RAISE EXCEPTION 'PAYMENT_PROOF_HTTPS_REQUIRED';
    END IF;
    v_function:=private.odr5d_settlement_account_function(v_method);
    IF v_function IS NULL THEN RAISE EXCEPTION 'PAYMENT_ACCOUNT_FUNCTION_REQUIRED'; END IF;
    v_fee:=CASE WHEN NOT v_method.fee_enabled THEN 0
      WHEN v_method.fee_type='PERCENT' THEN round(v_base*v_method.fee_percent/100,4)
      WHEN v_method.fee_type='FIXED' THEN v_method.fee_fixed_amount
      ELSE round(v_base*v_method.fee_percent/100+v_method.fee_fixed_amount,4) END;
    v_surcharge:=CASE WHEN v_method.fee_bearer='CUSTOMER' THEN v_fee ELSE 0 END;
    v_amount:=v_base+v_surcharge;v_base_total:=v_base_total+v_base;v_count:=v_count+1;
    v_snapshot:=jsonb_build_object('snapshotVersion',1,'sourceContract',
      'ODR_CONFIRMED_ORDER_PAYMENT_INTENT','clientPaymentKey',v_client_key,
      'baseAmount',v_base,'configuredFeeAmount',v_fee,
      'customerSurchargeAmount',v_surcharge,'settlementAmount',v_amount,
      'tenderedAmount',v_tendered+v_surcharge,'changeAmount',v_tendered-v_base,
      'proofMode',v_method.proof_mode,'feeBearer',v_method.fee_bearer,
      'feeType',v_method.fee_type,'feePercent',v_method.fee_percent,
      'feeFixedAmount',v_method.fee_fixed_amount,'storeId',v_sale.store_id,
      'cashierSessionId',v_session.id,'posTerminalId',v_session.pos_id);
    SELECT request.* INTO v_existing
    FROM public.sales_payment_verification_requests request
    WHERE request.company_id=p_company_id AND request.sales_id=p_sales_id
      AND request.client_payment_key=v_client_key;
    IF FOUND THEN
      IF v_existing.payment_method_id<>v_method.id OR v_existing.amount<>v_amount
        OR v_existing.intent_snapshot<>v_snapshot THEN
        RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
      END IF;
      IF v_method.settlement_route='CASH_DRAWER' AND v_existing.status='PENDING' THEN
        PERFORM private.auto_verify_pos_cash_payment_request(
          p_company_id,v_existing.id,p_actor_id);v_auto:=v_auto+1;
      END IF;
      CONTINUE;
    END IF;
    v_request_id:=gen_random_uuid();v_movement:=NULL;
    IF v_method.settlement_route='CASH_DRAWER' THEN
      v_expected:=private.calculate_cashier_session_expected_cash(
        p_company_id,v_session.id)+v_amount;
      INSERT INTO public.cash_drawer_movements(id,company_id,store_id,
        pos_terminal_id,cashier_session_id,direction,movement_type,amount,
        source_table,source_id,expected_cash_after,actor_id)
      VALUES(gen_random_uuid(),p_company_id,v_sale.store_id,v_session.pos_id,
        v_session.id,'IN','SALE_PAYMENT_INTENT',v_amount,
        'sales_payment_verification_requests',v_request_id,v_expected,p_actor_id)
      RETURNING id INTO v_movement;
    END IF;
    INSERT INTO public.sales_payment_verification_requests(id,company_id,sales_id,
      client_payment_key,payment_method_id,amount,proof_url,status,
      payment_method_code_snapshot,payment_method_name_snapshot,
      payment_method_type_snapshot,settlement_route_snapshot,
      settlement_account_function_snapshot,intent_snapshot,requested_by,
      cashier_session_id,store_id,pos_terminal_id,cash_drawer_movement_id)
    VALUES(v_request_id,p_company_id,p_sales_id,v_client_key,v_method.id,v_amount,
      v_proof,'PENDING',v_method.payment_method_code,v_method.payment_method_name,
      v_method.method_type,v_method.settlement_route,v_function,v_snapshot,
      p_actor_id,v_session.id,v_sale.store_id,v_session.pos_id,v_movement);
    INSERT INTO public.sales_payment_verification_audit(company_id,
      verification_request_id,action,actor_id,idempotency_key,after_state)
    VALUES(p_company_id,v_request_id,'CREATE',p_actor_id,v_client_key,
      jsonb_build_object('status','PENDING','amount',v_amount,
        'paymentMethodId',v_method.id,'cashDrawerMovementId',v_movement));
    IF v_method.settlement_route='CASH_DRAWER' THEN
      PERFORM private.auto_verify_pos_cash_payment_request(
        p_company_id,v_request_id,p_actor_id);v_auto:=v_auto+1;
    END IF;
    v_created:=v_created+1;
  END LOOP;
  IF NOT v_sale.is_tempo AND (v_count=0 OR v_base_total<>v_sale.grand_total_after_rounding) THEN
    RAISE EXCEPTION 'PAYMENT_TOTAL_MISMATCH';
  END IF;
  IF v_sale.is_tempo AND v_base_total>v_sale.grand_total_after_rounding THEN
    RAISE EXCEPTION 'PAYMENT_TOTAL_EXCEEDS_RECEIVABLE';
  END IF;
  RETURN jsonb_build_object('requestCount',v_count,'createdCount',v_created,
    'autoVerifiedCashCount',v_auto,'paymentBaseTotal',v_base_total,
    'exactRetry',v_created=0);
END
$$;

CREATE OR REPLACE FUNCTION public.get_finance_sales_payment_verifications()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_permission jsonb;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.sales_payment_verification','VIEW');
  RETURN jsonb_build_object('companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',coalesce(v_permission->'effectiveCapabilities','[]'::jsonb),
    'requests',(SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id',request.id,'salesId',request.sales_id,'invoiceNo',sale.invoice_no,
      'customerId',sale.customer_id,'customerCode',customer.code,
      'customerName',customer.name,'storeId',request.store_id,
      'storeName',store.store_name,'cashierSessionId',request.cashier_session_id,
      'paymentMethodName',request.payment_method_name_snapshot,
      'paymentMethodType',request.payment_method_type_snapshot,
      'settlementRoute',request.settlement_route_snapshot,'amount',request.amount,
      'proofUrl',request.proof_url,'status',request.status,
      'receiptTiming',request.receipt_timing,'settlementTarget',request.settlement_target,
      'requestedBy',request.requested_by,'requestedByName',maker.name,
      'requestedAt',request.requested_at,'reviewedBy',request.reviewed_by,
      'reviewedByName',reviewer.name,'reviewedAt',request.reviewed_at,
      'reviewNote',request.review_note,'effectiveDate',request.effective_date,
      'financialEventId',request.financial_event_id,'masterVersion',request.master_version,
      'intentSnapshot',request.intent_snapshot)
      ORDER BY request.requested_at DESC,request.id DESC),'[]'::jsonb)
      FROM public.sales_payment_verification_requests request
      JOIN public.sales_headers sale ON sale.company_id=request.company_id
        AND sale.id=request.sales_id
      JOIN public.customers customer ON customer.company_id=sale.company_id
        AND customer.id=sale.customer_id
      JOIN public.stores store ON store.company_id=request.company_id
        AND store.id=request.store_id
      LEFT JOIN public.profiles maker ON maker.id=request.requested_by
      LEFT JOIN public.profiles reviewer ON reviewer.id=request.reviewed_by
      WHERE request.company_id=v_company
        AND request.settlement_route_snapshot<>'CASH_DRAWER'));
END
$$;

CREATE FUNCTION private.sales_payment_blocks_order_cancel(
  p_company_id uuid,p_sales_id uuid,p_actor_id uuid
) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.sales_payment_verification_requests request
    LEFT JOIN public.financial_events event ON event.company_id=request.company_id
      AND event.id=request.financial_event_id
    WHERE request.company_id=p_company_id AND request.sales_id=p_sales_id AND (
      (request.status='VERIFIED' AND NOT(
        request.verification_mode='AUTO_CASH'
        AND request.settlement_route_snapshot='CASH_DRAWER'
        AND event.status='HOLD'::public.event_status
        AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
          WHERE journal.company_id=request.company_id
            AND journal.financial_event_id=request.financial_event_id)
        AND EXISTS(SELECT 1 FROM public.cashier_sessions session
          WHERE session.company_id=request.company_id
            AND session.status='OPEN'::public.session_status
            AND (session.id=request.cashier_session_id OR
              (session.cashier_id=p_actor_id AND session.store_id=request.store_id)))))
      OR (request.status='PENDING' AND request.settlement_route_snapshot='CASH_DRAWER'
        AND NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
          WHERE session.company_id=request.company_id
            AND session.status='OPEN'::public.session_status
            AND (session.id=request.cashier_session_id OR
              (session.cashier_id=p_actor_id AND session.store_id=request.store_id))))))
$$;

CREATE OR REPLACE FUNCTION private.cancel_pending_sales_order_payments(
  p_company_id uuid,p_sales_id uuid,p_actor_id uuid,
  p_idempotency_key uuid,p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_request public.sales_payment_verification_requests%rowtype;
  v_source_session public.cashier_sessions%rowtype;
  v_refund_session public.cashier_sessions%rowtype;v_event public.financial_events%rowtype;
  v_reversal uuid;v_expected numeric(24,4);v_before jsonb;v_after jsonb;
  v_count bigint:=0;v_cash_count bigint:=0;v_current_session_count bigint:=0;
  v_canceled_events bigint:=0;v_now timestamptz:=clock_timestamp();
BEGIN
  IF p_actor_id IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    LEFT JOIN public.financial_events event ON event.company_id=request.company_id
      AND event.id=request.financial_event_id
    WHERE request.company_id=p_company_id AND request.sales_id=p_sales_id
      AND request.status='VERIFIED' AND NOT(
        request.verification_mode='AUTO_CASH'
        AND request.settlement_route_snapshot='CASH_DRAWER'
        AND event.status='HOLD'::public.event_status
        AND NOT EXISTS(SELECT 1 FROM public.finance_journals journal
          WHERE journal.company_id=request.company_id
            AND journal.financial_event_id=request.financial_event_id))) THEN
    RAISE EXCEPTION 'SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED';
  END IF;
  FOR v_request IN SELECT request.*
    FROM public.sales_payment_verification_requests request
    WHERE request.company_id=p_company_id AND request.sales_id=p_sales_id
      AND (request.status='PENDING' OR (request.status='VERIFIED'
        AND request.verification_mode='AUTO_CASH'
        AND request.settlement_route_snapshot='CASH_DRAWER'))
    ORDER BY request.id FOR UPDATE
  LOOP
    v_before:=to_jsonb(v_request);v_reversal:=NULL;
    IF v_request.status='VERIFIED' THEN
      SELECT event.* INTO v_event FROM public.financial_events event
      WHERE event.company_id=p_company_id AND event.id=v_request.financial_event_id
        FOR UPDATE;
      IF NOT FOUND OR v_event.status<>'HOLD'::public.event_status
        OR EXISTS(SELECT 1 FROM public.finance_journals journal
          WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id) THEN
        RAISE EXCEPTION 'SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED';
      END IF;
    END IF;
    IF v_request.settlement_route_snapshot='CASH_DRAWER' THEN
      SELECT session.* INTO v_source_session FROM public.cashier_sessions session
      WHERE session.company_id=p_company_id AND session.id=v_request.cashier_session_id
      FOR SHARE;
      IF NOT FOUND THEN RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND'; END IF;
      IF v_source_session.status='OPEN'::public.session_status THEN
        v_refund_session:=v_source_session;
      ELSE
        SELECT session.* INTO v_refund_session FROM public.cashier_sessions session
        WHERE session.company_id=p_company_id AND session.cashier_id=p_actor_id
          AND session.store_id=v_request.store_id
          AND session.status='OPEN'::public.session_status
        ORDER BY session.opened_at DESC LIMIT 1 FOR SHARE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION';
        END IF;
        v_current_session_count:=v_current_session_count+1;
      END IF;
      SELECT movement.id INTO v_reversal FROM public.cash_drawer_movements movement
      WHERE movement.company_id=p_company_id
        AND movement.source_table='sales_payment_verification_reversal'
        AND movement.source_id=v_request.id;
      IF v_reversal IS NULL THEN
        v_expected:=private.calculate_cashier_session_expected_cash(
          p_company_id,v_refund_session.id)-v_request.amount;
        INSERT INTO public.cash_drawer_movements(company_id,store_id,pos_terminal_id,
          cashier_session_id,direction,movement_type,amount,source_table,source_id,
          expected_cash_after,actor_id)
        VALUES(p_company_id,v_refund_session.store_id,v_refund_session.pos_id,
          v_refund_session.id,'OUT','REVERSAL',v_request.amount,
          'sales_payment_verification_reversal',v_request.id,v_expected,p_actor_id)
        RETURNING id INTO v_reversal;
      END IF;
      v_cash_count:=v_cash_count+1;
    END IF;
    IF v_request.status='VERIFIED' THEN
      UPDATE public.financial_events SET status='CANCELED'::public.event_status,
        event_version=event_version+1,processed_at=v_now,
        error_message='SOURCE_ORDER_CANCELED_BEFORE_DISPATCH'
      WHERE company_id=p_company_id AND id=v_request.financial_event_id;
      v_canceled_events:=v_canceled_events+1;
    END IF;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','1',true);
    UPDATE public.sales_payment_verification_requests SET status='CANCELED',
      reviewed_by=coalesce(reviewed_by,p_actor_id),reviewed_at=coalesce(reviewed_at,v_now),
      review_note='Order dibatalkan: '||btrim(p_reason),
      cash_drawer_reversal_movement_id=v_reversal,
      master_version=master_version+1,updated_at=v_now
    WHERE company_id=p_company_id AND id=v_request.id RETURNING * INTO v_request;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','',true);
    v_after:=to_jsonb(v_request);
    INSERT INTO public.sales_payment_verification_audit(company_id,
      verification_request_id,action,actor_id,idempotency_key,before_state,after_state)
    VALUES(p_company_id,v_request.id,'CANCEL',p_actor_id,p_idempotency_key,
      v_before,v_after);
    v_count:=v_count+1;
  END LOOP;
  RETURN jsonb_build_object('canceledPaymentRequests',v_count,
    'cashDrawerReversals',v_cash_count,'canceledHoldEvents',v_canceled_events,
    'currentSessionCashReversals',v_current_session_count);
END
$$;

CREATE OR REPLACE FUNCTION public.get_sales_documents()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_order_permission jsonb;v_can_cancel boolean;v_timezone text;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company;
  v_order_permission:=private.acp_resolve_permission(
    v_company,v_actor,'sales.sales_orders');
  v_can_cancel:=(v_order_permission->'effectiveCapabilities') ? 'CANCEL_FINAL';
  RETURN jsonb_build_object('companyId',v_company,
    'effectiveOrderCapabilities',coalesce(
      v_order_permission->'effectiveCapabilities','[]'::jsonb),
    'data',coalesce((SELECT jsonb_agg(jsonb_build_object(
      'salesId',invoice.sales_id,'invoiceSnapshotId',invoice.id,
      'invoiceNo',invoice.invoice_no,'snapshotProvenance',invoice.snapshot_provenance,
      'invoiceDate',private.resolve_sales_invoice_display_date(
        invoice.snapshot_payload,to_jsonb(sale),invoice.created_at,v_timezone),
      'postedAt',coalesce(sale.posted_at,sale.confirmed_at,invoice.created_at),
      'total',sale.grand_total_after_rounding,'fulfillmentMode',sale.fulfillment_mode,
      'sourceChannel',sale.source_channel,
      'customerName',coalesce(customer.name,'Walk-In Customer'),
      'storeName',coalesce(store.store_name,'Store'),
      'invoiceStatus',CASE WHEN sale.order_runtime_status='CANCELED'
        OR sale.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END,
      'orderRuntimeStatus',sale.order_runtime_status,
      'masterVersion',sale.master_version,'canceledAt',sale.canceled_at,
      'cancelReason',sale.cancel_reason,'canceledBy',sale.canceled_by,
      'canceledByName',cancel_actor.name,
      'canCancel',v_can_cancel AND sale.document_status='DRAFT'
        AND sale.order_runtime_status IN('CONFIRMED','RESERVED')
        AND reservation.status='OPEN' AND reservation.total_dispatched_base_qty=0
        AND NOT private.sales_payment_blocks_order_cancel(
          sale.company_id,sale.id,v_actor)
      ) ORDER BY invoice.created_at DESC,invoice.id)
    FROM (SELECT candidate.* FROM public.sales_invoice_snapshots candidate
      WHERE candidate.company_id=v_company
      ORDER BY candidate.created_at DESC,candidate.id LIMIT 500) invoice
    JOIN public.sales_headers sale ON sale.company_id=invoice.company_id
      AND sale.id=invoice.sales_id
    LEFT JOIN public.customers customer ON customer.company_id=sale.company_id
      AND customer.id=sale.customer_id
    LEFT JOIN public.stores store ON store.company_id=sale.company_id
      AND store.id=sale.store_id
    LEFT JOIN public.profiles cancel_actor ON cancel_actor.id=sale.canceled_by
    LEFT JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
  ),'[]'::jsonb));
END
$$;

CREATE OR REPLACE FUNCTION public.get_sales_invoice_document(p_sales_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_result jsonb;v_invoice public.sales_invoice_snapshots%rowtype;
  v_sale public.sales_headers%rowtype;
  v_reservation public.sales_stock_reservations%rowtype;v_cancel_name text;
  v_permission jsonb;v_can_cancel boolean;v_timezone text;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'sales.sales_documents','VIEW');
  v_result:=private.acp5e_get_sales_invoice_document_core(p_sales_id);
  SELECT invoice.* INTO v_invoice FROM public.sales_invoice_snapshots invoice
  WHERE invoice.company_id=v_company AND invoice.sales_id=p_sales_id;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND'; END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=v_company;
  SELECT reservation.* INTO v_reservation FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.sales_id=p_sales_id;
  SELECT profile.name INTO v_cancel_name FROM public.profiles profile
  WHERE profile.id=v_sale.canceled_by;
  v_permission:=private.acp_resolve_permission(v_company,v_actor,'sales.sales_orders');
  v_can_cancel:=(v_permission->'effectiveCapabilities') ? 'CANCEL_FINAL'
    AND v_sale.document_status='DRAFT'
    AND v_sale.order_runtime_status IN('CONFIRMED','RESERVED')
    AND v_reservation.status='OPEN' AND v_reservation.total_dispatched_base_qty=0
    AND NOT private.sales_payment_blocks_order_cancel(v_company,p_sales_id,v_actor);
  RETURN v_result||jsonb_build_object('invoiceSnapshotId',v_invoice.id,
    'invoiceDate',private.resolve_sales_invoice_display_date(
      v_invoice.snapshot_payload,to_jsonb(v_sale),v_invoice.created_at,v_timezone),
    'invoiceStatus',CASE WHEN v_sale.order_runtime_status='CANCELED'
      OR v_sale.document_status='CANCELED' THEN 'CANCELED' ELSE 'ACTIVE' END,
    'orderRuntimeStatus',v_sale.order_runtime_status,
    'masterVersion',v_sale.master_version,'canceledAt',v_sale.canceled_at,
    'cancelReason',v_sale.cancel_reason,'canceledBy',v_sale.canceled_by,
    'canceledByName',v_cancel_name,'canCancel',v_can_cancel);
END
$$;

DO $backfill$
DECLARE v_request record;
BEGIN
  FOR v_request IN SELECT request.company_id,request.id,request.requested_by
    FROM public.sales_payment_verification_requests request
    WHERE request.status='PENDING' AND request.settlement_route_snapshot='CASH_DRAWER'
    ORDER BY request.company_id,request.requested_at,request.id
  LOOP
    PERFORM private.auto_verify_pos_cash_payment_request(
      v_request.company_id,v_request.id,v_request.requested_by);
  END LOOP;
END
$backfill$;

CREATE FUNCTION private.trg_enforce_no_pending_pos_cash()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=NEW.company_id AND request.id=NEW.id
      AND request.settlement_route_snapshot='CASH_DRAWER'
      AND request.status='PENDING') THEN
    RAISE EXCEPTION 'POS_CASH_AUTO_VERIFICATION_REQUIRED';
  END IF;
  RETURN NULL;
END
$$;
CREATE CONSTRAINT TRIGGER enforce_no_pending_pos_cash
AFTER INSERT OR UPDATE OF status,settlement_route_snapshot
ON public.sales_payment_verification_requests
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
EXECUTE FUNCTION private.trg_enforce_no_pending_pos_cash();

REVOKE ALL ON FUNCTION private.auto_verify_pos_cash_payment_request(uuid,uuid,uuid),
  private.sales_payment_blocks_order_cancel(uuid,uuid,uuid),
  private.trg_enforce_no_pending_pos_cash() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.auto_verify_pos_cash_payment_request(uuid,uuid,uuid),
  private.sales_payment_blocks_order_cancel(uuid,uuid,uuid),
  private.trg_enforce_no_pending_pos_cash() TO service_role;
REVOKE ALL ON FUNCTION private.capture_sales_order_payment_requests(uuid,uuid,uuid),
  private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.capture_sales_order_payment_requests(uuid,uuid,uuid),
  private.cancel_pending_sales_order_payments(uuid,uuid,uuid,uuid,text)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260923100000','pos_cash_auto_verification',
  'POS CASH_DRAWER payments auto-verify to source-linked HOLD events; non-Cash remains manual Finance; exact pending Cash backfill and pre-dispatch cancellation are guarded');

NOTIFY pgrst,'reload schema';
COMMIT;
