-- This behavior check is read-only. Supabase SQL Editor may commit between
-- statements, so keep the result table session-local without ON COMMIT DROP.
DROP TABLE IF EXISTS pg_temp.finance_mapping_catalog_behavior_result;
CREATE TEMP TABLE finance_mapping_catalog_behavior_result(
  check_name text,status text,violation_rows bigint,details jsonb
);

DO $test$
DECLARE
  v_category record;
  v_function text;
  v_account uuid;
  v_direct_count bigint;
  v_fallback_count bigint;
  v_system_count bigint;
  v_resolved bigint:=0;
  v_company_rows bigint:=0;
  v_before_event bigint;
  v_before_journal bigint;
  v_before_movement bigint;
BEGIN
  SELECT count(*) INTO v_before_event FROM public.financial_events;
  SELECT count(*) INTO v_before_journal FROM public.finance_journals;
  SELECT count(*) INTO v_before_movement FROM public.stock_movements;

  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260924120000') THEN RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration missing'; END IF;
  IF (SELECT count(*) FROM public.system_events event
    WHERE event.system_key='PURCHASE_RETURN'
      AND event.required_account_functions=
        ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL']::text[]
      AND event.conditional_account_functions=
        ARRAY['INPUT_TAX','PURCHASE_PRICE_VARIANCE','SUPPLIER_AP_FINAL',
          'SUPPLIER_REFUND_RECEIVABLE']::text[]
      AND event.optional_account_functions=ARRAY[]::text[])<>1 THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [CATALOG_SHAPE]';
  END IF;

  FOR v_category IN
    SELECT company.id company_id,
      (SELECT category.id FROM public.transaction_categories category
       WHERE category.company_id=company.id AND category.system_key='PURCHASE_RETURN'
         AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1) category_id
    FROM public.companies company WHERE company.status='ACTIVE' AND company.id IN(
      '4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid,
      '07bdffb9-8c56-444c-a49b-81ac86745674'::uuid,
      '809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid) ORDER BY company.id
  LOOP
    IF v_category.category_id IS NULL THEN
      RAISE EXCEPTION 'TEST_PHASE_FAILED [CATEGORY] Company %',v_category.company_id;
    END IF;
    v_company_rows:=v_company_rows+1;
    FOREACH v_function IN ARRAY ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL',
      'SUPPLIER_AP_FINAL','SUPPLIER_REFUND_RECEIVABLE','PURCHASE_PRICE_VARIANCE','INPUT_TAX']::text[]
    LOOP
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
        RAISE EXCEPTION 'TEST_PHASE_FAILED [AMBIGUOUS] Company %, function %',
          v_category.company_id,v_function;
      END IF;
      v_account:=private.resolve_opening_stock_account(
        v_category.company_id,v_category.category_id,v_function,clock_timestamp());
      IF v_account IS NULL THEN
        RAISE EXCEPTION 'TEST_PHASE_FAILED [RESOLUTION] Company %, function %',
          v_category.company_id,v_function;
      END IF;
      IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
        JOIN public.account_functions function_state
          ON function_state.function_key=v_function AND function_state.is_active
        WHERE account.company_id=v_category.company_id AND account.id=v_account
          AND account.is_active AND account.is_postable
          AND account.account_type=ANY(function_state.compatible_account_types)) THEN
        RAISE EXCEPTION 'TEST_PHASE_FAILED [INCOMPATIBLE] Company %, function %',
          v_category.company_id,v_function;
      END IF;
      v_resolved:=v_resolved+1;
    END LOOP;
  END LOOP;
  IF v_company_rows<>3 OR v_resolved<>18 THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [NONZERO_COVERAGE]';
  END IF;
  IF v_before_event<>(SELECT count(*) FROM public.financial_events)
    OR v_before_journal<>(SELECT count(*) FROM public.finance_journals)
    OR v_before_movement<>(SELECT count(*) FROM public.stock_movements) THEN
    RAISE EXCEPTION 'TEST_PHASE_FAILED [ZERO_BUSINESS_EFFECT]';
  END IF;

  INSERT INTO finance_mapping_catalog_behavior_result VALUES(
    'finance_mapping_catalog_completeness_behavior','PASS',0,
    jsonb_build_object('activeCompanies',v_company_rows,'resolvedFunctionRows',v_resolved,
      'tested',ARRAY['exact PURCHASE_RETURN six-function catalog',
        'nonzero active-Company category coverage','effective account resolution',
        'no Financial Event mutation','no Journal mutation','no Stock Movement mutation']));
END
$test$;

SELECT check_name,status,violation_rows,details
FROM finance_mapping_catalog_behavior_result ORDER BY check_name;
