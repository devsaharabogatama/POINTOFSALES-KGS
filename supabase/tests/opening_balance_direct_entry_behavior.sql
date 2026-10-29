-- Rollback-only behavior for migration 20261029100000.
BEGIN;

DO $test$
DECLARE
  v_company uuid;v_other uuid;v_finance constant uuid:='00000000-0000-0000-0000-000000291091';
  v_admin constant uuid:='00000000-0000-0000-0000-000000291092';
  v_customer uuid;v_supplier uuid;v_ar uuid;v_ap uuid;v_gl uuid;
  v_result jsonb;v_document uuid;v_version bigint;v_journal uuid;v_rejected boolean:=false;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations WHERE version='20261029100000')<>1 THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: installed Opening Balance migration required';
  END IF;
  SELECT id INTO v_company FROM public.companies WHERE company_code='KGFF' AND status='ACTIVE';
  SELECT id INTO v_other FROM public.companies WHERE id<>v_company AND status='ACTIVE' ORDER BY id LIMIT 1;
  SELECT id INTO v_customer FROM public.customers WHERE company_id=v_company AND is_active
    AND NOT is_system_customer ORDER BY id LIMIT 1;
  SELECT id INTO v_supplier FROM public.suppliers WHERE company_id=v_company AND is_active ORDER BY id LIMIT 1;
  SELECT account_id INTO v_ar FROM private.opening_balance_control_accounts(v_company,'CUSTOMER_RECEIVABLE') LIMIT 1;
  SELECT account_id INTO v_ap FROM private.opening_balance_control_accounts(v_company,'SUPPLIER_AP_FINAL') LIMIT 1;
  SELECT id INTO v_gl FROM public.chart_of_accounts WHERE company_id=v_company AND account_code='3010100'
    AND is_active AND is_postable LIMIT 1;
  IF v_company IS NULL OR v_other IS NULL OR v_customer IS NULL OR v_supplier IS NULL
     OR v_ar IS NULL OR v_ap IS NULL OR v_gl IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: exact KGFF Company/party/account fixture required';
  END IF;

  INSERT INTO auth.users(id,email,instance_id,raw_app_meta_data,raw_user_meta_data,is_super_admin,role,aud,email_confirmed_at)
  VALUES
    (v_finance,'opening-finance@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,'{"name":"Opening Finance"}'::jsonb,false,'authenticated','authenticated',now()),
    (v_admin,'opening-admin@example.invalid','00000000-0000-0000-0000-000000000000','{"provider":"email","providers":["email"]}'::jsonb,'{"name":"Opening Admin"}'::jsonb,false,'authenticated','authenticated',now())
  ON CONFLICT(id) DO NOTHING;
  INSERT INTO public.profiles(id,email,name,role) VALUES
    (v_finance,'opening-finance@example.invalid','Opening Finance','cashier'),
    (v_admin,'opening-admin@example.invalid','Opening Admin','cashier')
  ON CONFLICT(id) DO UPDATE SET email=excluded.email,name=excluded.name;
  INSERT INTO public.company_memberships(company_id,user_id,role_code,status,is_default_company)
  VALUES(v_company,v_finance,'FINANCE','ACTIVE',true),(v_company,v_admin,'COMPANY_ADMIN','ACTIVE',true)
  ON CONFLICT(company_id,user_id) DO UPDATE SET role_code=excluded.role_code,status='ACTIVE';

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'OPENING_BALANCE_BEHAVIOR');
  IF NOT EXISTS(SELECT 1 FROM public.accounting_periods WHERE company_id=v_company
    AND current_date BETWEEN start_date AND end_date AND status IN('OPEN','REOPENED')) THEN
    PERFORM public.create_accounting_period(extract(year FROM current_date)::int,extract(month FROM current_date)::int);
  END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_finance,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'OPENING_BALANCE_BEHAVIOR');
  v_result:=public.save_opening_balance_draft(NULL,NULL,gen_random_uuid(),current_date,
    'BEHAVIOR-20261029','Behavior Opening Balance',jsonb_build_array(
      jsonb_build_object('lineType','RECEIVABLE','accountId',v_ar,'customerId',v_customer,
        'debit',100,'credit',0,'description','Opening AR behavior'),
      jsonb_build_object('lineType','PAYABLE','accountId',v_ap,'supplierId',v_supplier,
        'debit',0,'credit',60,'description','Opening AP behavior'),
      jsonb_build_object('lineType','GL','accountId',v_gl,'debit',0,'credit',40,
        'description','Opening equity behavior')));
  v_document:=(v_result->>'documentId')::uuid;v_version:=(v_result->>'masterVersion')::bigint;
  IF (v_result->>'totalDebit')::numeric<>100 OR (v_result->>'totalCredit')::numeric<>100 THEN
    RAISE EXCEPTION 'TEST_FAILED: balanced Draft totals changed'; END IF;
  IF EXISTS(SELECT 1 FROM public.opening_balance_lines line
    WHERE line.company_id=v_company AND line.document_id=v_document
      AND line.line_type IN('RECEIVABLE','PAYABLE')
      AND (line.source_document_no IS NOT NULL OR line.source_document_date IS NOT NULL
        OR line.due_date IS NOT NULL)) THEN
    RAISE EXCEPTION 'TEST_FAILED: legacy AR/AP history was fabricated'; END IF;
  v_result:=public.submit_opening_balance(v_document,v_version);
  v_version:=(v_result->>'masterVersion')::bigint;

  v_rejected:=false;
  BEGIN PERFORM public.post_opening_balance(v_document,v_version,gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_rejected:=SQLERRM='CUSTOM_PERMISSION_DENIED'; END;
  IF NOT v_rejected THEN RAISE EXCEPTION 'TEST_FAILED: Finance posted Opening Balance'; END IF;

  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
  PERFORM public.set_active_company_context(v_company,'OPENING_BALANCE_BEHAVIOR');
  v_result:=public.post_opening_balance(v_document,v_version,'00000000-0000-0000-0000-000000291099');
  v_journal:=(v_result->>'journalId')::uuid;
  IF v_result->>'status'<>'POSTED' OR NOT EXISTS(SELECT 1 FROM public.finance_journals journal
    WHERE journal.company_id=v_company AND journal.id=v_journal AND journal.status='POSTED'
      AND journal.journal_type='OPENING_BALANCE' AND journal.total_debit=100 AND journal.total_credit=100)
    OR (SELECT count(*) FROM public.finance_journal_lines line
      WHERE line.company_id=v_company AND line.journal_id=v_journal)<>3 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical Opening Balance journal invalid'; END IF;
  v_result:=public.post_opening_balance(v_document,(v_result->>'masterVersion')::bigint,
    '00000000-0000-0000-0000-000000291099');
  IF v_result->>'journalId'<>v_journal::text THEN RAISE EXCEPTION 'TEST_FAILED: posting retry duplicated journal'; END IF;

  PERFORM public.set_active_company_context(v_other,'OPENING_BALANCE_BEHAVIOR');
  v_result:=public.get_opening_balance_workspace();
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v_result->'documents') row
    WHERE row->>'id'=v_document::text) THEN RAISE EXCEPTION 'TEST_FAILED: cross-Company document leaked'; END IF;
END
$test$;

SELECT 'opening_balance_direct_entry_behavior'::text check_name,'PASS'::text status,
  0::bigint violation_rows,jsonb_build_object('tested',jsonb_build_array(
    'Finance Draft with GL and per-party AR/AP balance without legacy history','balanced submit','Finance posting denial',
    'Company Admin maker-checker posting','one canonical balanced journal',
    'idempotent post retry','cross-Company read isolation','all fixture writes rolled back')) details;

ROLLBACK;
