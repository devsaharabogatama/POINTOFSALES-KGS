-- Authenticated rollback-only behavior for POS Cash auto-verification.
BEGIN;

DO $test$
DECLARE v_company uuid;v_store uuid;v_pos uuid;v_warehouse uuid;v_customer uuid;
  v_actor uuid:=gen_random_uuid();v_cash_method public.payment_methods%rowtype;
  v_non_cash_method public.payment_methods%rowtype;v_session uuid:=gen_random_uuid();
  v_sale uuid:=gen_random_uuid();v_capture_sale uuid:=gen_random_uuid();
  v_capture_cash_key uuid:=gen_random_uuid();v_capture_non_cash_key uuid:=gen_random_uuid();
  v_cash_request uuid:=gen_random_uuid();
  v_non_cash_request uuid:=gen_random_uuid();v_second_cash uuid:=gen_random_uuid();
  v_cash_key uuid:=gen_random_uuid();v_non_cash_key uuid:=gen_random_uuid();
  v_second_key uuid:=gen_random_uuid();v_movement uuid;v_second_movement uuid;
  v_event uuid;v_result jsonb;v_rejected boolean;v_count bigint;
BEGIN
  SELECT company.id,store.id,terminal.id,warehouse.id,customer.id
  INTO v_company,v_store,v_pos,v_warehouse,v_customer
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.pos_terminals terminal ON terminal.company_id=company.id
    AND terminal.store_id=store.id AND terminal.status='ACTIVE'
  JOIN public.warehouses warehouse ON warehouse.company_id=company.id
    AND warehouse.is_active AND warehouse.is_sale_source
  JOIN public.customers customer ON customer.company_id=company.id
  WHERE company.status='ACTIVE'
    AND EXISTS(SELECT 1 FROM public.transaction_categories category
      WHERE category.company_id=company.id AND category.system_key='SALE_PAYMENT_VERIFIED'
        AND category.is_active)
    AND EXISTS(SELECT 1 FROM public.payment_methods method
      WHERE method.company_id=company.id AND method.is_active
        AND method.settlement_route='CASH_DRAWER')
    AND EXISTS(SELECT 1 FROM public.payment_methods method
      WHERE method.company_id=company.id AND method.is_active
        AND method.settlement_route<>'CASH_DRAWER'
        AND method.method_type NOT IN('TEMPO','CUSTOMER_BALANCE','KETUL_OFFSET'))
  ORDER BY company.created_at,company.id,store.id,terminal.id,warehouse.id,customer.id
  LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Company with Cash, non-Cash, POS, Warehouse and category required';
  END IF;
  SELECT method.* INTO STRICT v_cash_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.settlement_route='CASH_DRAWER' ORDER BY method.id LIMIT 1;
  SELECT method.* INTO STRICT v_non_cash_method FROM public.payment_methods method
  WHERE method.company_id=v_company AND method.is_active
    AND method.settlement_route<>'CASH_DRAWER'
    AND method.method_type NOT IN('TEMPO','CUSTOMER_BALANCE','KETUL_OFFSET')
  ORDER BY method.id LIMIT 1;

  INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at)
  VALUES(v_actor,'pos-cash-auto-'||right(v_actor::text,8)||'@example.invalid',
    '00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}',
    '{"name":"POS Cash Auto Test"}',false,'authenticated','authenticated',now());
  -- auth.users invokes public.handle_new_user() in the live runtime, so the
  -- Profile may already exist by the time this fixture reaches this statement.
  INSERT INTO public.profiles(id,email,name,role)
  VALUES(v_actor,'pos-cash-auto-'||right(v_actor::text,8)||'@example.invalid',
    'POS Cash Auto Test','cashier'::public.user_role)
  ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name,
    role=excluded.role;
  INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company)
  VALUES(v_company,v_actor,'CASHIER','ACTIVE',false);
  INSERT INTO public.store_memberships(company_id,store_id,user_id,role_code,status)
  VALUES(v_company,v_store,v_actor,'CASHIER','ACTIVE');

  PERFORM set_config('request.jwt.claims',jsonb_build_object(
    'sub',v_actor,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'POS_CASH_AUTO_TEST');
  PERFORM set_config('kgs.sales_process_grandfathered_lineage','1',true);
  INSERT INTO public.cashier_sessions(id,session_code,cashier_id,opening_balance,
    expected_cash,actual_cash,difference,status,company_id,store_id,pos_id,
    sales_warehouse_id,opening_cash_actual)
  VALUES(v_session,'TEST-CASH-AUTO-'||right(v_session::text,8),v_actor,0,0,0,0,
    'OPEN'::public.session_status,v_company,v_store,v_pos,v_warehouse,0);
  INSERT INTO public.sales_headers(id,invoice_no,session_id,customer_id,
    transaction_date,is_tempo,subtotal,item_discount,global_discount,grand_total,
    paid_amount,sisa_piutang,created_by,payload_snapshot,company_id,store_id,pos_id,
    document_status,client_transaction_id,sales_warehouse_id,
    grand_total_before_rounding,rounding_direction,rounding_increment,
    rounding_adjustment,grand_total_after_rounding,order_runtime_status,
    confirmed_at,confirmed_by,confirmation_idempotency_key,reservation_version)
  VALUES(v_sale,'DRAFT-TEST-'||right(v_sale::text,12),v_session,v_customer,
    clock_timestamp(),false,150000,0,0,150000,0,0,v_actor,'{}'::jsonb,
    v_company,v_store,v_pos,'DRAFT',gen_random_uuid(),v_warehouse,
    150000,'NONE',100,0,150000,'CONFIRMED',clock_timestamp(),v_actor,
    gen_random_uuid(),1);

  INSERT INTO public.sales_headers(id,invoice_no,session_id,customer_id,
    transaction_date,is_tempo,subtotal,item_discount,global_discount,grand_total,
    paid_amount,sisa_piutang,created_by,payload_snapshot,company_id,store_id,pos_id,
    document_status,client_transaction_id,sales_warehouse_id,
    grand_total_before_rounding,rounding_direction,rounding_increment,
    rounding_adjustment,grand_total_after_rounding,order_runtime_status,
    confirmed_at,confirmed_by,confirmation_idempotency_key,reservation_version)
  VALUES(v_capture_sale,'DRAFT-CAPTURE-'||right(v_capture_sale::text,12),
    v_session,v_customer,clock_timestamp(),false,150000,0,0,150000,0,0,v_actor,
    jsonb_build_object('payments',jsonb_build_array(
      jsonb_build_object('clientPaymentKey',v_capture_cash_key,
        'paymentMethodId',v_cash_method.id,'amount',100000,'tenderedAmount',100000),
      jsonb_build_object('clientPaymentKey',v_capture_non_cash_key,
        'paymentMethodId',v_non_cash_method.id,'amount',50000,'tenderedAmount',50000,
        'proofUrl','https://example.invalid/rollback-only-proof'))),
    v_company,v_store,v_pos,'DRAFT',gen_random_uuid(),v_warehouse,
    150000,'NONE',100,0,150000,'CONFIRMED',clock_timestamp(),v_actor,
    gen_random_uuid(),1);
  v_result:=private.capture_sales_order_payment_requests(
    v_company,v_capture_sale,v_actor);
  IF (v_result->>'requestCount')::integer<>2
    OR (v_result->>'createdCount')::integer<>2
    OR (v_result->>'autoVerifiedCashCount')::integer<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical payment capture did not split Cash and non-Cash';
  END IF;
  IF (SELECT count(*) FROM public.sales_payment_verification_requests request
      WHERE request.company_id=v_company AND request.sales_id=v_capture_sale
        AND request.status='VERIFIED' AND request.verification_mode='AUTO_CASH')<>1
    OR (SELECT count(*) FROM public.sales_payment_verification_requests request
      WHERE request.company_id=v_company AND request.sales_id=v_capture_sale
        AND request.status='PENDING' AND request.verification_mode='MANUAL_REVIEW')<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical capture status split invalid';
  END IF;
  v_result:=private.capture_sales_order_payment_requests(
    v_company,v_capture_sale,v_actor);
  IF NOT (v_result->>'exactRetry')::boolean
    OR (v_result->>'createdCount')::integer<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical payment capture retry duplicated requests';
  END IF;

  INSERT INTO public.cash_drawer_movements(company_id,store_id,pos_terminal_id,
    cashier_session_id,direction,movement_type,amount,source_table,source_id,
    expected_cash_after,actor_id)
  VALUES(v_company,v_store,v_pos,v_session,'IN','SALE_PAYMENT_INTENT',100000,
    'sales_payment_verification_requests',v_cash_request,100000,v_actor)
  RETURNING id INTO v_movement;
  INSERT INTO public.sales_payment_verification_requests(id,company_id,sales_id,
    client_payment_key,payment_method_id,amount,status,payment_method_code_snapshot,
    payment_method_name_snapshot,payment_method_type_snapshot,
    settlement_route_snapshot,settlement_account_function_snapshot,intent_snapshot,
    requested_by,cashier_session_id,store_id,pos_terminal_id,cash_drawer_movement_id)
  VALUES(v_cash_request,v_company,v_sale,v_cash_key,v_cash_method.id,100000,'PENDING',
    v_cash_method.payment_method_code,v_cash_method.payment_method_name,
    v_cash_method.method_type,'CASH_DRAWER','CASH_DRAWER',
    jsonb_build_object('sourceContract','ROLLBACK_TEST','settlementAmount',100000),
    v_actor,v_session,v_store,v_pos,v_movement);
  INSERT INTO public.sales_payment_verification_requests(id,company_id,sales_id,
    client_payment_key,payment_method_id,amount,status,payment_method_code_snapshot,
    payment_method_name_snapshot,payment_method_type_snapshot,
    settlement_route_snapshot,settlement_account_function_snapshot,intent_snapshot,
    requested_by,cashier_session_id,store_id,pos_terminal_id)
  VALUES(v_non_cash_request,v_company,v_sale,v_non_cash_key,v_non_cash_method.id,50000,
    'PENDING',v_non_cash_method.payment_method_code,v_non_cash_method.payment_method_name,
    v_non_cash_method.method_type,v_non_cash_method.settlement_route,
    private.odr5d_settlement_account_function(v_non_cash_method),
    jsonb_build_object('sourceContract','ROLLBACK_TEST','settlementAmount',50000),
    v_actor,v_session,v_store,v_pos);

  v_rejected:=false;
  BEGIN
    PERFORM set_config('kgs.odr5_payment_verification_mutation','1',true);
    UPDATE public.sales_payment_verification_requests SET status='VERIFIED',
      reviewed_by=v_actor,reviewed_at=clock_timestamp(),
      receipt_timing='PRE_DISPATCH',settlement_target='CUSTOMER_ADVANCE'
    WHERE company_id=v_company AND id=v_cash_request;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='POS_CASH_MANUAL_VERIFICATION_FORBIDDEN' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  PERFORM set_config('kgs.odr5_payment_verification_mutation','',true);
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: Cash accepted manual Finance verification';
  END IF;

  v_result:=private.auto_verify_pos_cash_payment_request(
    v_company,v_cash_request,v_actor);
  IF v_result->>'status'<>'VERIFIED' OR (v_result->>'exactRetry')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: Cash was not auto-verified';
  END IF;
  SELECT request.financial_event_id INTO v_event
  FROM public.sales_payment_verification_requests request
  WHERE request.company_id=v_company AND request.id=v_cash_request
    AND request.status='VERIFIED' AND request.verification_mode='AUTO_CASH';
  IF v_event IS NULL OR NOT EXISTS(SELECT 1 FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=v_event
      AND event.status='HOLD'::public.event_status
      AND event.system_event_key='SALE_PAYMENT_VERIFIED') THEN
    RAISE EXCEPTION 'TEST_FAILED: source-linked Cash HOLD event missing';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_payment_verification_requests request
    WHERE request.company_id=v_company AND request.id=v_non_cash_request
      AND request.status='PENDING' AND request.verification_mode='MANUAL_REVIEW') THEN
    RAISE EXCEPTION 'TEST_FAILED: non-Cash leg did not remain manual';
  END IF;
  v_result:=private.auto_verify_pos_cash_payment_request(
    v_company,v_cash_request,v_actor);
  IF NOT(v_result->>'exactRetry')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: exact Cash retry was not idempotent';
  END IF;
  SELECT count(*) INTO v_count FROM public.financial_events event
  WHERE event.company_id=v_company AND event.source_table='sales_payment_verification_requests'
    AND event.source_id=v_cash_request;
  IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: Cash retry duplicated event'; END IF;

  v_result:=private.cancel_pending_sales_order_payments(v_company,v_sale,v_actor,
    gen_random_uuid(),'Rollback-only pre-dispatch cancellation');
  IF (v_result->>'canceledPaymentRequests')::bigint<>2
    OR (v_result->>'cashDrawerReversals')::bigint<>1
    OR (v_result->>'canceledHoldEvents')::bigint<>1 THEN
    RAISE EXCEPTION 'TEST_FAILED: Cash/non-Cash cancellation split invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.financial_events event
    WHERE event.company_id=v_company AND event.id=v_event
      AND event.status='CANCELED'::public.event_status)
    OR NOT EXISTS(SELECT 1 FROM public.cash_drawer_movements movement
      WHERE movement.company_id=v_company
        AND movement.source_table='sales_payment_verification_reversal'
        AND movement.source_id=v_cash_request AND movement.direction='OUT'
        AND movement.amount=100000) THEN
    RAISE EXCEPTION 'TEST_FAILED: canceled Cash did not reverse HOLD and Drawer';
  END IF;

  INSERT INTO public.cash_drawer_movements(company_id,store_id,pos_terminal_id,
    cashier_session_id,direction,movement_type,amount,source_table,source_id,
    expected_cash_after,actor_id)
  VALUES(v_company,v_store,v_pos,v_session,'IN','SALE_PAYMENT_INTENT',25000,
    'sales_payment_verification_requests',v_second_cash,25000,v_actor)
  RETURNING id INTO v_second_movement;
  INSERT INTO public.sales_payment_verification_requests(id,company_id,sales_id,
    client_payment_key,payment_method_id,amount,status,payment_method_code_snapshot,
    payment_method_name_snapshot,payment_method_type_snapshot,
    settlement_route_snapshot,settlement_account_function_snapshot,intent_snapshot,
    requested_by,cashier_session_id,store_id,pos_terminal_id,cash_drawer_movement_id)
  VALUES(v_second_cash,v_company,v_sale,v_second_key,v_cash_method.id,25000,'PENDING',
    v_cash_method.payment_method_code,v_cash_method.payment_method_name,
    v_cash_method.method_type,'CASH_DRAWER','CASH_DRAWER',
    jsonb_build_object('sourceContract','ROLLBACK_TEST','settlementAmount',25000),
    v_actor,v_session,v_store,v_pos,v_second_movement);
  v_result:=private.auto_verify_pos_cash_payment_request(
    v_company,v_second_cash,v_actor);
  UPDATE public.financial_events SET status='POSTED'::public.event_status
  WHERE company_id=v_company AND id=(v_result->>'financialEventId')::uuid;
  v_rejected:=false;
  BEGIN
    PERFORM private.cancel_pending_sales_order_payments(v_company,v_sale,v_actor,
      gen_random_uuid(),'Posted event must not be rewritten');
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED' THEN
      v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'TEST_FAILED: posted Cash event accepted destructive cancel';
  END IF;
  v_rejected:=false;
  BEGIN
    PERFORM private.auto_verify_pos_cash_payment_request(
      gen_random_uuid(),v_second_cash,v_actor);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='PAYMENT_VERIFICATION_NOT_FOUND' THEN v_rejected:=true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: tenant scope was bypassed'; END IF;
END
$test$;

SELECT 'pos_cash_auto_verification_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'canonical capture Cash/non-Cash split','canonical capture exact retry',
    'Cash request auto VERIFIED','source-linked HOLD Finance event',
    'manual Finance cannot verify Cash',
    'non-Cash leg remains PENDING manual Finance','split-payment independence',
    'exact retry without duplicate Event','pre-dispatch Cash Drawer reversal',
    'HOLD Event cancellation','posted Event requires source-linked reversal',
    'tenant scope rejection','all fixture writes rolled back']) details;

ROLLBACK;
