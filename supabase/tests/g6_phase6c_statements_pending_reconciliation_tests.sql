-- G6 phase 6C behavior: POSTED statements, pending separation, reconciliation.
-- SAFETY: every synthetic Company/journal/event/reconciliation row rolls back.

BEGIN;
DO $test$
DECLARE
    v_actor UUID;
    v_company CONSTANT UUID:='00000000-0000-0000-0000-000000023001';
    v_company_b CONSTANT UUID:='00000000-0000-0000-0000-000000023002';
    v_period CONSTANT UUID:='00000000-0000-0000-0000-000000023011';
    v_opening CONSTANT UUID:='00000000-0000-0000-0000-000000023021';
    v_sale CONSTANT UUID:='00000000-0000-0000-0000-000000023022';
    v_inventory UUID; v_opening_equity UUID; v_cash UUID; v_revenue UUID; v_cogs UUID;
    v_category UUID; v_report_definition UUID; v_report_version UUID;
    v_reconciliation UUID:='00000000-0000-0000-0000-000000023041';
    v_today DATE; v_month_start DATE; v_month_end DATE;
    v_result JSONB; v_count BIGINT; v_rejected BOOLEAN;
BEGIN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
    IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required'; END IF;

    INSERT INTO public.companies(id,company_code,company_name,company_slug,status)
    VALUES(v_company,'G6C-A','G6 Phase 6C A','g6-phase6c-a','ACTIVE'),
          (v_company_b,'G6C-B','G6 Phase 6C B','g6-phase6c-b','ACTIVE');
    SELECT (clock_timestamp() AT TIME ZONE company.timezone)::DATE INTO v_today
    FROM public.companies company WHERE company.id=v_company;
    v_month_start:=date_trunc('month',v_today)::DATE;
    v_month_end:=(v_month_start+INTERVAL '1 month'-INTERVAL '1 day')::DATE;
    SELECT id INTO v_inventory FROM public.chart_of_accounts
      WHERE company_id=v_company AND system_function_key='INVENTORY_ASSET' AND is_system_account;
    SELECT id INTO v_opening_equity FROM public.chart_of_accounts
      WHERE company_id=v_company AND system_function_key='OPENING_BALANCE_CLEARING' AND is_system_account;
    SELECT id INTO v_cash FROM public.chart_of_accounts
      WHERE company_id=v_company AND system_function_key='CASH_DRAWER' AND is_system_account;
    SELECT id INTO v_revenue FROM public.chart_of_accounts
      WHERE company_id=v_company AND system_function_key='SALES_REVENUE' AND is_system_account;
    SELECT id INTO v_cogs FROM public.chart_of_accounts
      WHERE company_id=v_company AND system_function_key='COGS' AND is_system_account;
    IF v_inventory IS NULL OR v_opening_equity IS NULL OR v_cash IS NULL
       OR v_revenue IS NULL OR v_cogs IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: canonical statement accounts missing';
    END IF;
    INSERT INTO public.accounting_periods(
        id,company_id,period_year,period_month,start_date,end_date,status,created_by,updated_by
    ) VALUES(v_period,v_company,extract(YEAR FROM v_today)::INTEGER,
        extract(MONTH FROM v_today)::INTEGER,v_month_start,v_month_end,'OPEN',v_actor,v_actor);

    INSERT INTO public.finance_journals(
        id,company_id,journal_no,journal_type,accounting_period_id,accounting_date,
        source_type,source_id,idempotency_key,description,status,created_by
    ) VALUES
        (v_opening,v_company,'G6C-OPEN','MANUAL',v_period,v_today,'G6C_TEST',
         '00000000-0000-0000-0000-000000023031','G6C_OPEN','Opening','DRAFT',v_actor),
        (v_sale,v_company,'G6C-SALE','MANUAL',v_period,v_today,'G6C_TEST',
         '00000000-0000-0000-0000-000000023032','G6C_SALE','Sale fixture','DRAFT',v_actor);
    INSERT INTO public.finance_journal_lines(
        company_id,journal_id,line_no,account_id,debit,credit,description
    ) VALUES
        (v_company,v_opening,1,v_inventory,100,0,'Inventory'),
        (v_company,v_opening,2,v_opening_equity,0,100,'Opening equity'),
        (v_company,v_sale,1,v_cash,200,0,'Cash'),
        (v_company,v_sale,2,v_revenue,0,200,'Revenue'),
        (v_company,v_sale,3,v_cogs,80,0,'COGS'),
        (v_company,v_sale,4,v_inventory,0,80,'Inventory out');
    UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor
    WHERE company_id=v_company AND id IN(v_opening,v_sale);

    SELECT id INTO v_category FROM public.transaction_categories
    WHERE company_id=v_company AND system_key='SALE_POSTED' AND is_active
    ORDER BY is_system_default DESC,id LIMIT 1;
    IF v_category IS NULL THEN
        RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: SALE_POSTED category missing';
    END IF;
    INSERT INTO public.financial_events(
        event_code,event_type,source_table,source_id,event_date,event_version,
        idempotency_key,amounts,status,error_message,created_by,company_id,
        system_event_key,transaction_category_id
    ) VALUES(
        'G6C-PENDING-SALE','SALE_POSTED'::public.event_type,'g6_phase6c_test',
        '00000000-0000-0000-0000-000000023033',clock_timestamp(),1,
        'G6C_PENDING_SALE',jsonb_build_object('grandTotal',123),
        'HOLD'::public.event_status,'TEST_PENDING',v_actor,v_company,
        'SALE_POSTED',v_category
    );

    PERFORM set_config('request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE);
    PERFORM public.set_active_company_context(v_company,'G6_PHASE6C_TEST');

    v_result:=public.get_finance_income_statement(v_month_start,v_today,NULL,NULL);
    IF (v_result->>'netRevenue')::NUMERIC<>200
       OR (v_result->>'cogs')::NUMERIC<>80
       OR (v_result->>'profitBeforeTax')::NUMERIC<>120
       OR NOT (v_result->>'postedOnly')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: income statement invalid: %',v_result;
    END IF;
    v_result:=public.get_finance_balance_sheet(v_today,NULL,NULL);
    IF (v_result->>'assets')::NUMERIC<>220
       OR (v_result->>'equity')::NUMERIC<>100
       OR (v_result->>'currentResult')::NUMERIC<>120
       OR NOT (v_result->>'balanced')::BOOLEAN THEN
        RAISE EXCEPTION 'TEST_FAILED: balance sheet invalid: %',v_result;
    END IF;
    v_result:=public.get_finance_pending_analysis(v_month_start,v_today,100,0);
    IF (v_result->>'financialStatementIncluded')::BOOLEAN
       OR v_result->>'label'<>'BELUM MASUK LAPORAN KEUANGAN'
       OR (v_result->>'totalRows')::BIGINT<>1
       OR ((v_result->'rows'->0)->>'potentialAmount')::NUMERIC<>123 THEN
        RAISE EXCEPTION 'TEST_FAILED: pending analysis invalid: %',v_result;
    END IF;
    v_result:=public.get_finance_reconciliation_summary(v_today);
    IF v_result->>'valuationMode'<>'CURRENT_ONLY'
       OR (v_result->>'autoAdjustment')::BOOLEAN
       OR jsonb_array_length(v_result->'rows')<>4
       OR (v_result->'rows'->3)->>'status'<>'DEFERRED' THEN
        RAISE EXCEPTION 'TEST_FAILED: reconciliation summary invalid: %',v_result;
    END IF;

    SELECT definition.id,version.id INTO v_report_definition,v_report_version
    FROM public.finance_report_definitions definition
    JOIN public.finance_report_versions version
      ON version.company_id=definition.company_id
     AND version.report_definition_id=definition.id
     AND version.status='ACTIVE' AND version.effective_to IS NULL
    WHERE definition.company_id=v_company
      AND definition.report_code='RECONCILIATION_SUMMARY';
    INSERT INTO public.finance_reconciliation_documents(
        id,company_id,reconciliation_no,reconciliation_type,as_of_date,
        report_definition_id,report_version_id,status,subledger_balance,
        ledger_balance,difference,created_by
    ) VALUES(v_reconciliation,v_company,'G6C-REC','STOCK_FIFO_GL',v_today,
        v_report_definition,v_report_version,'DRAFT',5,3,2,v_actor);
    INSERT INTO public.finance_reconciliation_allocations(
        company_id,reconciliation_document_id,line_no,source_type,source_id,
        allocation_status,subledger_amount,ledger_amount,difference,created_by
    ) VALUES(v_company,v_reconciliation,1,'G6C_TEST',
        '00000000-0000-0000-0000-000000023034','PARTIAL',5,3,2,v_actor);
    UPDATE public.finance_reconciliation_documents SET
        status='FINALIZED',finalized_by=v_actor
    WHERE company_id=v_company AND id=v_reconciliation;
    SELECT count(*) INTO v_count FROM public.finance_reconciliation_audit
    WHERE company_id=v_company AND reconciliation_document_id=v_reconciliation;
    IF v_count<>3 THEN RAISE EXCEPTION 'TEST_FAILED: reconciliation audit incomplete'; END IF;
    v_rejected:=FALSE;
    BEGIN
        UPDATE public.finance_reconciliation_documents SET notes='forbidden'
        WHERE company_id=v_company AND id=v_reconciliation;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='FINAL_RECONCILIATION_IMMUTABLE' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: finalized reconciliation mutable'; END IF;

    PERFORM public.set_active_company_context(v_company_b,'G6_PHASE6C_CROSS');
    v_result:=public.get_finance_income_statement(v_month_start,v_today,NULL,NULL);
    IF (v_result->>'netRevenue')::NUMERIC<>0 THEN
        RAISE EXCEPTION 'TEST_FAILED: cross-Company statement leaked';
    END IF;
    PERFORM public.set_active_company_context(v_company,'G6_PHASE6C_TEST');
    v_rejected:=FALSE;
    BEGIN
        PERFORM public.get_finance_reconciliation_summary(v_today-1);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM='HISTORICAL_SUBLEDGER_SNAPSHOT_UNAVAILABLE' THEN v_rejected:=TRUE;
        ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: historical current-state reconciliation accepted'; END IF;

    IF has_table_privilege('authenticated',
        'public.finance_reconciliation_documents','INSERT,UPDATE,DELETE')
       OR has_function_privilege('anon',
        'public.get_finance_income_statement(date,date,uuid,uuid)','EXECUTE')
       OR NOT has_function_privilege('authenticated',
        'public.get_finance_pending_analysis(date,date,integer,integer)','EXECUTE') THEN
        RAISE EXCEPTION 'TEST_FAILED: Phase 6C privilege boundary invalid';
    END IF;
    SELECT count(*) INTO v_count FROM public.finance_report_definitions
    WHERE company_id=v_company AND is_active;
    IF v_count<>6 THEN RAISE EXCEPTION 'TEST_FAILED: expected six report definitions'; END IF;
    RAISE NOTICE 'TEST PASSED: G6 Phase 6C statements are POSTED-only, pending exposure is separated, reconciliation is current-only/no-adjustment, versioned, immutable, tenant-safe, and role-guarded.';
END
$test$;
ROLLBACK;
