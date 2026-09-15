-- Rollback-only behavior for deterministic Customer receipt account resolution.
BEGIN;
DO $test$
DECLARE
  v_actor uuid;v_company uuid;v_store uuid;v_category uuid;v_event_id uuid:=gen_random_uuid();
  v_event public.financial_events%rowtype;v_cogs uuid;v_inventory uuid;
  v_journals_before bigint;v_journals_after bigint;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909153000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: receipt Finance mapping required';
  END IF;
  SELECT profile.id INTO STRICT v_actor
  FROM auth.users user_row
  JOIN public.profiles profile ON profile.id=user_row.id
    AND profile.role::text='super_admin'
  ORDER BY profile.id LIMIT 1;
  SELECT company.id,store.id,category.id INTO STRICT v_company,v_store,v_category
  FROM public.companies company
  JOIN public.stores store ON store.company_id=company.id AND store.status='ACTIVE'
  JOIN public.transaction_categories category ON category.company_id=company.id
    AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND category.is_active
  WHERE company.status='ACTIVE' ORDER BY company.id,store.id LIMIT 1;
  SELECT count(*) INTO v_journals_before FROM public.finance_journals;

  INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
    root_sales_id,event_date,event_version,idempotency_key,payment_method,amounts,
    status,created_by,company_id,store_id,system_event_key,
    transaction_category_id,transaction_rule_version)
  VALUES(v_event_id,'BO-RCP-MAP-'||replace(v_event_id::text,'-',''),
    'SALE_POSTED'::public.event_type,'BACKOFFICE_RECEIPT_MAPPING_TEST',gen_random_uuid(),
    NULL,clock_timestamp(),1,'BO_RECEIPT_MAPPING_TEST|'||v_event_id,NULL,
    jsonb_build_object('fifoCostTotal',1),'READY'::public.event_status,v_actor,
    v_company,v_store,'BACKOFFICE_CUSTOMER_RECEIPT',v_category,1)
  RETURNING * INTO v_event;
  v_cogs:=private.resolve_financial_event_account(v_event,'COGS');
  v_inventory:=private.resolve_financial_event_account(v_event,'INVENTORY_ASSET');
  IF v_cogs IS NULL OR v_inventory IS NULL OR v_cogs=v_inventory THEN
    RAISE EXCEPTION 'TEST_FAILED: receipt account resolution invalid';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.id=v_cogs
        AND account.account_type='COGS' AND account.is_active AND account.is_postable)
    OR NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
      WHERE account.company_id=v_company AND account.id=v_inventory
        AND account.account_type='ASSET' AND account.is_active AND account.is_postable) THEN
    RAISE EXCEPTION 'TEST_FAILED: resolved receipt account type invalid';
  END IF;
  SELECT count(*) INTO v_journals_after FROM public.finance_journals;
  IF v_journals_after<>v_journals_before THEN
    RAISE EXCEPTION 'TEST_FAILED: mapping resolution created Journal';
  END IF;
END
$test$;
ROLLBACK;
SELECT 'backoffice_sales_receipt_finance_mapping_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'real Financial Event category mapping','COGS account resolution',
    'Inventory Asset account resolution','account type validation',
    'zero Journal effect','all fixture writes rolled back']) details;
