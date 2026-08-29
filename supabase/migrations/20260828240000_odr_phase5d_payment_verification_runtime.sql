-- ODR-5D: immutable Sales Order payment verification and controlled posting.
-- Automatic posting and pre-dispatch advance application stay closed until ODR-5E.
BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828210000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828220000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828230000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-5A, ODR-5B and ODR-5C required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828240000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828240000';
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
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: payment verification source must be empty';
  END IF;
  SELECT pg_get_functiondef(
    'public.confirm_pos_sales_order(uuid,bigint,uuid,text)'::regprocedure)
  INTO v_definition;
  IF v_definition IS NULL OR v_definition!~'ensure_confirmed_order_documents'
    OR v_definition!~'refresh_sales_order_procurement_demand' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Order confirmation changed';
  END IF;
END
$guard$;

ALTER TABLE public.sales_payment_verification_requests
  ADD COLUMN cashier_session_id UUID,
  ADD COLUMN store_id UUID,
  ADD COLUMN pos_terminal_id UUID,
  ADD COLUMN effective_date DATE,
  ADD COLUMN cash_drawer_movement_id UUID,
  ADD COLUMN cash_drawer_reversal_movement_id UUID,
  ADD CONSTRAINT fk_sales_payment_verification_session FOREIGN KEY(
    company_id,store_id,cashier_session_id)
    REFERENCES public.cashier_sessions(company_id,store_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_sales_payment_verification_terminal FOREIGN KEY(
    company_id,store_id,pos_terminal_id)
    REFERENCES public.pos_terminals(company_id,store_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_sales_payment_verification_cash_movement FOREIGN KEY(
    company_id,cash_drawer_movement_id)
    REFERENCES public.cash_drawer_movements(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT fk_sales_payment_verification_cash_reversal FOREIGN KEY(
    company_id,cash_drawer_reversal_movement_id)
    REFERENCES public.cash_drawer_movements(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_payment_verification_operational_identity_check CHECK(
    cashier_session_id IS NOT NULL AND store_id IS NOT NULL
      AND pos_terminal_id IS NOT NULL),
  ADD CONSTRAINT sales_payment_verification_effective_date_check CHECK(
    status<>'VERIFIED' OR effective_date IS NOT NULL),
  ADD CONSTRAINT sales_payment_verification_cash_shape_check CHECK(
    (settlement_route_snapshot='CASH_DRAWER' AND cash_drawer_movement_id IS NOT NULL)
    OR (settlement_route_snapshot<>'CASH_DRAWER'
      AND cash_drawer_movement_id IS NULL
      AND cash_drawer_reversal_movement_id IS NULL));

ALTER TABLE public.cash_drawer_movements
  DROP CONSTRAINT cash_drawer_movement_type_check,
  ADD CONSTRAINT cash_drawer_movement_type_check CHECK(movement_type IN(
    'EXPENSE_DISBURSEMENT','EXPENSE_RETURN','CASH_IN','REVERSAL',
    'SALE_PAYMENT_INTENT'));

CREATE FUNCTION private.odr5d_settlement_account_function(
  p_method public.payment_methods
) RETURNS TEXT LANGUAGE sql IMMUTABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
  SELECT CASE p_method.settlement_route
    WHEN 'CASH_DRAWER' THEN 'CASH_DRAWER'
    WHEN 'DIRECT_BANK' THEN NULLIF(btrim(p_method.bank_account_function),'')
    WHEN 'CLEARING' THEN NULLIF(btrim(p_method.clearing_account_function),'')
    WHEN 'RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
    ELSE NULL END
$$;

CREATE FUNCTION private.capture_sales_order_payment_requests(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%ROWTYPE;v_session public.cashier_sessions%ROWTYPE;
  v_method public.payment_methods%ROWTYPE;v_payment JSONB;v_request_id UUID;
  v_client_key UUID;v_base NUMERIC(24,4);v_tendered NUMERIC(24,4);
  v_fee NUMERIC(24,4);v_surcharge NUMERIC(24,4);v_amount NUMERIC(24,4);
  v_base_total NUMERIC(24,4):=0;v_count INTEGER:=0;v_created INTEGER:=0;
  v_proof TEXT;v_function TEXT;v_expected NUMERIC(24,4);v_movement UUID;
  v_snapshot JSONB;v_existing public.sales_payment_verification_requests%ROWTYPE;
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
    COALESCE(v_sale.payload_snapshot->'payments','[]'::JSONB))
  LOOP
    BEGIN
      v_client_key:=(v_payment->>'clientPaymentKey')::UUID;
      v_base:=round((v_payment->>'amount')::NUMERIC,4);
      v_tendered:=round(COALESCE((v_payment->>'tenderedAmount')::NUMERIC,v_base),4);
    EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'INVALID_PAYMENT_INTENT'; END;
    IF v_client_key IS NULL OR v_base<=0 OR v_tendered<v_base THEN
      RAISE EXCEPTION 'INVALID_PAYMENT_AMOUNT';
    END IF;
    SELECT method.* INTO v_method FROM public.payment_methods method
    WHERE method.company_id=p_company_id
      AND method.id=(v_payment->>'paymentMethodId')::UUID
      AND method.is_active AND method.effective_from<=clock_timestamp()
      AND (method.effective_to IS NULL OR method.effective_to>=clock_timestamp())
      AND (method.available_all_stores OR EXISTS(SELECT 1
        FROM public.payment_method_store_assignments assignment
        WHERE assignment.company_id=method.company_id
          AND assignment.payment_method_id=method.id
          AND assignment.store_id=v_sale.store_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'ELIGIBLE_PAYMENT_METHOD_REQUIRED'; END IF;
    IF v_method.settlement_route='INTERNAL_LIABILITY'
      OR v_method.method_type IN('CUSTOMER_BALANCE','KETUL_OFFSET') THEN
      RAISE EXCEPTION 'ODR_INTERNAL_LIABILITY_PAYMENT_NOT_SUPPORTED';
    END IF;
    IF v_method.method_type='TEMPO' THEN
      RAISE EXCEPTION 'TEMPO_IS_DOCUMENT_MODE_NOT_PAYMENT_LEG';
    END IF;
    v_proof:=NULLIF(btrim(v_payment->>'proofUrl'),'');
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
    v_created:=v_created+1;
  END LOOP;
  IF NOT v_sale.is_tempo AND (v_count=0 OR v_base_total<>v_sale.grand_total_after_rounding) THEN
    RAISE EXCEPTION 'PAYMENT_TOTAL_MISMATCH';
  END IF;
  IF v_sale.is_tempo AND v_base_total>v_sale.grand_total_after_rounding THEN
    RAISE EXCEPTION 'PAYMENT_TOTAL_EXCEEDS_RECEIVABLE';
  END IF;
  RETURN jsonb_build_object('requestCount',v_count,'createdCount',v_created,
    'paymentBaseTotal',v_base_total,'exactRetry',v_created=0);
END
$$;

CREATE OR REPLACE FUNCTION public.confirm_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_documents JSONB;v_demand JSONB;v_payment JSONB;
  v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  v_result:=private.confirm_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_negative_stock_reason);
  v_documents:=private.ensure_confirmed_order_documents(v_company,p_sales_id);
  v_demand:=private.refresh_sales_order_procurement_demand(
    v_company,p_sales_id,v_actor,p_idempotency_key,'CONFIRM');
  v_payment:=private.capture_sales_order_payment_requests(
    v_company,p_sales_id,v_actor);
  RETURN v_result||jsonb_build_object('documents',v_documents,
    'procurementDemand',v_demand,'paymentVerification',v_payment);
END
$$;

CREATE FUNCTION public.get_finance_sales_payment_verifications()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_permission JSONB;
BEGIN
  v_permission:=private.acp_require_permission_capability(
    v_company,'finance.sales_payment_verification','VIEW');
  RETURN jsonb_build_object('companyId',v_company,'currentUserId',auth.uid(),
    'effectiveCapabilities',COALESCE(v_permission->'effectiveCapabilities','[]'::JSONB),
    'requests',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
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
      'financialEventId',request.financial_event_id,
      'masterVersion',request.master_version,'intentSnapshot',request.intent_snapshot)
      ORDER BY request.requested_at DESC,request.id DESC),'[]'::JSONB)
      FROM public.sales_payment_verification_requests request
      JOIN public.sales_headers sale ON sale.company_id=request.company_id
        AND sale.id=request.sales_id
      JOIN public.customers customer ON customer.company_id=sale.company_id
        AND customer.id=sale.customer_id
      JOIN public.stores store ON store.company_id=request.company_id
        AND store.id=request.store_id
      LEFT JOIN public.profiles maker ON maker.id=request.requested_by
      LEFT JOIN public.profiles reviewer ON reviewer.id=request.reviewed_by
      WHERE request.company_id=v_company));
END
$$;

CREATE FUNCTION public.review_sales_payment_verification(
  p_request_id UUID,p_master_version BIGINT,p_action TEXT,p_note TEXT,
  p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
  v_request public.sales_payment_verification_requests%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;v_event UUID:=gen_random_uuid();
  v_category UUID;v_category_count BIGINT;v_timing TEXT;v_target TEXT;
  v_timezone TEXT;v_effective DATE;v_now TIMESTAMPTZ:=clock_timestamp();
  v_before JSONB;v_after JSONB;v_expected NUMERIC(24,4);v_reversal UUID;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF v_action NOT IN('VERIFY','REJECT') THEN RAISE EXCEPTION 'INVALID_REVIEW_ACTION'; END IF;
  PERFORM private.acp_require_permission_capability(v_company,
    'finance.sales_payment_verification',CASE WHEN v_action='VERIFY' THEN 'APPROVE' ELSE 'REVIEW' END);
  SELECT request.* INTO v_request FROM public.sales_payment_verification_requests request
  WHERE request.company_id=v_company AND request.id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_NOT_FOUND'; END IF;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_audit audit
    WHERE audit.company_id=v_company AND audit.verification_request_id=p_request_id
      AND audit.action=v_action AND audit.idempotency_key=p_idempotency_key) THEN
    RETURN jsonb_build_object('requestId',v_request.id,'status',v_request.status,
      'masterVersion',v_request.master_version,'financialEventId',v_request.financial_event_id,
      'exactRetry',TRUE);
  END IF;
  IF v_request.status<>'PENDING' THEN RAISE EXCEPTION 'PAYMENT_VERIFICATION_FINAL'; END IF;
  IF v_request.master_version<>p_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_request.requested_by=v_actor THEN RAISE EXCEPTION 'MAKER_CHECKER_REQUIRED'; END IF;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_request.sales_id FOR SHARE;
  v_before:=to_jsonb(v_request);
  IF v_action='REJECT' THEN
    IF v_request.settlement_route_snapshot='CASH_DRAWER' THEN
      IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
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
    PERFORM set_config('kgs.odr5_payment_verification_mutation','1',TRUE);
    UPDATE public.sales_payment_verification_requests SET status='REJECTED',
      reviewed_by=v_actor,reviewed_at=v_now,review_note=NULLIF(btrim(p_note),''),
      cash_drawer_reversal_movement_id=v_reversal,master_version=master_version+1,
      updated_at=v_now WHERE company_id=v_company AND id=v_request.id
    RETURNING * INTO v_request;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','',TRUE);
  ELSE
    SELECT COALESCE(company.timezone,'Asia/Jakarta') INTO v_timezone
    FROM public.companies company WHERE company.id=v_company;
    v_effective:=(v_now AT TIME ZONE v_timezone)::DATE;
    IF EXISTS(SELECT 1 FROM public.sales_dispatch_financial_effects effect
      WHERE effect.company_id=v_company AND effect.sales_id=v_sale.id) THEN
      v_timing:='POST_DISPATCH';
      v_target:=CASE WHEN v_sale.is_tempo THEN 'CUSTOMER_RECEIVABLE'
        ELSE 'PAYMENT_CLEARING' END;
    ELSE v_timing:='PRE_DISPATCH';v_target:='CUSTOMER_ADVANCE'; END IF;
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
    VALUES(v_event,'ODR-PAY-'||upper(replace(v_request.id::TEXT,'-','')),
      'PAYMENT_RECEIVED'::public.event_type,'sales_payment_verification_requests',
      v_request.id,v_sale.id,v_now,1,
      'ODR_PAYMENT_VERIFY|'||v_company||'|'||v_request.id,
      v_request.payment_method_type_snapshot,jsonb_build_object(
        'settlementAmount',v_request.amount,'sourceAccountFunction',
        v_request.settlement_account_function_snapshot,'settlementTarget',v_target,
        'receiptTiming',v_timing),'HOLD'::public.event_status,v_actor,v_company,
      v_request.store_id,'SALE_PAYMENT_VERIFIED',v_category,1);
    PERFORM set_config('kgs.odr5_payment_verification_mutation','1',TRUE);
    UPDATE public.sales_payment_verification_requests SET status='VERIFIED',
      receipt_timing=v_timing,settlement_target=v_target,effective_date=v_effective,
      financial_event_id=v_event,reviewed_by=v_actor,reviewed_at=v_now,
      review_note=NULLIF(btrim(p_note),''),master_version=master_version+1,
      updated_at=v_now WHERE company_id=v_company AND id=v_request.id
    RETURNING * INTO v_request;
    PERFORM set_config('kgs.odr5_payment_verification_mutation','',TRUE);
  END IF;
  v_after:=to_jsonb(v_request);
  INSERT INTO public.sales_payment_verification_audit(company_id,
    verification_request_id,action,actor_id,idempotency_key,before_state,after_state)
  VALUES(v_company,v_request.id,v_action,v_actor,p_idempotency_key,v_before,v_after);
  RETURN jsonb_build_object('requestId',v_request.id,'status',v_request.status,
    'receiptTiming',v_request.receipt_timing,'settlementTarget',v_request.settlement_target,
    'financialEventId',v_request.financial_event_id,
    'masterVersion',v_request.master_version,'exactRetry',FALSE);
END
$$;

CREATE FUNCTION private.post_odr_payment_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_event public.financial_events%ROWTYPE;
  v_request public.sales_payment_verification_requests%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;v_period public.accounting_periods%ROWTYPE;
  v_source UUID;v_target UUID;v_journal public.finance_journals%ROWTYPE;
  v_rule_count BIGINT;v_rule_version BIGINT;v_accounting_date DATE;
  v_journal_type TEXT:='AUTOMATIC';v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  SELECT event.* INTO v_event FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'FINANCIAL_EVENT_NOT_FOUND'; END IF;
  IF v_event.event_version<>p_expected_event_version THEN RAISE EXCEPTION 'EVENT_VERSION_CONFLICT'; END IF;
  IF v_event.status::TEXT='POSTED' THEN
    SELECT journal.* INTO STRICT v_journal FROM public.finance_journals journal
    WHERE journal.company_id=p_company_id AND journal.financial_event_id=v_event.id;
    RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'status','POSTED','idempotentReplay',TRUE);
  END IF;
  IF v_event.status::TEXT='CANCELED' THEN
    RETURN jsonb_build_object('financialEventId',v_event.id,'status','CANCELED',
      'noFinancialEffect',TRUE,'idempotentReplay',TRUE);
  END IF;
  IF v_event.status::TEXT<>'HOLD' OR v_event.system_event_key<>'SALE_PAYMENT_VERIFIED'
    OR v_event.source_table<>'sales_payment_verification_requests' THEN
    RAISE EXCEPTION 'UNSUPPORTED_FINANCIAL_EVENT_CONTRACT';
  END IF;
  SELECT request.* INTO v_request FROM public.sales_payment_verification_requests request
  WHERE request.company_id=p_company_id AND request.id=v_event.source_id
    AND request.financial_event_id=v_event.id AND request.status='VERIFIED' FOR SHARE;
  IF NOT FOUND OR round((v_event.amounts->>'settlementAmount')::NUMERIC,4)<>v_request.amount
    OR v_event.amounts->>'sourceAccountFunction'<>
      v_request.settlement_account_function_snapshot
    OR v_event.amounts->>'settlementTarget'<>v_request.settlement_target THEN
    RAISE EXCEPTION 'FINANCIAL_EVENT_AMOUNT_SOURCE_MISMATCH';
  END IF;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=v_request.sales_id FOR SHARE;
  v_source:=private.resolve_financial_event_account(v_event,
    v_request.settlement_account_function_snapshot);
  v_target:=private.resolve_financial_event_account(v_event,CASE v_request.settlement_target
    WHEN 'CUSTOMER_ADVANCE' THEN 'CUSTOMER_ADVANCE_LIABILITY'
    WHEN 'CUSTOMER_RECEIVABLE' THEN 'CUSTOMER_RECEIVABLE'
    ELSE 'PAYMENT_CLEARING' END);
  IF v_source=v_target THEN
    UPDATE public.financial_events SET status='CANCELED'::public.event_status,
      processed_at=v_now,error_message='NO_FINANCIAL_EFFECT'
    WHERE company_id=p_company_id AND id=v_event.id;
    INSERT INTO public.sales_payment_verification_audit(company_id,
      verification_request_id,action,actor_id,idempotency_key,after_state)
    VALUES(p_company_id,v_request.id,'POST',p_actor_id,v_event.id,
      jsonb_build_object('financialEventId',v_event.id,'status','CANCELED',
        'reason','SOURCE_AND_TARGET_ACCOUNT_EQUAL'));
    RETURN jsonb_build_object('financialEventId',v_event.id,'status','CANCELED',
      'noFinancialEffect',TRUE,'idempotentReplay',FALSE);
  END IF;
  SELECT period.* INTO v_period FROM public.accounting_periods period
  WHERE period.company_id=p_company_id AND v_request.effective_date BETWEEN
    period.start_date AND period.end_date AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date LIMIT 1 FOR SHARE;
  IF NOT FOUND THEN
    SELECT period.* INTO v_period FROM public.accounting_periods period
    WHERE period.company_id=p_company_id AND period.start_date>v_request.effective_date
      AND period.status IN('OPEN','REOPENED') ORDER BY period.start_date LIMIT 1 FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND'; END IF;
    v_journal_type:='PRIOR_PERIOD_ADJUSTMENT';v_accounting_date:=v_period.start_date;
  ELSE v_accounting_date:=v_request.effective_date; END IF;
  SELECT count(*),max(rule_set.rule_set_version) INTO v_rule_count,v_rule_version
  FROM public.posting_rule_sets rule_set
  WHERE rule_set.company_id=p_company_id
    AND rule_set.transaction_category_id=v_event.transaction_category_id
    AND rule_set.system_key='SALE_PAYMENT_VERIFIED' AND rule_set.status='APPROVED'
    AND rule_set.effective_from<=v_event.event_date
    AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_event.event_date);
  IF v_rule_count<>1 THEN RAISE EXCEPTION 'POSTING_RULE_SET_MISSING_OR_AMBIGUOUS'; END IF;
  INSERT INTO public.finance_journals(company_id,journal_no,journal_type,
    accounting_period_id,accounting_date,original_event_date,source_type,source_id,
    source_version,financial_event_id,idempotency_key,system_event_key,
    transaction_category_id,transaction_rule_version,store_id,description,status,created_by)
  VALUES(p_company_id,'ODR-'||replace(v_event.id::TEXT,'-',''),v_journal_type,
    v_period.id,v_accounting_date,v_request.effective_date,v_event.source_table,
    v_request.id,v_request.master_version,v_event.id,
    'ODR_EVENT|'||p_company_id||'|'||v_event.id||'|'||v_event.event_version,
    v_event.system_event_key,v_event.transaction_category_id,v_rule_version,
    v_request.store_id,'ODR Payment verification: '||v_event.event_code,
    'DRAFT',p_actor_id) RETURNING * INTO v_journal;
  INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,
    debit,credit,store_id,customer_id,description)
  VALUES(p_company_id,v_journal.id,1,v_source,v_request.amount,0,
      v_request.store_id,v_sale.customer_id,v_request.settlement_account_function_snapshot),
    (p_company_id,v_journal.id,2,v_target,0,v_request.amount,
      v_request.store_id,v_sale.customer_id,v_request.settlement_target);
  UPDATE public.finance_journals SET status='POSTED',posted_by=p_actor_id,
    posted_at=v_now WHERE company_id=p_company_id AND id=v_journal.id
  RETURNING * INTO v_journal;
  UPDATE public.financial_events SET status='POSTED'::public.event_status,
    processed_at=v_now,error_message=NULL,transaction_rule_version=v_rule_version
  WHERE company_id=p_company_id AND id=v_event.id;
  INSERT INTO public.sales_payment_verification_audit(company_id,
    verification_request_id,action,actor_id,idempotency_key,after_state)
  VALUES(p_company_id,v_request.id,'POST',p_actor_id,v_event.id,
    jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
      'journalNo',v_journal.journal_no,'accountingDate',v_journal.accounting_date));
  RETURN jsonb_build_object('financialEventId',v_event.id,'journalId',v_journal.id,
    'journalNo',v_journal.journal_no,'status','POSTED','idempotentReplay',FALSE);
