-- Read-only Production preflight for Finance mapping catalog completeness.
-- Safe to rerun. Temp-table writes are session-local only.
-- Supabase SQL Editor may commit between statements, so this report table must
-- not use ON COMMIT DROP. It is still session-local and is reset on every run.
DROP TABLE IF EXISTS pg_temp.finance_mapping_catalog_preflight_result;
CREATE TEMP TABLE finance_mapping_catalog_preflight_result(
  check_name text,status text,violation_rows bigint,details jsonb
);

DO $audit$
DECLARE
  v_missing text[]:=ARRAY[]::text[];
  v_definition text;
  v_category record;
  v_function text;
  v_account uuid;
  v_direct_count bigint;
  v_fallback_count bigint;
  v_system_count bigint;
  v_invalid jsonb:='[]'::jsonb;
  v_runtime_rows bigint:=0;
BEGIN
  IF to_regclass('private.kgs_schema_migrations') IS NULL THEN v_missing:=array_append(v_missing,'private.kgs_schema_migrations'); END IF;
  IF to_regclass('public.companies') IS NULL THEN v_missing:=array_append(v_missing,'public.companies'); END IF;
  IF to_regclass('public.system_events') IS NULL THEN v_missing:=array_append(v_missing,'public.system_events'); END IF;
  IF to_regclass('public.account_functions') IS NULL THEN v_missing:=array_append(v_missing,'public.account_functions'); END IF;
  IF to_regclass('public.chart_of_accounts') IS NULL THEN v_missing:=array_append(v_missing,'public.chart_of_accounts'); END IF;
  IF to_regclass('public.transaction_categories') IS NULL THEN v_missing:=array_append(v_missing,'public.transaction_categories'); END IF;
  IF to_regclass('public.transaction_account_rules') IS NULL THEN v_missing:=array_append(v_missing,'public.transaction_account_rules'); END IF;
  IF to_regclass('public.company_account_function_fallbacks') IS NULL THEN v_missing:=array_append(v_missing,'public.company_account_function_fallbacks'); END IF;
  IF to_regclass('public.finance_posting_queue_runs') IS NULL THEN v_missing:=array_append(v_missing,'public.finance_posting_queue_runs'); END IF;
  IF to_regclass('public.pos_offline_sale_submissions') IS NULL THEN v_missing:=array_append(v_missing,'public.pos_offline_sale_submissions'); END IF;
  IF to_regprocedure('private.resolve_opening_stock_account(uuid,uuid,text,timestamp with time zone)') IS NULL THEN
    v_missing:=array_append(v_missing,'private.resolve_opening_stock_account(uuid,uuid,text,timestamptz)');
  END IF;
  IF to_regprocedure('public.post_backoffice_purchase_return(uuid,bigint,uuid)') IS NULL THEN
    v_missing:=array_append(v_missing,'public.post_backoffice_purchase_return(uuid,bigint,uuid)');
  END IF;
  INSERT INTO finance_mapping_catalog_preflight_result VALUES(
    'finance_mapping_catalog_required_runtime',
    CASE WHEN cardinality(v_missing)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    cardinality(v_missing),jsonb_build_object('missing',v_missing));
  IF cardinality(v_missing)>0 THEN RETURN; END IF;

  INSERT INTO finance_mapping_catalog_preflight_result
  SELECT 'finance_mapping_catalog_dependency_ledger',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,3-count(*),
    jsonb_build_object('required',ARRAY['20260722150000','20260919141000','20260919143000'],
      'installed',COALESCE(jsonb_agg(version ORDER BY version),'[]'::jsonb))
  FROM private.kgs_schema_migrations
  WHERE version IN('20260722150000','20260919141000','20260919143000');

  INSERT INTO finance_mapping_catalog_preflight_result
  SELECT 'finance_mapping_catalog_object_collision',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),
    jsonb_build_object('existing',COALESCE(jsonb_agg(version),'[]'::jsonb))
  FROM private.kgs_schema_migrations WHERE version='20260924120000';

  INSERT INTO finance_mapping_catalog_preflight_result
  SELECT 'finance_mapping_catalog_target_company_identity',
    CASE WHEN count(*)=3 AND count(*) FILTER(WHERE
      (id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid AND company_name='Khadijah Muda Sejahtera') OR
      (id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid AND company_name='Latorti Sari Median') OR
      (id='809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid AND company_name='Smart Muda Solusi'))=3
      THEN 'PASS' ELSE 'BLOCKER' END,
    3-count(*) FILTER(WHERE
      (id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid AND company_name='Khadijah Muda Sejahtera') OR
      (id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid AND company_name='Latorti Sari Median') OR
      (id='809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid AND company_name='Smart Muda Solusi')),
    jsonb_build_object('rows',count(*),'companies',COALESCE(jsonb_agg(
      jsonb_build_object('id',id,'name',company_name,'status',status) ORDER BY company_name),'[]'::jsonb))
  FROM public.companies WHERE id IN(
    '4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
    '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
    '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) AND status='ACTIVE';

  SELECT pg_get_functiondef(
    'public.post_backoffice_purchase_return(uuid,bigint,uuid)'::regprocedure)
  INTO v_definition;
  INSERT INTO finance_mapping_catalog_preflight_result
  SELECT 'finance_mapping_catalog_purchase_return_runtime_anchor',
    CASE WHEN count(*)=6 THEN 'PASS' ELSE 'BLOCKER' END,6-count(*),
    jsonb_build_object('present',COALESCE(jsonb_agg(function_key ORDER BY function_key),'[]'::jsonb),'expected',6)
  FROM unnest(ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL','SUPPLIER_AP_FINAL',
    'SUPPLIER_REFUND_RECEIVABLE','PURCHASE_PRICE_VARIANCE','INPUT_TAX']) function_key
  WHERE v_definition LIKE '%'||quote_literal(function_key)||'%';

  INSERT INTO finance_mapping_catalog_preflight_result
  SELECT 'finance_mapping_catalog_purchase_return_current_shape','INFO',0,
    jsonb_build_object('rows',count(*),'required',COALESCE(jsonb_agg(required_account_functions),'[]'::jsonb),
      'conditional',COALESCE(jsonb_agg(conditional_account_functions),'[]'::jsonb),
      'optional',COALESCE(jsonb_agg(optional_account_functions),'[]'::jsonb))
  FROM public.system_events WHERE system_key='PURCHASE_RETURN';

  INSERT INTO finance_mapping_catalog_preflight_result
  SELECT 'finance_mapping_catalog_active_queue',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),jsonb_build_object('rows',count(*))
  FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING');
  INSERT INTO finance_mapping_catalog_preflight_result
  SELECT 'finance_mapping_catalog_nonterminal_offline',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,count(*),jsonb_build_object('rows',count(*))
  FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION');

  FOR v_category IN
    SELECT company.id company_id,company.company_name,
      (SELECT category.id FROM public.transaction_categories category
       WHERE category.company_id=company.id AND category.system_key='PURCHASE_RETURN'
         AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1) category_id,
      (SELECT count(*) FROM public.transaction_categories category
       WHERE category.company_id=company.id AND category.system_key='PURCHASE_RETURN'
         AND category.is_active) category_rows
    FROM public.companies company WHERE company.status='ACTIVE' AND company.id IN(
      '4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) ORDER BY company.id
  LOOP
    IF v_category.category_rows=0 OR v_category.category_id IS NULL THEN
      v_invalid:=v_invalid||jsonb_build_array(jsonb_build_object(
        'companyId',v_category.company_id,'companyName',v_category.company_name,
        'reason','PURCHASE_RETURN_CATEGORY_MISSING'));
      CONTINUE;
    END IF;
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
        v_runtime_rows:=v_runtime_rows+1;
      EXCEPTION WHEN OTHERS THEN
        v_invalid:=v_invalid||jsonb_build_array(jsonb_build_object(
          'companyId',v_category.company_id,'companyName',v_category.company_name,
          'function',v_function,'reason',SQLERRM));
      END;
    END LOOP;
  END LOOP;
  INSERT INTO finance_mapping_catalog_preflight_result VALUES(
    'finance_mapping_catalog_runtime_resolution',
    CASE WHEN jsonb_array_length(v_invalid)=0 AND v_runtime_rows>0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_array_length(v_invalid),jsonb_build_object('resolvedRows',v_runtime_rows,'invalid',v_invalid));
END
$audit$;

SELECT check_name,status,violation_rows,details
FROM finance_mapping_catalog_preflight_result
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
