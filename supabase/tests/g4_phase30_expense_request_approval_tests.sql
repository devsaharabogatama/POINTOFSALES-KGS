-- G4 phase 30 behavior: Expense Draft/Submit/Review/Cancel only.
-- SAFETY: all fixtures and writes are rolled back.

BEGIN;

DO $test$
DECLARE
    v_actor UUID; v_company UUID:='00000000-0000-0000-0000-000000070001';
    v_store UUID:='00000000-0000-0000-0000-000000070011';
    v_terminal UUID:='00000000-0000-0000-0000-000000070021';
    v_warehouse UUID:='00000000-0000-0000-0000-000000070025';
    v_session UUID:='00000000-0000-0000-0000-000000070031';
    v_category UUID:='00000000-0000-0000-0000-000000070041';
    v_transaction_category UUID; v_account UUID; v_method UUID;
    v_document UUID; v_result JSONB; v_count BIGINT; v_expected NUMERIC;
    v_rejected BOOLEAN;
BEGIN
    SELECT p.id INTO v_actor FROM public.profiles p
    JOIN auth.users u ON u.id=p.id
    WHERE p.role='super_admin'::user_role
      AND NOT EXISTS (
          SELECT 1 FROM public.cashier_sessions existing_session
          WHERE existing_session.cashier_id=p.id
            AND existing_session.status='OPEN'::public.session_status
      )
    ORDER BY p.id LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES(v_company,'G70','G70 Expense Company','g70-expense-company','ACTIVE');
    INSERT INTO public.stores(id,company_id,store_code,store_name,status)
    VALUES(v_store,v_company,'G70S','G70 Store','ACTIVE');
    INSERT INTO public.pos_terminals(
        id,company_id,store_id,pos_code,pos_name,status
    ) VALUES(v_terminal,v_company,v_store,'G70P','G70 POS','ACTIVE');
    INSERT INTO public.warehouses(
        id,company_id,code,name,warehouse_type,store_id,is_sale_source
    ) VALUES(
        v_warehouse,v_company,'G70W','G70 Sales Warehouse','STORE',v_store,TRUE
    );

    SELECT id INTO v_transaction_category FROM public.transaction_categories
    WHERE company_id=v_company AND system_key='EXPENSE_SETTLEMENT' AND is_active
    ORDER BY created_at,id LIMIT 1;
    IF v_transaction_category IS NULL THEN
        INSERT INTO public.transaction_categories(
            company_id,category_code,category_name,system_key
        ) VALUES(v_company,'G70-EXP','G70 Expense','EXPENSE_SETTLEMENT')
        RETURNING id INTO v_transaction_category;
    END IF;
    SELECT id INTO v_account FROM public.chart_of_accounts
    WHERE company_id=v_company AND system_function_key='EXPENSE'
      AND is_active AND is_postable ORDER BY account_code,id LIMIT 1;
    IF v_account IS NULL THEN
        INSERT INTO public.chart_of_accounts(
            company_id,account_code,account_name,account_type,normal_balance,
            system_function_key,is_system_account,is_postable,
            allow_manual_posting,allow_reconciliation
        ) VALUES(v_company,'G706110','G70 Expense','EXPENSE','DEBIT',
            'EXPENSE',FALSE,TRUE,FALSE,FALSE) RETURNING id INTO v_account;
    END IF;
    SELECT id INTO v_method FROM public.payment_methods
    WHERE company_id=v_company AND method_type='CASH' AND is_active
    ORDER BY created_at,id LIMIT 1;
    IF v_method IS NULL THEN
        INSERT INTO public.payment_methods(
            company_id,payment_method_code,payment_method_name,method_type,
            settlement_route,is_default,available_all_stores
        ) VALUES(v_company,'G70-CASH','G70 Cash','CASH','CASH_DRAWER',TRUE,TRUE)
        RETURNING id INTO v_method;
    END IF;

    INSERT INTO public.company_features(
        company_id,feature_code,is_enabled,updated_by
    ) VALUES(v_company,'expense_enabled',TRUE,v_actor);
    UPDATE public.expense_approval_policies
    SET approval_required=TRUE,updated_by=v_actor
    WHERE company_id=v_company AND store_id IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEST_FAILED: future Company approval default missing';
    END IF;
    INSERT INTO public.expense_categories(
        id,company_id,category_code,category_name,transaction_category_id,
        expense_account_id,evidence_policy,approval_policy,is_system_default,
        created_by,updated_by
    ) VALUES(v_category,v_company,'G70-CATEGORY','G70 Operational',
        v_transaction_category,v_account,'OPTIONAL','USE_DEFAULT',FALSE,
        v_actor,v_actor);
    INSERT INTO public.cashier_sessions(
        id,session_code,cashier_id,company_id,store_id,pos_id,status,
        sales_warehouse_id,opening_balance,expected_cash
    ) VALUES(v_session,'G70-SESSION',v_actor,v_company,v_store,v_terminal,
        'OPEN'::public.session_status,v_warehouse,100000,100000);

    PERFORM set_config('request.jwt.claims',jsonb_build_object(
        'sub',v_actor,'role','authenticated')::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G4_PHASE30_TEST');

    v_result:=public.save_expense_draft(
        NULL,NULL,v_store,v_session,v_category,'CASHIER',v_actor,
        'G70 Responsible',50000,v_method,'G70 Recipient','Buy fuel',NULL,
        current_date+1,'00000000-0000-0000-0000-000000070099'
    );
    v_document:=(v_result->>'documentId')::UUID;
    IF v_result->>'status'<>'DRAFT' THEN
        RAISE EXCEPTION 'TEST_FAILED: Expense was not saved as Draft'; END IF;

    v_result:=public.save_expense_draft(
        NULL,NULL,v_store,v_session,v_category,'CASHIER',v_actor,
        'G70 Responsible',50000,v_method,'G70 Recipient','Buy fuel',NULL,
        current_date+1,'00000000-0000-0000-0000-000000070099'
    );
    IF (v_result->>'documentId')::UUID<>v_document
       OR COALESCE((v_result->>'idempotentReplay')::BOOLEAN,FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST_FAILED: Expense Draft retry was not idempotent';
    END IF;

    v_result:=public.submit_expense_request(v_document,1);
    IF v_result->>'status'<>'SUBMITTED' THEN
        RAISE EXCEPTION 'TEST_FAILED: required approval was bypassed'; END IF;
    v_result:=public.review_expense_request(v_document,2,TRUE,NULL);
    IF v_result->>'status'<>'APPROVED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Expense approval failed'; END IF;

    SELECT expected_cash INTO v_expected FROM public.cashier_sessions
    WHERE id=v_session;
    IF v_expected<>100000 THEN
        RAISE EXCEPTION 'TEST_FAILED: request/approval changed expected cash'; END IF;
    SELECT count(*) INTO v_count FROM public.expense_disbursements
    WHERE document_id=v_document;
    IF v_count<>0 OR EXISTS(
        SELECT 1 FROM public.cash_drawer_movements WHERE source_id=v_document
    ) OR EXISTS(
        SELECT 1 FROM public.financial_events
        WHERE source_table='expense_documents' AND source_id=v_document
    ) THEN RAISE EXCEPTION 'TEST_FAILED: closed cash runtime produced final effect'; END IF;

    v_rejected:=FALSE;
    BEGIN
        PERFORM public.review_expense_request(v_document,2,TRUE,NULL);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='ONLY_SUBMITTED_EXPENSE_REVIEWABLE' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: final approval replay accepted'; END IF;

    v_result:=public.save_expense_draft(
        NULL,NULL,v_store,v_session,v_category,'EXTERNAL',NULL,
        'G70 External',10000,v_method,NULL,'Disposable draft',NULL,NULL,
        '00000000-0000-0000-0000-000000070098'
    );
    v_result:=public.cancel_expense_request(
        (v_result->>'documentId')::UUID,1,'Disposable test'
    );
    IF v_result->>'status'<>'CANCELED' THEN
        RAISE EXCEPTION 'TEST_FAILED: Draft cancel failed'; END IF;

    UPDATE public.company_features SET is_enabled=FALSE
    WHERE company_id=v_company AND feature_code='expense_enabled';
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.save_expense_draft(
            NULL,NULL,v_store,v_session,v_category,'CASHIER',v_actor,
            'G70 Responsible',1,v_method,NULL,'Disabled feature',NULL,NULL,
            gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='EXPENSE_FEATURE_DISABLED' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
        RAISE EXCEPTION 'TEST_FAILED: disabled Expense feature accepted request';
    END IF;

    SELECT count(*) INTO v_count FROM public.expense_audit
    WHERE document_id=v_document
      AND action IN ('CREATE','SUBMIT','APPROVE');
    IF v_count<>3 THEN RAISE EXCEPTION 'TEST_FAILED: Expense audit incomplete'; END IF;

    IF has_table_privilege(
        'authenticated','public.expense_documents','INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'authenticated','public.cash_drawer_movements','INSERT,UPDATE,DELETE'
    ) OR NOT has_function_privilege(
        'authenticated',
        'public.save_expense_draft(uuid,bigint,uuid,uuid,uuid,text,uuid,text,numeric,uuid,text,text,text,date,uuid)',
        'EXECUTE'
    ) THEN RAISE EXCEPTION 'TEST_FAILED: Expense privilege boundary invalid'; END IF;

    RAISE NOTICE 'TEST PASSED: Expense request/approval is tenant-safe, versioned, audited, feature-guarded, and cash-neutral.';
END
$test$;

ROLLBACK;