END
$$;

ALTER FUNCTION private.post_financial_event_core(UUID,UUID,BIGINT,UUID)
  RENAME TO post_financial_event_core_pre_odr5d;
CREATE FUNCTION private.post_financial_event_core(
  p_company_id UUID,p_event_id UUID,p_expected_event_version BIGINT,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_key TEXT;v_source TEXT;
BEGIN
  SELECT event.system_event_key,event.source_table INTO v_key,v_source
  FROM public.financial_events event
  WHERE event.company_id=p_company_id AND event.id=p_event_id;
  IF v_key='SALE_PAYMENT_VERIFIED'
    AND v_source='sales_payment_verification_requests' THEN
    RETURN private.post_odr_payment_financial_event_core(
      p_company_id,p_event_id,p_expected_event_version,p_actor_id);
  END IF;
  RETURN private.post_financial_event_core_pre_odr5d(
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
    WHEN 'SALE_DISPATCHED' THEN p_event.source_table='sales_dispatch_financial_effects'
    WHEN 'SALE_PAYMENT_VERIFIED' THEN
      p_event.source_table='sales_payment_verification_requests'
    ELSE FALSE END
$$;

-- Keep automatic posting closed until advance application and full reconciliation.
CREATE OR REPLACE FUNCTION private.trg_odr5c_guard_automatic_posting_policy()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.posting_mode='AUTOMATIC'
    AND NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828250000') THEN
    RAISE EXCEPTION 'ODR_AUTOMATIC_POSTING_NOT_READY';
  END IF;
  RETURN NEW;
END
$$;

ALTER FUNCTION private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT)
  RENAME TO dispatch_sales_delivery_core_pre_odr5d;
CREATE FUNCTION private.dispatch_sales_delivery_core(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_idempotency_key UUID,p_lines JSONB,p_notes TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_sale UUID;
BEGIN
  SELECT delivery.sales_id INTO v_sale FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company AND request.sales_id=v_sale
      AND request.status='VERIFIED' AND request.receipt_timing='PRE_DISPATCH') THEN
    RAISE EXCEPTION 'ODR_PREDISPATCH_ADVANCE_APPLICATION_NOT_READY';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company AND request.sales_id=v_sale
      AND request.status IN('PENDING','VERIFIED')
      AND COALESCE((request.intent_snapshot->>'customerSurchargeAmount')::NUMERIC,0)>0) THEN
    RAISE EXCEPTION 'ODR_PAYMENT_SURCHARGE_DISPATCH_APPLICATION_NOT_READY';
  END IF;
  RETURN private.dispatch_sales_delivery_core_pre_odr5d(
    p_delivery_document_id,p_master_version,p_idempotency_key,p_lines,p_notes);
