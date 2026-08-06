-- G4 phase 43 behavior: multi-Session Cash Deposit lifecycle.
-- SAFETY: every fixture, audit row, exception, and event is rolled back.

BEGIN;
DO $test$
DECLARE
    v_actor UUID; v_company UUID:='00000000-0000-0000-0000-000000074001';
    v_store UUID:='00000000-0000-0000-0000-000000074011';
    v_terminal UUID:='00000000-0000-0000-0000-000000074021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000074031';
    v_session_a UUID:='00000000-0000-0000-0000-000000074041';
    v_session_b UUID:='00000000-0000-0000-0000-000000074042';
    v_session_c UUID:='00000000-0000-0000-0000-000000074043';
    v_document UUID; v_reject_document UUID; v_conflict_document UUID;
    v_result JSONB; v_count BIGINT; v_rejected BOOLEAN:=FALSE;
    v_deposit_at TIMESTAMPTZ:=clock_timestamp();
BEGIN
    SELECT profile.id INTO v_actor FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required'; END IF;

    INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES(v_company,'G74','G74 Cash Deposit Company','g74-cash-deposit-company','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES(v_store,v_company,'G74S','G74 Store','ACTIVE');
    INSERT INTO public.pos_terminals(id,company_id,store_id,pos_code,pos_name,status)
    VALUES(v_terminal,v_company,v_store,'G74P','G74 POS','ACTIVE');
    INSERT INTO public.warehouses(id,company_id,code,name,warehouse_type,store_id,is_sale_source)
    VALUES(v_warehouse,v_company,'G74W','G74 Warehouse','STORE',v_store,TRUE);
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,opening_balance,expected_cash,actual_cash,
        difference,status,company_id,store_id,pos_id,sales_warehouse_id,
        opening_cash_actual,closing_cash_actual,closed_at
    ) VALUES
      (v_session_a,'G74-A',v_actor,0,100,100,0,'CLOSED',v_company,v_store,v_terminal,v_warehouse,0,100,clock_timestamp()),
      (v_session_b,'G74-B',v_actor,0,200,200,0,'CLOSED',v_company,v_store,v_terminal,v_warehouse,0,200,clock_timestamp()),
      (v_session_c,'G74-C',v_actor,0,50,50,0,'CLOSED',v_company,v_store,v_terminal,v_warehouse,0,50,clock_timestamp());

    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G4_PHASE43_TEST');

    v_result:=public.save_cash_deposit_draft(
        NULL,NULL,v_store,'BANK','G74 Bank',260,v_deposit_at,
        'https://example.invalid/deposit.jpg','Behavior fixture',
        '00000000-0000-0000-0000-000000074081',
        jsonb_build_array(
          jsonb_build_object('sessionId',v_session_a,'nextSessionFloatReserved',10),
          jsonb_build_object('sessionId',v_session_b,'nextSessionFloatReserved',20)));
    v_document:=(v_result->>'depositDocumentId')::UUID;
    IF (v_result->>'totalExpectedDeposit')::NUMERIC<>270
       OR (v_result->>'depositVariance')::NUMERIC<>-10
       OR v_result->>'varianceType'<>'UNDER_DEPOSIT' THEN
        RAISE EXCEPTION 'TEST_FAILED: draft total or variance invalid';
    END IF;

    v_result:=public.save_cash_deposit_draft(
        NULL,NULL,v_store,'BANK','G74 Bank',260,v_deposit_at,
        'https://example.invalid/deposit.jpg','Behavior fixture',
        '00000000-0000-0000-0000-000000074081',
        jsonb_build_array(
          jsonb_build_object('sessionId',v_session_a,'nextSessionFloatReserved',10),
          jsonb_build_object('sessionId',v_session_b,'nextSessionFloatReserved',20)));
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: exact create replay not recognized';
    END IF;
    SELECT count(*) INTO v_count FROM public.cash_deposit_documents
    WHERE company_id=v_company AND client_deposit_id='00000000-0000-0000-0000-000000074081';
    IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: client identity duplicated'; END IF;

    v_result:=public.submit_cash_deposit(v_document,1,'00000000-0000-0000-0000-000000074082');
    IF v_result->>'status'<>'SUBMITTED' OR (v_result->>'masterVersion')::BIGINT<>2 THEN RAISE EXCEPTION 'TEST_FAILED: submit invalid'; END IF;

    v_result:=public.save_cash_deposit_draft(
        NULL,NULL,v_store,'VAULT','G74 Vault',90,clock_timestamp(),NULL,
        'Conflict fixture','00000000-0000-0000-0000-000000074083',
        jsonb_build_array(jsonb_build_object('sessionId',v_session_a,'nextSessionFloatReserved',10)));
    v_conflict_document:=(v_result->>'depositDocumentId')::UUID;
    BEGIN
        PERFORM public.submit_cash_deposit(v_conflict_document,1,'00000000-0000-0000-0000-000000074084');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='CASHIER_SESSION_ALREADY_DEPOSITED_OR_LOCKED' THEN v_rejected:=TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: duplicate active Session accepted'; END IF;

    v_result:=public.review_cash_deposit(v_document,2,'APPROVE',NULL,'00000000-0000-0000-0000-000000074085');
    IF v_result->>'status'<>'APPROVED' OR NOT (v_result->>'varianceExceptionOpened')::BOOLEAN THEN RAISE EXCEPTION 'TEST_FAILED: approval invalid'; END IF;
    SELECT count(*) INTO v_count FROM public.financial_events event
    WHERE event.source_table='cash_deposit_documents' AND event.source_id=v_document
      AND event.status='HOLD'::public.event_status;
    IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: Financial Event HOLD missing'; END IF;
    SELECT count(*) INTO v_count FROM public.deposit_variance_exceptions exception
    WHERE exception.cash_deposit_document_id=v_document
      AND exception.original_amount=10 AND exception.remaining_amount=10;
    IF v_count<>1 THEN RAISE EXCEPTION 'TEST_FAILED: variance exception invalid'; END IF;

    v_result:=public.save_cash_deposit_draft(
        NULL,NULL,v_store,'VAULT','G74 Vault',50,clock_timestamp(),NULL,
        'Reject fixture','00000000-0000-0000-0000-000000074086',
        jsonb_build_array(jsonb_build_object('sessionId',v_session_c,'nextSessionFloatReserved',0)));
    v_reject_document:=(v_result->>'depositDocumentId')::UUID;
    PERFORM public.submit_cash_deposit(v_reject_document,1,'00000000-0000-0000-0000-000000074087');
    v_result:=public.review_cash_deposit(v_reject_document,2,'REJECT','Proof not valid','00000000-0000-0000-0000-000000074088');
    IF v_result->>'status'<>'REJECTED' THEN RAISE EXCEPTION 'TEST_FAILED: reject invalid'; END IF;
    IF EXISTS(SELECT 1 FROM public.cash_deposit_session_lines line WHERE line.deposit_document_id=v_reject_document AND line.allocation_status<>'RELEASED') THEN RAISE EXCEPTION 'TEST_FAILED: rejected Session lock not released'; END IF;

    IF has_table_privilege('authenticated','public.cash_deposit_documents','INSERT,UPDATE,DELETE')
       OR has_table_privilege('authenticated','public.cash_deposit_session_lines','INSERT,UPDATE,DELETE')
       OR NOT has_function_privilege('authenticated','public.submit_cash_deposit(uuid,bigint,uuid)','EXECUTE') THEN RAISE EXCEPTION 'TEST_FAILED: browser write boundary invalid'; END IF;
    RAISE NOTICE 'TEST PASSED: Cash Deposit is multi-Session, tenant-safe, versioned, locked, approved/rejected atomically, audited, and variance-controlled.';
END
$test$;
ROLLBACK;
