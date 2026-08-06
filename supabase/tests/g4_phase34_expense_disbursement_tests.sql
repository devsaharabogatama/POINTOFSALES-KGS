-- G4 phase 34 behavior: approved Expense initial disbursement.
-- SAFETY: every fixture, event, and cash effect is rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID;
    v_company UUID:='00000000-0000-0000-0000-000000071001';
    v_store UUID:='00000000-0000-0000-0000-000000071011';
    v_terminal UUID:='00000000-0000-0000-0000-000000071021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000071025';
    v_session UUID:='00000000-0000-0000-0000-000000071031';
    v_category UUID:='00000000-0000-0000-0000-000000071041';
    v_settlement_category UUID;
    v_expense_account UUID;
    v_cash_method UUID;
    v_transfer_method UUID;
    v_cash_document UUID;
    v_transfer_document UUID;
    v_insufficient_document UUID;
    v_cash_key UUID:='00000000-0000-0000-0000-000000071091';
    v_transfer_key UUID:='00000000-0000-0000-0000-000000071092';
    v_failed_key UUID:='00000000-0000-0000-0000-000000071093';
    v_result JSONB;
    v_count BIGINT;
    v_expected NUMERIC;
    v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role='super_admin'::public.user_role
      AND NOT EXISTS (
          SELECT 1 FROM public.cashier_sessions existing_session
          WHERE existing_session.cashier_id=profile.id
            AND existing_session.status='OPEN'::public.session_status
      )
    ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(
        id,company_code,company_name,company_slug,status
    ) VALUES(
        v_company,'G71','G71 Disbursement Company',
        'g71-disbursement-company','ACTIVE'
    );
    INSERT INTO public.stores(
        id,company_id,store_code,store_name,status
    ) VALUES(v_store,v_company,'G71S','G71 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G71P','G71 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,is_sale_source
    ) VALUES(
        v_warehouse,v_company,'G71W','G71 Sales Warehouse','STORE',
        v_store,TRUE
    );

    SELECT category.id INTO v_settlement_category
    FROM public.transaction_categories category
    WHERE category.company_id=v_company
      AND category.system_key='EXPENSE_SETTLEMENT'
      AND category.is_active
    ORDER BY category.created_at,category.id LIMIT 1;
    IF v_settlement_category IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: Expense Settlement category missing';
    END IF;
    SELECT account.id INTO v_expense_account
    FROM public.chart_of_accounts account
    WHERE account.company_id=v_company
      AND account.system_function_key='EXPENSE'
      AND account.is_active AND account.is_postable
    ORDER BY account.account_code,account.id LIMIT 1;
    IF v_expense_account IS NULL THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: Expense account missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.transaction_categories category
        WHERE category.company_id=v_company
          AND category.system_key='EXPENSE_DISBURSEMENT'
          AND category.is_active
    ) OR EXISTS (
        SELECT 1
        FROM (VALUES
            ('OUTSTANDING_EXPENSE'),('CASH_DRAWER'),('BANK')
        ) req(function_key)
        WHERE NOT EXISTS (
            SELECT 1 FROM public.chart_of_accounts account
            WHERE account.company_id=v_company
              AND account.system_function_key=req.function_key
              AND account.is_active AND account.is_postable
        )
    ) THEN
        RAISE EXCEPTION
            'TEST_PRECONDITION_FAILED: disbursement category/accounts missing';
    END IF;

    SELECT method.id INTO v_cash_method
    FROM public.payment_methods method
    WHERE method.company_id=v_company
      AND method.method_type='CASH'
      AND method.settlement_route='CASH_DRAWER'
      AND method.is_active
    ORDER BY method.created_at,method.id LIMIT 1;
    IF v_cash_method IS NULL THEN
        INSERT INTO public.payment_methods(
            company_id,payment_method_code,payment_method_name,method_type,
            settlement_route,is_default,available_all_stores
        ) VALUES(
            v_company,'G71-CASH','G71 Cash','CASH','CASH_DRAWER',TRUE,TRUE
        ) RETURNING id INTO v_cash_method;
    END IF;
    SELECT method.id INTO v_transfer_method
    FROM public.payment_methods method
    WHERE method.company_id=v_company
      AND method.method_type='TRANSFER'
      AND method.settlement_route='DIRECT_BANK'
      AND method.is_active
    ORDER BY method.created_at,method.id LIMIT 1;
    IF v_transfer_method IS NULL THEN
        INSERT INTO public.payment_methods(
            company_id,payment_method_code,payment_method_name,method_type,
            settlement_route,available_all_stores,bank_account_function
        ) VALUES(
            v_company,'G71-TRANSFER','G71 Transfer','TRANSFER',
            'DIRECT_BANK',TRUE,'BANK'
        ) RETURNING id INTO v_transfer_method;
    END IF;

    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,updated_by
    ) VALUES(v_company,'expense_enabled',TRUE,v_actor);
    UPDATE public.expense_approval_policies
    SET approval_required=TRUE,updated_by=v_actor
    WHERE company_id=v_company AND store_id IS NULL;
    INSERT INTO public.expense_categories(
        id,company_id,category_code,category_name,transaction_category_id,
        expense_account_id,evidence_policy,approval_policy,is_system_default,
        created_by,updated_by
    ) VALUES(
        v_category,v_company,'G71-CATEGORY','G71 Operational',
        v_settlement_category,v_expense_account,'OPTIONAL','USE_DEFAULT',FALSE,
        v_actor,v_actor
    );
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,company_id,store_id,pos_id,status,
        sales_warehouse_id,opening_balance,opening_cash_actual,expected_cash
    ) VALUES(
        v_session,'G71-SESSION',v_actor,v_company,v_store,v_terminal,
        'OPEN'::public.session_status,v_warehouse,500000,500000,500000
    );

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE
    );
    PERFORM public.set_active_company_context(v_company,'G4_PHASE34_TEST');

    v_result:=public.save_expense_draft(
        NULL,NULL,v_store,v_session,v_category,'CASHIER',v_actor,
        'G71 Responsible',50000,v_cash_method,'G71 Recipient',
        'Cash operational expense',NULL,current_date+1,
        '00000000-0000-0000-0000-000000071081'
    );
    v_cash_document:=(v_result->>'documentId')::UUID;
    PERFORM public.submit_expense_request(v_cash_document,1);
    PERFORM public.review_expense_request(v_cash_document,2,TRUE,NULL);

    v_result:=public.disburse_expense(
        v_cash_document,3,v_session,NULL,v_cash_key
    );
    IF v_result->>'status'<>'DISBURSED'
       OR (v_result->>'amount')::NUMERIC<>50000
       OR (v_result->>'expectedCashAfter')::NUMERIC<>450000
       OR COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash disbursement result invalid';
    END IF;
    SELECT private.calculate_cashier_session_expected_cash(
        v_company,v_session
    ) INTO v_expected;
    IF v_expected<>450000 THEN
        RAISE EXCEPTION
            'TEST_FAILED: expected Cash %, expected 450000',v_expected;
    END IF;
    SELECT count(*) INTO v_count
    FROM public.expense_disbursements disbursement
    JOIN public.financial_events event
      ON event.company_id=disbursement.company_id
     AND event.id=disbursement.financial_event_id
    JOIN public.cash_drawer_movements movement
      ON movement.company_id=disbursement.company_id
     AND movement.source_table='expense_disbursements'
     AND movement.source_id=disbursement.id
    WHERE disbursement.document_id=v_cash_document
      AND disbursement.amount=50000
      AND disbursement.payment_method_type_snapshot='CASH'
      AND movement.direction='OUT'
      AND movement.movement_type='EXPENSE_DISBURSEMENT'
      AND movement.expected_cash_after=450000
      AND event.event_type='EXPENSE_DISBURSEMENT'::public.event_type
      AND event.status='HOLD'::public.event_status
      AND event.system_event_key='EXPENSE_DISBURSEMENT';
    IF v_count<>1 THEN
        RAISE EXCEPTION
            'TEST_FAILED: Cash disbursement final-effect coverage invalid';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.expense_documents document
        WHERE document.id=v_cash_document
          AND document.status='DISBURSED'
          AND document.disbursed_amount=50000
          AND document.outstanding_amount=50000
          AND document.master_version=4
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash Expense aggregate invalid';
    END IF;

    v_result:=public.disburse_expense(
        v_cash_document,3,v_session,NULL,v_cash_key
    );
    IF COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE
       OR (v_result->>'masterVersion')::BIGINT<>4 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash retry was not idempotent';
    END IF;
    SELECT count(*) INTO v_count
    FROM public.expense_disbursements
    WHERE document_id=v_cash_document;
    IF v_count<>1 THEN
        RAISE EXCEPTION 'TEST_FAILED: Cash retry duplicated disbursement';
    END IF;

    v_result:=public.save_expense_draft(
        NULL,NULL,v_store,NULL,v_category,'EXTERNAL',NULL,
        'G71 Transfer Recipient',75000,v_transfer_method,'G71 Vendor',
        'Transfer operational expense',NULL,current_date+1,
        '00000000-0000-0000-0000-000000071082'
    );
    v_transfer_document:=(v_result->>'documentId')::UUID;
    PERFORM public.submit_expense_request(v_transfer_document,1);
    PERFORM public.review_expense_request(v_transfer_document,2,TRUE,NULL);
    v_result:=public.disburse_expense(
        v_transfer_document,3,NULL,'https://example.invalid/transfer-proof',
        v_transfer_key
    );
    IF v_result->>'status'<>'DISBURSED'
       OR v_result->>'expectedCashAfter' IS NOT NULL THEN
        RAISE EXCEPTION 'TEST_FAILED: non-Cash disbursement result invalid';
    END IF;
    SELECT private.calculate_cashier_session_expected_cash(
        v_company,v_session
    ) INTO v_expected;
    IF v_expected<>450000 OR EXISTS (
        SELECT 1
        FROM public.expense_disbursements disbursement
        JOIN public.cash_drawer_movements movement
          ON movement.company_id=disbursement.company_id
         AND movement.source_table='expense_disbursements'
         AND movement.source_id=disbursement.id
        WHERE disbursement.document_id=v_transfer_document
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: non-Cash changed drawer';
    END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.disburse_expense(
            v_transfer_document,3,NULL,
            'https://example.invalid/transfer-proof',v_cash_key
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='EXPENSE_DISBURSEMENT_IDEMPOTENCY_CONFLICT' THEN
            v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: reused idempotency key accepted';
    END IF;

    v_result:=public.save_expense_draft(
        NULL,NULL,v_store,v_session,v_category,'CASHIER',v_actor,
        'G71 Responsible',500000,v_cash_method,NULL,
        'Insufficient drawer test',NULL,NULL,
        '00000000-0000-0000-0000-000000071083'
    );
    v_insufficient_document:=(v_result->>'documentId')::UUID;
    PERFORM public.submit_expense_request(v_insufficient_document,1);
    PERFORM public.review_expense_request(
        v_insufficient_document,2,TRUE,NULL
    );
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.disburse_expense(
            v_insufficient_document,3,v_session,NULL,v_failed_key
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='INSUFFICIENT_EXPECTED_CASH' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected OR EXISTS (
        SELECT 1 FROM public.expense_disbursements
        WHERE document_id=v_insufficient_document
    ) OR EXISTS (
        SELECT 1 FROM public.financial_events
        WHERE idempotency_key='EXPENSE_DISBURSEMENT|'||v_company::TEXT||'|'||
            v_failed_key::TEXT
    ) OR NOT EXISTS (
        SELECT 1 FROM public.expense_documents
        WHERE id=v_insufficient_document AND status='APPROVED'
          AND master_version=3 AND disbursed_amount=0
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: insufficient Cash was not atomically rejected';
    END IF;

    SELECT count(*) INTO v_count
    FROM public.expense_audit
    WHERE document_id IN (v_cash_document,v_transfer_document)
      AND entity_type='DISBURSEMENT' AND action='DISBURSE';
    IF v_count<>2 THEN
        RAISE EXCEPTION 'TEST_FAILED: disbursement audit incomplete';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.journal_entries journal
        JOIN public.financial_events event
          ON event.company_id=journal.company_id
         AND event.id=journal.financial_event_id
        WHERE event.source_table='expense_disbursements'
    ) THEN
        RAISE EXCEPTION 'TEST_FAILED: G6 journal boundary was bypassed';
    END IF;

    IF has_table_privilege(
        'authenticated','public.expense_disbursements','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.cash_drawer_movements','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.disburse_expense(uuid,bigint,uuid,text,uuid)','EXECUTE'
    ) OR has_function_privilege(
        'anon','public.disburse_expense(uuid,bigint,uuid,text,uuid)','EXECUTE'
    ) THEN
        RAISE EXCEPTION
            'TEST_FAILED: Expense disbursement privilege boundary invalid';
    END IF;

    RAISE NOTICE 'TEST PASSED: Cash and non-Cash Expense disbursement is approved-only, atomic, idempotent, drawer-safe, audited, and Finance-HOLD.';
END
$test$;

ROLLBACK;
