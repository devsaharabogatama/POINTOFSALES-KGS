-- Rollback-only behavior for Backoffice Regular/DP Invoice Finance mapping.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_regular_category uuid;v_dp_category uuid;
  v_regular_event public.financial_events%rowtype;v_dp_event public.financial_events%rowtype;
  v_event_id uuid:=gen_random_uuid();v_dp_event_id uuid:=gen_random_uuid();
  v_ar uuid;v_revenue uuid;v_tax uuid;v_advance uuid;
  v_dp_ar uuid;v_dp_tax uuid;v_dp_advance uuid;v_journal_before bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909160000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: Invoice Finance mapping required';
  END IF;
  SELECT profile.id INTO v_actor FROM public.profiles profile
  JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role='super_admin'::public.user_role
  ORDER BY profile.id LIMIT 1;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: linked Super Admin profile required';
  END IF;
  SELECT company.id,store.id,regular.id,dp.id
  INTO v_company,v_store,v_regular_category,v_dp_category
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.transaction_categories regular ON regular.company_id=company.id
    AND regular.system_key='BACKOFFICE_SALES_INVOICE' AND regular.is_active
  JOIN public.transaction_categories dp ON dp.company_id=company.id
    AND dp.system_key='BACKOFFICE_SALES_DOWN_PAYMENT' AND dp.is_active
  WHERE company.status='ACTIVE' ORDER BY company.id,store.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: mapped active Company/Store required';
  END IF;
  SELECT count(*) INTO v_journal_before FROM public.finance_journals;

  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
    root_sales_id,event_date,event_version,idempotency_key,payment_method,amounts,status,
    created_by,company_id,store_id,system_event_key,transaction_category_id,
    transaction_rule_version)
  VALUES(v_event_id,'BO-INV-MAP-'||replace(v_event_id::text,'-',''),
    'SALE_POSTED'::public.event_type,'BACKOFFICE_INVOICE_MAPPING_TEST',gen_random_uuid(),
    NULL,clock_timestamp(),1,'BO_INVOICE_MAPPING_TEST|'||v_event_id,NULL,
    jsonb_build_object('grandTotal',1),'READY'::public.event_status,v_actor,
    v_company,v_store,'BACKOFFICE_SALES_INVOICE',v_regular_category,1)
  RETURNING * INTO v_regular_event;
  v_ar:=private.resolve_financial_event_account(v_regular_event,'CUSTOMER_RECEIVABLE');
  v_revenue:=private.resolve_financial_event_account(v_regular_event,'SALES_REVENUE');
  v_tax:=private.resolve_financial_event_account(v_regular_event,'OUTPUT_TAX');
  v_advance:=private.resolve_financial_event_account(v_regular_event,'CUSTOMER_ADVANCE_LIABILITY');
  IF v_ar IS NULL OR v_revenue IS NULL OR v_tax IS NULL OR v_advance IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: Regular Invoice account resolution incomplete';
  END IF;

  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
    root_sales_id,event_date,event_version,idempotency_key,payment_method,amounts,status,
    created_by,company_id,store_id,system_event_key,transaction_category_id,
    transaction_rule_version)
  VALUES(v_dp_event_id,'BO-DP-MAP-'||replace(v_dp_event_id::text,'-',''),
    'SALE_POSTED'::public.event_type,'BACKOFFICE_DP_MAPPING_TEST',gen_random_uuid(),
    NULL,clock_timestamp(),1,'BO_DP_MAPPING_TEST|'||v_dp_event_id,NULL,
    jsonb_build_object('grandTotal',1),'READY'::public.event_status,v_actor,
    v_company,v_store,'BACKOFFICE_SALES_DOWN_PAYMENT',v_dp_category,1)
  RETURNING * INTO v_dp_event;
  v_dp_ar:=private.resolve_financial_event_account(v_dp_event,'CUSTOMER_RECEIVABLE');
  v_dp_advance:=private.resolve_financial_event_account(
    v_dp_event,'CUSTOMER_ADVANCE_LIABILITY');
  v_dp_tax:=private.resolve_financial_event_account(v_dp_event,'OUTPUT_TAX');
  IF v_dp_ar IS NULL OR v_dp_advance IS NULL OR v_dp_tax IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: DP Invoice account resolution incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM (VALUES
      ('CUSTOMER_RECEIVABLE'::text,v_ar),('SALES_REVENUE',v_revenue),
      ('OUTPUT_TAX',v_tax),('CUSTOMER_ADVANCE_LIABILITY',v_advance),
      ('CUSTOMER_RECEIVABLE',v_dp_ar),('OUTPUT_TAX',v_dp_tax),
      ('CUSTOMER_ADVANCE_LIABILITY',v_dp_advance)) expected(function_key,account_id)
    JOIN public.chart_of_accounts account ON account.company_id=v_company
      AND account.id=expected.account_id
    JOIN public.account_functions function_state ON function_state.function_key=expected.function_key
    WHERE NOT account.is_active OR NOT account.is_postable OR NOT function_state.is_active
      OR NOT account.account_type=ANY(function_state.compatible_account_types)) THEN
    RAISE EXCEPTION 'TEST_FAILED: resolved account compatibility invalid';
  END IF;
  IF (SELECT count(*) FROM public.finance_journals)<>v_journal_before THEN
    RAISE EXCEPTION 'TEST_FAILED: mapping resolution created Journal';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_invoice_finance_mapping_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'real Regular Invoice category','real DP Invoice category',
    'AR Revenue Output Tax Customer Advance resolution','account compatibility',
    'zero Journal effect','all fixture writes rolled back']) details;
