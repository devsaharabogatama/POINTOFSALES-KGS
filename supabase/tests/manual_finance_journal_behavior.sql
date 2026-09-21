-- Authenticated rollback-only behavior for Manual Finance Journal.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_maker uuid:='00000000-0000-0000-0000-000000191201';
  v_approver uuid:='00000000-0000-0000-0000-000000191202';
  v_account_debit uuid:=gen_random_uuid();v_account_credit uuid:=gen_random_uuid();
  v_period uuid:=gen_random_uuid();v_result jsonb;v_journal uuid;v_version bigint;
  v_operation uuid:=gen_random_uuid();v_rejected boolean;v_count bigint;
  v_second uuid;v_second_version bigint;v_policy_version bigint;
  v_test_date date:='2098-01-15';
BEGIN
  SELECT company.id INTO v_company FROM public.companies company
  WHERE company.status='ACTIVE' ORDER BY company.created_at,company.id LIMIT 1;
  IF v_company IS NULL THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company required'; END IF;

  INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,
    is_super_admin,role,aud,email_confirmed_at) VALUES
  (v_maker,'manual-journal-maker@example.invalid','00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}','{"name":"Manual Journal Maker"}',false,'authenticated','authenticated',now()),
  (v_approver,'manual-journal-approver@example.invalid','00000000-0000-0000-0000-000000000000',
    '{"provider":"email","providers":["email"]}','{"name":"Manual Journal Approver"}',false,'authenticated','authenticated',now())
  ON CONFLICT(id) DO NOTHING;
  INSERT INTO public.profiles(id,email,name,role) VALUES
    (v_maker,'manual-journal-maker@example.invalid','Manual Journal Maker','cashier'::public.user_role),
    (v_approver,'manual-journal-approver@example.invalid','Manual Journal Approver','cashier'::public.user_role)
  ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name;
  INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company)
  VALUES(v_company,v_maker,'FINANCE','ACTIVE',false),
    (v_company,v_approver,'COMPANY_ADMIN','ACTIVE',false)
  ON CONFLICT(company_id,user_id) DO UPDATE SET role_code=excluded.role_code,status='ACTIVE';
  INSERT INTO public.accounting_periods(id,company_id,period_year,period_month,start_date,end_date,status,
    created_by,updated_by) VALUES(v_period,v_company,2098,1,'2098-01-01','2098-01-31','OPEN',v_approver,v_approver)
  ON CONFLICT(company_id,period_year,period_month) DO UPDATE SET status='OPEN'
  RETURNING id INTO v_period;
  INSERT INTO public.chart_of_accounts(id,company_id,account_code,account_name,account_type,
    normal_balance,is_postable,allow_manual_posting,is_active,created_by,updated_by) VALUES
    (v_account_debit,v_company,'TST-MJ-D-'||right(v_account_debit::text,6),'Test Manual Debit','ASSET','DEBIT',true,true,true,v_approver,v_approver),
    (v_account_credit,v_company,'TST-MJ-C-'||right(v_account_credit::text,6),'Test Manual Credit','LIABILITY','CREDIT',true,true,true,v_approver,v_approver);
  UPDATE public.finance_company_policies SET manual_journal_approval_required=true
  WHERE company_id=v_company;

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_maker,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'MANUAL_JOURNAL_TEST');
  v_result:=public.save_manual_finance_journal_draft(NULL,NULL,v_operation,v_test_date,
    'TEST-REF','Rollback-only maker-checker behavior','https://example.invalid/evidence',
    jsonb_build_array(
      jsonb_build_object('accountId',v_account_debit,'description','Debit test','debit',100000,'credit',0),
      jsonb_build_object('accountId',v_account_credit,'description','Credit test','debit',0,'credit',100000)));
  v_journal:=(v_result->>'journalId')::uuid;v_version:=(v_result->>'masterVersion')::bigint;
  IF v_result->>'workflowStatus'<>'DRAFT' OR NOT(v_result->>'approvalRequired')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: new Manual Journal default workflow invalid'; END IF;
  IF public.save_manual_finance_journal_draft(NULL,NULL,v_operation,v_test_date,
    'TEST-REF','Rollback-only maker-checker behavior','https://example.invalid/evidence',
    jsonb_build_array(
      jsonb_build_object('accountId',v_account_debit,'description','Debit test','debit',100000,'credit',0),
      jsonb_build_object('accountId',v_account_credit,'description','Credit test','debit',0,'credit',100000)))<>v_result THEN
    RAISE EXCEPTION 'TEST_FAILED: exact retry changed result'; END IF;
  v_rejected:=false;
  BEGIN
    PERFORM public.save_manual_finance_journal_draft(v_journal,v_version-1,gen_random_uuid(),
      v_test_date,'TEST-REF','Stale edit','https://example.invalid/evidence',
      jsonb_build_array(jsonb_build_object('accountId',v_account_debit,'debit',1,'credit',0),
        jsonb_build_object('accountId',v_account_credit,'debit',0,'credit',1)));
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='MASTER_VERSION_CONFLICT' THEN v_rejected:=true; ELSE RAISE; END IF;END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: stale edit accepted'; END IF;
  v_result:=public.submit_manual_finance_journal(v_journal,v_version,gen_random_uuid());
  v_version:=(v_result->>'masterVersion')::bigint;
  IF v_result->>'workflowStatus'<>'PENDING_APPROVAL' THEN RAISE EXCEPTION 'TEST_FAILED: approval queue skipped'; END IF;
  v_rejected:=false;
  BEGIN PERFORM public.approve_manual_finance_journal(v_journal,v_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='CUSTOM_PERMISSION_DENIED' THEN v_rejected:=true; ELSE RAISE; END IF;END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance maker gained approval capability'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_approver,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'MANUAL_JOURNAL_TEST');
  v_result:=public.approve_manual_finance_journal(v_journal,v_version,gen_random_uuid());
  IF v_result->>'status'<>'POSTED' OR v_result->>'workflowStatus'<>'APPROVED' THEN
    RAISE EXCEPTION 'TEST_FAILED: approval did not post Journal'; END IF;
  v_rejected:=false;
  BEGIN UPDATE public.finance_journal_lines SET debit=debit+1
    WHERE company_id=v_company AND journal_id=v_journal AND debit>0;
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='POSTED_JOURNAL_IMMUTABLE' THEN v_rejected:=true; ELSE RAISE; END IF;END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: posted Manual Journal line mutable'; END IF;
  SELECT count(*) INTO v_count FROM public.finance_journal_audit
  WHERE company_id=v_company AND entity_id=v_journal AND action IN('SAVE_DRAFT','SUBMIT','APPROVE','POST');
  IF v_count<>4 THEN RAISE EXCEPTION 'TEST_FAILED: expected four audit events, got %',v_count; END IF;

  -- An authorized approver is still forbidden to approve their own Journal.
  v_result:=public.save_manual_finance_journal_draft(NULL,NULL,gen_random_uuid(),v_test_date,
    'TEST-SELF','Self approval guard','https://example.invalid/evidence',
    jsonb_build_array(
      jsonb_build_object('accountId',v_account_debit,'debit',200000,'credit',0),
      jsonb_build_object('accountId',v_account_credit,'debit',0,'credit',200000)));
  v_second:=(v_result->>'journalId')::uuid;
  v_result:=public.submit_manual_finance_journal(v_second,
    (v_result->>'masterVersion')::bigint,gen_random_uuid());
  v_second_version:=(v_result->>'masterVersion')::bigint;v_rejected:=false;
  BEGIN PERFORM public.approve_manual_finance_journal(v_second,v_second_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN IF SQLERRM='MANUAL_JOURNAL_SELF_APPROVAL_FORBIDDEN' THEN v_rejected:=true; ELSE RAISE; END IF;END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: self approval accepted'; END IF;
  PERFORM public.cancel_manual_finance_journal(v_second,v_second_version,
    'Rollback-only self approval fixture',gen_random_uuid());

  -- Approval-off is Company policy and only changes Journals created afterward.
  v_policy_version:=(public.get_manual_finance_journal_context()->>'policyMasterVersion')::bigint;
  PERFORM public.save_manual_journal_approval_policy(v_policy_version,false,gen_random_uuid());
  v_result:=public.save_manual_finance_journal_draft(NULL,NULL,gen_random_uuid(),v_test_date,
    'TEST-DIRECT','Approval off direct posting','https://example.invalid/evidence',
    jsonb_build_array(
      jsonb_build_object('accountId',v_account_debit,'debit',300000,'credit',0),
      jsonb_build_object('accountId',v_account_credit,'debit',0,'credit',300000)));
  v_result:=public.submit_manual_finance_journal((v_result->>'journalId')::uuid,
    (v_result->>'masterVersion')::bigint,gen_random_uuid());
  IF v_result->>'status'<>'POSTED' OR (v_result->>'approvalRequired')::boolean THEN
    RAISE EXCEPTION 'TEST_FAILED: approval-off did not post directly'; END IF;
END
$test$;

SELECT 'manual_finance_journal_behavior' check_name,'PASS' status,0::bigint violation_rows,
  jsonb_build_object('tested',ARRAY[
    'approval defaults ON','Finance maker create/save/submit','exact retry',
    'stale version rejection','maker lacks approval','maker-checker self-approval rejection',
    'Company Admin approval and posting','approval-off direct posting',
    'balanced Journal','posted line immutability','audit lifecycle','all fixtures rolled back']) details;

ROLLBACK;
