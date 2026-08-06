-- G4 phase 37 behavior: reviewed actual, Cash return, and additional request.
-- SAFETY: every fixture, event, and drawer effect is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000072001';
    v_store UUID:='00000000-0000-0000-0000-000000072011';
    v_terminal UUID:='00000000-0000-0000-0000-000000072021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000072025';
    v_session UUID:='00000000-0000-0000-0000-000000072031';
    v_category UUID:='00000000-0000-0000-0000-000000072041';
    v_document UUID:='00000000-0000-0000-0000-000000072051';
    v_settlement_category UUID;
    v_disbursement_category UUID;
    v_expense_account UUID;
    v_outstanding_account UUID;
    v_cash_account UUID;
    v_cash_method UUID;
    v_result JSONB;
    v_request UUID;
    v_count BIGINT;
    v_expected NUMERIC;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
      AND NOT EXISTS (
          SELECT 1 FROM public.cashier_sessions session
          WHERE session.cashier_id=profile.id
            AND session.status='OPEN'::public.session_status
      )
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES(
        v_company,'G72','G72 Settlement Company',
        'g72-settlement-company','ACTIVE'
    );
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES(v_store,v_company,'G72S','G72 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G72P','G72 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,is_sale_source
    ) VALUES(
        v_warehouse,v_company,'G72W','G72 Warehouse','STORE',v_store,TRUE
    );

    SELECT id INTO v_settlement_category
    FROM public.transaction_categories
    WHERE company_id=v_company AND system_key='EXPENSE_SETTLEMENT'
      AND is_active ORDER BY created_at,id LIMIT 1;
    SELECT id INTO v_disbursement_category
    FROM public.transaction_categories
    WHERE company_id=v_company AND system_key='EXPENSE_DISBURSEMENT'
      AND is_active ORDER BY created_at,id LIMIT 1;
    SELECT id INTO v_expense_account FROM public.chart_of_accounts
    WHERE company_id=v_company AND system_function_key='EXPENSE'
      AND is_active AND is_postable ORDER BY account_code,id LIMIT 1;
    SELECT id INTO v_outstanding_account FROM public.chart_of_accounts
    WHERE company_id=v_company AND system_function_key='OUTSTANDING_EXPENSE'
      AND is_active AND is_postable ORDER BY account_code,id LIMIT 1;
    SELECT id INTO v_cash_account FROM public.chart_of_accounts
    WHERE company_id=v_company AND system_function_key='CASH_DRAWER'
      AND is_active AND is_postable ORDER BY account_code,id LIMIT 1;
    IF v_settlement_category IS NULL OR v_disbursement_category IS NULL
       OR v_expense_account IS NULL OR v_outstanding_account IS NULL
       OR v_cash_account IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Finance defaults missing';
    END IF;

    SELECT id INTO v_cash_method FROM public.payment_methods
    WHERE company_id=v_company AND method_type='CASH'
      AND settlement_route='CASH_DRAWER' AND is_active
    ORDER BY created_at,id LIMIT 1;
    IF v_cash_method IS NULL THEN
        INSERT INTO public.payment_methods(
            company_id,payment_method_code,payment_method_name,method_type,
            settlement_route,is_default,available_all_stores
        ) VALUES(
            v_company,'G72-CASH','G72 Cash','CASH','CASH_DRAWER',TRUE,TRUE
        ) RETURNING id INTO v_cash_method;
    END IF;

    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,updated_by
    ) VALUES(v_company,'expense_enabled',TRUE,v_actor);
    UPDATE public.expense_approval_policies
    SET approval_required=TRUE,updated_by=v_actor
    WHERE company_id=v_company AND store_id IS NULL;
    INSERT INTO public.expense_categories(
        id,company_id,category_code,category_name,transaction_category_id,
        expense_account_id,evidence_policy,approval_policy,
        is_system_default,created_by,updated_by
    ) VALUES(
        v_category,v_company,'G72-CATEGORY','G72 Operational',
        v_settlement_category,v_expense_account,'OPTIONAL','USE_DEFAULT',
        FALSE,v_actor,v_actor
    );
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,company_id,store_id,pos_id,status,
        sales_warehouse_id,opening_balance,opening_cash_actual,expected_cash
    ) VALUES(
        v_session,'G72-SESSION',v_actor,v_company,v_store,v_terminal,
        'OPEN'::public.session_status,v_warehouse,500000,500000,500000
    );

    INSERT INTO public.expense_documents(
        id,company_id,document_no,store_id,pos_terminal_id,
        cashier_session_id,category_id,category_name_snapshot,
        transaction_category_id,expense_account_id_snapshot,
        responsible_party_type,responsible_party_id,
        responsible_party_name_snapshot,requested_amount,disbursed_amount,
        actual_expense_amount,returned_amount,outstanding_amount,
        requested_payment_method_id,requested_payment_method_name_snapshot,
        requested_payment_method_type_snapshot,description,status,
        approval_required_snapshot,evidence_policy_snapshot,master_version,
        created_by,updated_by,submitted_by,approved_by,submitted_at,
        approved_at,disbursed_by,disbursed_at
    ) VALUES(
        v_document,v_company,'EXP-G72-000001',v_store,v_terminal,v_session,
        v_category,'G72 Operational',v_settlement_category,v_expense_account,
        'CASHIER',v_actor,'G72 Responsible',50000,50000,0,0,50000,
        v_cash_method,'G72 Cash','CASH','Settlement behavior fixture',
        'DISBURSED',TRUE,'OPTIONAL',4,v_actor,v_actor,v_actor,v_actor,
        clock_timestamp(),clock_timestamp(),v_actor,clock_timestamp()
    );
    INSERT INTO public.expense_disbursements(
        company_id,document_id,store_id,pos_terminal_id,amount,
        payment_method_id,payment_method_name_snapshot,
        payment_method_type_snapshot,payment_settlement_route_snapshot,
        payment_account_function_snapshot,cashier_session_id,
        idempotency_key,transaction_category_id,
        outstanding_account_id_snapshot,payment_account_id_snapshot,
        document_master_version_snapshot,approval_snapshot,created_by
    ) VALUES(
        v_company,v_document,v_store,v_terminal,50000,v_cash_method,
        'G72 Cash','CASH','CASH_DRAWER','CASH_DRAWER',v_session,
        '00000000-0000-0000-0000-000000072081',
        v_disbursement_category,v_outstanding_account,v_cash_account,3,
        jsonb_build_object(
            'approvalRequired',TRUE,'approvedBy',v_actor,
            'approvedAt',clock_timestamp(),'documentMasterVersion',3
        ),v_actor
    );
    INSERT INTO public.cash_drawer_movements(
        company_id,store_id,pos_terminal_id,cashier_session_id,direction,
        movement_type,amount,source_table,source_id,expected_cash_after,
        actor_id
    ) SELECT
        v_company,v_store,v_terminal,v_session,'OUT',
        'EXPENSE_DISBURSEMENT',50000,'expense_disbursements',id,450000,
        v_actor
    FROM public.expense_disbursements
    WHERE company_id=v_company AND document_id=v_document;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE37_TEST');

    v_result:=public.save_expense_settlement(
        v_document,4,30000,'https://example.invalid/actual',
        '00000000-0000-0000-0000-000000072091'
    );
    v_request:=(v_result->>'settlementRequestId')::UUID;
    IF v_result->>'status'<>'SUBMITTED' THEN
        RAISE EXCEPTION 'TEST_FAILED: settlement was not submitted';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.expense_documents
        WHERE id=v_document AND actual_expense_amount=0
          AND outstanding_amount=50000 AND master_version=4
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: unreviewed actual changed document';
    END IF;

    v_result:=public.review_expense_settlement(
        v_request,1,'APPROVE',NULL
    );
    IF v_result->>'status'<>'PARTIALLY_SETTLED'
       OR (v_result->>'outstandingAmount')::NUMERIC<>20000 THEN
        RAISE EXCEPTION 'TEST_FAILED: approved actual result invalid';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.expense_settlements settlement
    JOIN public.financial_events event
      ON event.company_id=settlement.company_id
     AND event.id=settlement.financial_event_id
    WHERE settlement.document_id=v_document
      AND settlement.actual_expense_amount=30000
      AND event.event_type='EXPENSE_SETTLEMENT'::public.event_type
      AND event.status='HOLD'::public.event_status;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: settlement final effect missing';
    END IF;

    v_result:=public.request_additional_expense_disbursement(
        v_document,5,10000,v_cash_method,NULL,
        '00000000-0000-0000-0000-000000072092'
    );
    IF v_result->>'status'<>'SUBMITTED'
       OR (v_result->>'cashEffect')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: additional request boundary invalid';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.cash_drawer_movements
        WHERE company_id=v_company AND amount=10000
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: additional request changed drawer';
    END IF;

    v_result:=public.return_expense_funds(
        v_document,5,20000,v_cash_method,v_session,NULL,
        '00000000-0000-0000-0000-000000072093'
    );
    IF v_result->>'status'<>'SETTLED'
       OR (v_result->>'outstandingAmount')::NUMERIC<>0
       OR (v_result->>'expectedCashAfter')::NUMERIC<>470000 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash return result invalid';
    END IF;
    SELECT private.calculate_cashier_session_expected_cash(
        v_company,v_session
    ) INTO v_expected;
    IF v_expected<>470000 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected Cash %, expected 470000',v_expected;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.expense_documents
        WHERE id=v_document AND status='SETTLED'
          AND actual_expense_amount=30000 AND returned_amount=20000
          AND outstanding_amount=0 AND settled_by=v_actor
          AND settled_at IS NOT NULL AND master_version=6
    ) OR NOT EXISTS (
        SELECT 1 FROM public.cash_in_documents
        WHERE company_id=v_company AND source_type='EXPENSE_RETURN'
          AND source_document_id=v_document AND amount=20000
    ) OR NOT EXISTS (
        SELECT 1 FROM public.cash_drawer_movements
        WHERE company_id=v_company AND source_table='expense_returns'
          AND direction='IN' AND movement_type='EXPENSE_RETURN'
          AND amount=20000 AND expected_cash_after=470000
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash return final coverage invalid';
    END IF;

    v_result:=public.return_expense_funds(
        v_document,5,20000,v_cash_method,v_session,NULL,
        '00000000-0000-0000-0000-000000072093'
    );
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
       OR (v_result->>'masterVersion')::BIGINT<>6 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash return retry not idempotent';
    END IF;
    SELECT count(*) INTO v_count FROM public.expense_returns
    WHERE document_id=v_document;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash return retry duplicated row';
    END IF;

    IF has_table_privilege(
        'authenticated','public.expense_settlement_requests','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.expense_settlements','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.expense_returns','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.cash_in_documents','INSERT,UPDATE,DELETE'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: settlement write boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: reviewed actual is append-only, Cash return reconciles drawer/outstanding, retry is idempotent, and additional request has zero cash effect.';
END
$test$;

ROLLBACK;
