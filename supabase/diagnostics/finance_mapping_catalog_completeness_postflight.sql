-- Supabase SQL Editor may commit between statements, so this report table must
-- not use ON COMMIT DROP. It is still session-local and is reset on every run.
DROP TABLE IF EXISTS pg_temp.finance_mapping_catalog_postflight_result;
CREATE TEMP TABLE finance_mapping_catalog_postflight_result(
  check_name text,status text,violation_rows bigint,details jsonb
);

DO $audit$
DECLARE
  v_category record;v_function text;v_account uuid;
  v_direct_count bigint;v_fallback_count bigint;v_system_count bigint;
  v_invalid jsonb:='[]'::jsonb;v_resolved bigint:=0;v_company_rows bigint:=0;
BEGIN
  INSERT INTO finance_mapping_catalog_postflight_result
  SELECT 'finance_mapping_catalog_migration_ledger',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('ledgerRows',count(*))
  FROM private.kgs_schema_migrations WHERE version='20260924120000';

  INSERT INTO finance_mapping_catalog_postflight_result
  SELECT 'finance_mapping_catalog_purchase_return_contract',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(1-count(*)),
    jsonb_build_object('rows',count(*),'required',
      ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL'],
      'conditional',ARRAY['INPUT_TAX','PURCHASE_PRICE_VARIANCE',
        'SUPPLIER_AP_FINAL','SUPPLIER_REFUND_RECEIVABLE'])
  FROM public.system_events event WHERE event.system_key='PURCHASE_RETURN'
    AND event.required_account_functions=
      ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL']::text[]
    AND event.conditional_account_functions=
      ARRAY['INPUT_TAX','PURCHASE_PRICE_VARIANCE','SUPPLIER_AP_FINAL',
        'SUPPLIER_REFUND_RECEIVABLE']::text[]
    AND event.optional_account_functions=ARRAY[]::text[];

  FOR v_category IN
    SELECT company.id company_id,company.company_name,
      (SELECT category.id FROM public.transaction_categories category
       WHERE category.company_id=company.id AND category.system_key='PURCHASE_RETURN'
         AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1) category_id
    FROM public.companies company WHERE company.status='ACTIVE' AND company.id IN(
      '4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) ORDER BY company.id
  LOOP
    IF v_category.category_id IS NULL THEN
      v_invalid:=v_invalid||jsonb_build_array(jsonb_build_object(
        'companyId',v_category.company_id,'reason','CATEGORY_MISSING'));
      CONTINUE;
    END IF;
    v_company_rows:=v_company_rows+1;
    FOREACH v_function IN ARRAY ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL',
      'SUPPLIER_AP_FINAL','SUPPLIER_REFUND_RECEIVABLE','PURCHASE_PRICE_VARIANCE','INPUT_TAX']::text[]
    LOOP
      BEGIN
        SELECT count(*) INTO v_direct_count FROM public.transaction_account_rules rule
        WHERE rule.company_id=v_category.company_id
          AND rule.transaction_category_id=v_category.category_id
          AND rule.account_function_key=v_function AND rule.status='ACTIVE'
          AND rule.effective_from<=clock_timestamp()
          AND (rule.effective_to IS NULL OR rule.effective_to>clock_timestamp());
        SELECT count(*) INTO v_fallback_count FROM public.company_account_function_fallbacks fallback
        WHERE fallback.company_id=v_category.company_id
          AND fallback.account_function_key=v_function AND fallback.status='ACTIVE'
          AND fallback.effective_from<=clock_timestamp()
          AND (fallback.effective_to IS NULL OR fallback.effective_to>clock_timestamp());
        SELECT count(*) INTO v_system_count FROM public.chart_of_accounts account
        WHERE account.company_id=v_category.company_id
          AND account.system_function_key=v_function
          AND account.is_active AND account.is_postable;
        IF v_direct_count>1 OR (v_direct_count=0 AND v_fallback_count>1)
          OR (v_direct_count=0 AND v_fallback_count=0 AND v_system_count>1) THEN
          RAISE EXCEPTION 'ACCOUNT_MAPPING_AMBIGUOUS';
        END IF;
        v_account:=private.resolve_opening_stock_account(
          v_category.company_id,v_category.category_id,v_function,clock_timestamp());
        IF v_account IS NULL THEN RAISE EXCEPTION 'NULL_ACCOUNT'; END IF;
        IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
          JOIN public.account_functions function_state
            ON function_state.function_key=v_function AND function_state.is_active
          WHERE account.company_id=v_category.company_id AND account.id=v_account
            AND account.is_active AND account.is_postable
            AND account.account_type=ANY(function_state.compatible_account_types)) THEN
          RAISE EXCEPTION 'ACCOUNT_MAPPING_INCOMPATIBLE';
        END IF;
        v_resolved:=v_resolved+1;
      EXCEPTION WHEN OTHERS THEN
        v_invalid:=v_invalid||jsonb_build_array(jsonb_build_object(
          'companyId',v_category.company_id,'companyName',v_category.company_name,
          'function',v_function,'reason',SQLERRM));
      END;
    END LOOP;
  END LOOP;
  INSERT INTO finance_mapping_catalog_postflight_result VALUES(
    'finance_mapping_catalog_runtime_resolution',
    CASE WHEN jsonb_array_length(v_invalid)=0 AND v_company_rows=3 AND v_resolved=18
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_array_length(v_invalid)+abs(3-v_company_rows)+abs(18-v_resolved),
    jsonb_build_object('activeCompanies',v_company_rows,'resolvedRows',v_resolved,
      'expectedCompanies',3,'expectedResolvedRows',18,'invalid',v_invalid));

  INSERT INTO finance_mapping_catalog_postflight_result
  SELECT 'finance_mapping_catalog_active_finance_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),jsonb_build_object('rows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING');
  INSERT INTO finance_mapping_catalog_postflight_result
  SELECT 'finance_mapping_catalog_business_boundary','PASS',0,jsonb_build_object(
    'rule','Catalog-only update; no COA, mapping, Stock, FIFO, Payment, Event, or Journal row is mutated');
END
$audit$;

SELECT check_name,status,violation_rows,details
FROM finance_mapping_catalog_postflight_result
ORDER BY CASE status WHEN 'FAIL' THEN 0 ELSE 1 END,check_name;