END
$$;

ALTER FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
  RENAME TO odr5d_close_cashier_session_legacy;
ALTER FUNCTION public.odr5d_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
  SET SCHEMA private;
CREATE FUNCTION public.close_cashier_session(
  p_cashier_session_id UUID,p_master_version BIGINT,p_closing_cash_actual NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  IF EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company
      AND request.cashier_session_id=p_cashier_session_id
      AND request.settlement_route_snapshot='CASH_DRAWER'
      AND request.status='PENDING') THEN
    RAISE EXCEPTION 'PENDING_CASH_PAYMENT_VERIFICATION';
  END IF;
  RETURN private.odr5d_close_cashier_session_legacy(
    p_cashier_session_id,p_master_version,p_closing_cash_actual);
END
$$;

UPDATE public.access_permission_catalog SET enforcement_status='ENFORCED',
  catalog_version=catalog_version+1,updated_at=clock_timestamp()
WHERE permission_key='finance.sales_payment_verification'
  AND enforcement_status='SHADOW';

REVOKE ALL ON FUNCTION
  private.odr5d_settlement_account_function(public.payment_methods),
  private.capture_sales_order_payment_requests(UUID,UUID,UUID),
  private.post_odr_payment_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core_pre_odr5d(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.f4b_financial_event_supported(public.financial_events),
  private.dispatch_sales_delivery_core_pre_odr5d(UUID,BIGINT,UUID,JSONB,TEXT),
  private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.odr5d_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.odr5d_settlement_account_function(public.payment_methods),
  private.capture_sales_order_payment_requests(UUID,UUID,UUID),
  private.post_odr_payment_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core_pre_odr5d(UUID,UUID,BIGINT,UUID),
  private.post_financial_event_core(UUID,UUID,BIGINT,UUID),
  private.f4b_financial_event_supported(public.financial_events),
  private.dispatch_sales_delivery_core_pre_odr5d(UUID,BIGINT,UUID,JSONB,TEXT),
  private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.odr5d_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
TO service_role;
REVOKE ALL ON FUNCTION
  public.get_finance_sales_payment_verifications(),
  public.review_sales_payment_verification(UUID,BIGINT,TEXT,TEXT,UUID),
  public.close_cashier_session(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
  public.get_finance_sales_payment_verifications(),
  public.review_sales_payment_verification(UUID,BIGINT,TEXT,TEXT,UUID),
  public.close_cashier_session(UUID,BIGINT,NUMERIC)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828240000','odr_phase5d_payment_verification_runtime',
  'Capture immutable confirmed-Order external payment intents, record Cash exactly once in the drawer, enforce Finance maker-checker verification, create one HOLD SALE_PAYMENT_VERIFIED event and controlled canonical settlement posting; keep automatic posting and pre-dispatch advance application closed for ODR-5E');

NOTIFY pgrst,'reload schema';
COMMIT;
