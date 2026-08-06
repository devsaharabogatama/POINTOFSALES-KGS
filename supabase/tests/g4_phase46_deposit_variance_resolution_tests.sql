-- G4 phase 46 behavior: Deposit variance investigation and resolution.
-- SAFETY: every fixture, request, allocation, audit, and event is rolled back.

BEGIN;
DO $test$
DECLARE
    v_actor UUID; v_reviewer UUID;
    v_company UUID:='00000000-0000-0000-0000-000000076001';
    v_company_b UUID:='00000000-0000-0000-0000-000000076002';
    v_store UUID:='00000000-0000-0000-0000-000000076011';
    v_terminal UUID:='00000000-0000-0000-0000-000000076021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000076031';
    v_session_under UUID:='00000000-0000-0000-0000-000000076041';
    v_session_over UUID:='00000000-0000-0000-0000-000000076042';
    v_document UUID; v_exception UUID; v_request UUID; v_over_request UUID;
    v_result JSONB; v_count BIGINT; v_version BIGINT; v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
    ORDER BY profile.id LIMIT 1;
    SELECT profile.id INTO v_reviewer
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.id<>v_actor ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL OR v_reviewer IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: two linked users required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES
      (v_company,'G76','G76 Variance Company','g76-variance-company','ACTIVE'),
      (v_company_b,'G76B','G76 Company B','g76-company-b','ACTIVE');
    INSERT INTO public.company_memberships(
        company_id,user_id,role_code,status,is_default_company
    ) VALUES
        (v_company,v_actor,'FINANCE','ACTIVE',FALSE),
        (v_company,v_reviewer,'COMPANY_ADMIN','ACTIVE',FALSE),
        (v_company_b,v_actor,'FINANCE','ACTIVE',FALSE)
    ON CONFLICT(company_id,user_id) DO UPDATE SET
        role_code=excluded.role_code,status=excluded.status;
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES(v_store,v_company,'G76S','G76 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G76P','G76 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,is_sale_source
    ) VALUES(
        v_warehouse,v_company,'G76W','G76 Warehouse','STORE',v_store,TRUE
    );
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,opening_balance,expected_cash,actual_cash,
        difference,status,company_id,store_id,pos_id,sales_warehouse_id,
        opening_cash_actual,closing_cash_actual,closed_at
    ) VALUES
      (v_session_under,'G76-U',v_actor,0,100,100,0,'CLOSED',v_company,
       v_store,v_terminal,v_warehouse,0,100,clock_timestamp()),
      (v_session_over,'G76-O',v_actor,0,50,50,0,'CLOSED',v_company,
       v_store,v_terminal,v_warehouse,0,50,clock_timestamp());

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE46_TEST');

    v_result:=public.save_cash_deposit_draft(
        NULL,NULL,v_store,'BANK','G76 Bank',90,clock_timestamp(),NULL,
        'Under fixture','00000000-0000-0000-0000-000000076081',
        jsonb_build_array(jsonb_build_object(
            'sessionId',v_session_under,'nextSessionFloatReserved',0
        ))
    );
    v_document:=(v_result->>'depositDocumentId')::UUID;
    PERFORM public.submit_cash_deposit(
        v_document,1,'00000000-0000-0000-0000-000000076082'
    );
    PERFORM public.review_cash_deposit(
        v_document,2,'APPROVE',NULL,
        '00000000-0000-0000-0000-000000076083'
    );
    SELECT id,master_version INTO v_exception,v_version
    FROM public.deposit_variance_exceptions
    WHERE cash_deposit_document_id=v_document;
    IF v_exception IS NULL OR v_version<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: under exception not opened';
    END IF;

    PERFORM public.set_active_company_context(v_company_b,'G4_PHASE46_CROSS');
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.assign_deposit_variance_responsible_party(
            v_exception,1,v_actor,'Cross-company attempt'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='DEPOSIT_VARIANCE_EXCEPTION_NOT_FOUND' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company exception accessible';
    END IF;
    PERFORM public.set_active_company_context(v_company,'G4_PHASE46_TEST');

    v_result:=public.assign_deposit_variance_responsible_party(
        v_exception,1,v_actor,'Cashier custody investigation'
    );
    IF v_result->>'status'<>'UNDER_INVESTIGATION'
       OR (v_result->>'masterVersion')::BIGINT<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: responsible party assignment invalid';
    END IF;

    v_result:=public.resolve_deposit_variance(
        v_exception,2,4,'RECOVERED_FUNDS','BANK',
        'Recovered cash deposited','https://example.invalid/recovery.jpg',
        'BANK-RECOVERY-1','00000000-0000-0000-0000-000000076084'
    );
    IF v_result->>'status'<>'APPROVED'
       OR (v_result->>'remainingAmount')::NUMERIC<>6
       OR (v_result->>'requiresReview')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: direct partial resolution invalid';
    END IF;
    v_result:=public.resolve_deposit_variance(
        v_exception,2,4,'RECOVERED_FUNDS','BANK',
        'Recovered cash deposited','https://example.invalid/recovery.jpg',
        'BANK-RECOVERY-1','00000000-0000-0000-0000-000000076084'
    );
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: direct resolution retry not idempotent';
    END IF;

    v_result:=public.resolve_deposit_variance(
        v_exception,3,6,'WRITE_OFF',NULL,'Approved shortage write-off',
        'https://example.invalid/writeoff.jpg','WRITE-OFF-1',
        '00000000-0000-0000-0000-000000076085'
    );
    v_request:=(v_result->>'resolutionRequestId')::UUID;
    IF v_result->>'status'<>'SUBMITTED'
       OR NOT (v_result->>'requiresReview')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: maker-checker request invalid';
    END IF;
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.review_deposit_variance_resolution(
            v_request,1,'APPROVE',NULL,
            '00000000-0000-0000-0000-000000076086'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='MAKER_CANNOT_APPROVE_OWN_RESOLUTION' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: maker approved own write-off';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_reviewer,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE46_REVIEW');
    v_result:=public.review_deposit_variance_resolution(
        v_request,1,'APPROVE',NULL,
        '00000000-0000-0000-0000-000000076086'
    );
    IF v_result->>'status'<>'APPROVED'
       OR v_result->>'exceptionStatus'<>'WRITTEN_OFF'
       OR (v_result->>'remainingAmount')::NUMERIC<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: write-off review invalid';
    END IF;
    v_result:=public.review_deposit_variance_resolution(
        v_request,1,'APPROVE',NULL,
        '00000000-0000-0000-0000-000000076086'
    );
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: review retry not idempotent';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE46_TEST');
    v_result:=public.save_cash_deposit_draft(
        NULL,NULL,v_store,'VAULT','G76 Vault',60,clock_timestamp(),NULL,
        'Over fixture','00000000-0000-0000-0000-000000076087',
        jsonb_build_array(jsonb_build_object(
            'sessionId',v_session_over,'nextSessionFloatReserved',0
        ))
    );
    v_document:=(v_result->>'depositDocumentId')::UUID;
    PERFORM public.submit_cash_deposit(
        v_document,1,'00000000-0000-0000-0000-000000076088'
    );
    PERFORM public.review_cash_deposit(
        v_document,2,'APPROVE',NULL,
        '00000000-0000-0000-0000-000000076089'
    );
    SELECT id,master_version INTO v_exception,v_version
    FROM public.deposit_variance_exceptions
    WHERE cash_deposit_document_id=v_document;
    v_result:=public.resolve_deposit_variance(
        v_exception,v_version,10,'CASH_OVERAGE_INCOME',NULL,
        'Unclaimed over deposit','https://example.invalid/over.jpg',
        'OVER-INCOME-1','00000000-0000-0000-0000-000000076090'
    );
    v_over_request:=(v_result->>'resolutionRequestId')::UUID;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_reviewer,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE46_REVIEW');
    v_result:=public.review_deposit_variance_resolution(
        v_over_request,1,'REJECT','Owner not identified',
        '00000000-0000-0000-0000-000000076091'
    );
    IF v_result->>'status'<>'REJECTED' THEN
        RAISE EXCEPTION 'TEST_FAILED: resolution rejection invalid';
    END IF;
    IF EXISTS(
        SELECT 1 FROM public.deposit_variance_allocations allocation
        WHERE allocation.resolution_request_id=v_over_request
    ) OR EXISTS(
        SELECT 1 FROM public.financial_events event
        WHERE event.source_table='deposit_variance_resolution_requests'
          AND event.source_id=v_over_request
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: rejected resolution created final effect';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.deposit_variance_allocations allocation
    WHERE allocation.company_id=v_company;
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: expected two approved allocations, got %',v_count;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.financial_events event
    WHERE event.company_id=v_company
      AND event.event_type='DEPOSIT_VARIANCE_RESOLUTION'::public.event_type
      AND event.status='HOLD'::public.event_status;
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: resolution Financial Event count %',v_count;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.deposit_variance_resolution_audit audit
    WHERE audit.company_id=v_company;
    IF v_count<7 THEN
        RAISE EXCEPTION 'TEST_FAILED: resolution audit incomplete';
    END IF;
    IF has_table_privilege(
        'authenticated','public.deposit_variance_resolution_requests',
        'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.deposit_variance_allocations',
        'INSERT,UPDATE,DELETE'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: browser write boundary open'; END IF;

    RAISE NOTICE 'TEST PASSED: Deposit variance resolution is tenant-safe, partial, idempotent, maker-checker guarded, audited, and Finance-HOLD only.';
END
$test$;
ROLLBACK;
