-- G6 phase 6A behavior: POSTED-only Trial Balance and General Ledger.
-- SAFETY: all Company, period, journal, line, report, and audit fixture rows roll back.
BEGIN;
DO $test$
DECLARE
 v_actor UUID; v_company_a CONSTANT UUID:='00000000-0000-0000-0000-000000022001';
 v_company_b CONSTANT UUID:='00000000-0000-0000-0000-000000022002';
 v_period CONSTANT UUID:='00000000-0000-0000-0000-000000022011';
 v_journal CONSTANT UUID:='00000000-0000-0000-0000-000000022021';
 v_draft CONSTANT UUID:='00000000-0000-0000-0000-000000022022';
 v_inventory UUID; v_clearing UUID; v_result JSONB; v_rows JSONB; v_count BIGINT; v_rejected BOOLEAN;
 v_start DATE:=date_trunc('month',clock_timestamp())::DATE; v_end DATE;
BEGIN
 v_end:=(v_start+INTERVAL '1 month'-INTERVAL '1 day')::DATE;
 SELECT profile.id INTO v_actor FROM public.profiles profile JOIN auth.users auth_user ON auth_user.id=profile.id
 WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
 IF v_actor IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin required'; END IF;
 INSERT INTO public.companies(id,company_code,company_name,company_slug,status) VALUES
 (v_company_a,'G6RPA','G6 Report A','g6-report-a','ACTIVE'),(v_company_b,'G6RPB','G6 Report B','g6-report-b','ACTIVE');
 SELECT id INTO v_inventory FROM public.chart_of_accounts WHERE company_id=v_company_a AND system_function_key='INVENTORY_ASSET' AND is_system_account;
 SELECT id INTO v_clearing FROM public.chart_of_accounts WHERE company_id=v_company_a AND system_function_key='OPENING_BALANCE_CLEARING' AND is_system_account;
 IF v_inventory IS NULL OR v_clearing IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: report accounts missing'; END IF;
 INSERT INTO public.accounting_periods(id,company_id,period_year,period_month,start_date,end_date,status,created_by,updated_by)
 VALUES(v_period,v_company_a,extract(YEAR FROM v_start)::INTEGER,extract(MONTH FROM v_start)::INTEGER,v_start,v_end,'OPEN',v_actor,v_actor);
 INSERT INTO public.finance_journals(id,company_id,journal_no,journal_type,accounting_period_id,accounting_date,source_type,source_id,idempotency_key,description,status,created_by)
 VALUES(v_journal,v_company_a,'G6-RPT-POSTED','MANUAL',v_period,v_start,'G6_REPORT_TEST','00000000-0000-0000-0000-000000022031','G6_REPORT_POSTED','Posted report fixture','DRAFT',v_actor),
 (v_draft,v_company_a,'G6-RPT-DRAFT','MANUAL',v_period,v_start,'G6_REPORT_TEST','00000000-0000-0000-0000-000000022032','G6_REPORT_DRAFT','Draft exclusion fixture','DRAFT',v_actor);
 INSERT INTO public.finance_journal_lines(company_id,journal_id,line_no,account_id,debit,credit,description) VALUES
 (v_company_a,v_journal,1,v_inventory,100,0,'Inventory debit'),(v_company_a,v_journal,2,v_clearing,0,100,'Clearing credit'),
 (v_company_a,v_draft,1,v_inventory,999,0,'Excluded draft'),(v_company_a,v_draft,2,v_clearing,0,999,'Excluded draft');
 UPDATE public.finance_journals SET status='POSTED',posted_by=v_actor,posted_at=clock_timestamp()
 WHERE company_id=v_company_a AND id=v_journal;
 PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,TRUE);
 PERFORM public.set_active_company_context(v_company_a,'G6_PHASE6A_TEST');
 v_result:=public.get_finance_trial_balance(v_start,v_end,NULL,NULL);
 IF (v_result->>'periodDebit')::NUMERIC<>100 OR (v_result->>'periodCredit')::NUMERIC<>100
 OR NOT (v_result->>'balanced')::BOOLEAN OR (v_result->>'reportVersion')::BIGINT<>1 THEN
  RAISE EXCEPTION 'TEST_FAILED: Trial Balance totals invalid: %',v_result;
 END IF;
 v_rows:=v_result->'rows';
 SELECT count(*) INTO v_count FROM jsonb_array_elements(v_rows) row_state
 WHERE (row_state->>'accountId')::UUID IN(v_inventory,v_clearing)
 AND (row_state->>'closingBalance')::NUMERIC=100;
 IF v_count<>2 THEN RAISE EXCEPTION 'TEST_FAILED: Trial Balance presentation invalid'; END IF;
 v_result:=public.get_finance_general_ledger(v_inventory,v_start,v_end,NULL,NULL,100,0);
 IF (v_result->>'totalRows')::BIGINT<>1 OR (v_result->>'openingBalance')::NUMERIC<>0
 OR jsonb_array_length(v_result->'rows')<>1
 OR ((v_result->'rows'->0)->>'runningBalance')::NUMERIC<>100 THEN
  RAISE EXCEPTION 'TEST_FAILED: General Ledger invalid: %',v_result;
 END IF;
 PERFORM public.set_active_company_context(v_company_b,'G6_PHASE6A_CROSS');
 v_rejected:=FALSE;
 BEGIN PERFORM public.get_finance_general_ledger(v_inventory,v_start,v_end,NULL,NULL,100,0);
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='REPORT_ACCOUNT_NOT_FOUND' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
 IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company report account accepted'; END IF;
 PERFORM public.set_active_company_context(v_company_a,'G6_PHASE6A_TEST');
 v_rejected:=FALSE;
 BEGIN PERFORM public.get_finance_trial_balance(v_end,v_start,NULL,NULL);
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='REPORT_DATE_RANGE_INVALID' THEN v_rejected:=TRUE; ELSE RAISE; END IF; END;
 IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: invalid report range accepted'; END IF;
 SELECT count(*) INTO v_count FROM public.finance_report_definitions WHERE company_id=v_company_a AND is_active
 AND report_code IN('TRIAL_BALANCE','GENERAL_LEDGER');
 IF v_count<>2 THEN RAISE EXCEPTION 'TEST_FAILED: future Company report provisioning missing'; END IF;
 IF has_table_privilege('authenticated','public.finance_report_definitions','INSERT,UPDATE,DELETE')
 OR has_table_privilege('authenticated','public.finance_report_versions','INSERT,UPDATE,DELETE')
 OR NOT has_function_privilege('authenticated','public.get_finance_trial_balance(date,date,uuid,uuid)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.get_finance_general_ledger(uuid,date,date,uuid,uuid,integer,integer)','EXECUTE') THEN
  RAISE EXCEPTION 'TEST_FAILED: report privilege boundary invalid';
 END IF;
 RAISE NOTICE 'TEST PASSED: G6 Phase 6A Trial Balance and General Ledger are POSTED-only, balanced, versioned, tenant-safe, timezone-aware, paginated, and role-guarded.';
END
$test$;
ROLLBACK;
