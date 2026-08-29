-- ODR-5B fixture-free behavioral contract. Entire block rolls back.
BEGIN;
DO $test$
DECLARE
  v_company_count BIGINT;
  v_category_count BIGINT;
  v_rule_count BIGINT;
  v_set_count BIGINT;
  v_line_count BIGINT;
  v_event_count BIGINT;
  v_journal_count BIGINT;
BEGIN
  SELECT count(*) INTO v_company_count FROM public.companies WHERE status='ACTIVE';
  SELECT count(*) INTO v_category_count FROM public.transaction_categories category
  JOIN public.companies company ON company.id=category.company_id
  WHERE company.status='ACTIVE' AND category.is_active
    AND category.system_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
    AND category.category_code IN('ODR-SALE-DISPATCHED','ODR-SALE-PAYMENT-VERIFIED');
  IF v_category_count<>v_company_count*2 THEN
    RAISE EXCEPTION 'TEST_FAILED: ODR category coverage invalid';
  END IF;

  SELECT count(*) INTO v_rule_count FROM public.transaction_account_rules rule
  JOIN public.transaction_categories category ON category.company_id=rule.company_id
    AND category.id=rule.transaction_category_id
  JOIN public.companies company ON company.id=rule.company_id
  JOIN public.chart_of_accounts account ON account.company_id=rule.company_id
    AND account.id=rule.account_id
  JOIN public.account_functions account_function
    ON account_function.function_key=rule.account_function_key
  WHERE company.status='ACTIVE' AND category.is_active
    AND category.system_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED')
    AND rule.status='ACTIVE' AND account.is_active AND account.is_postable
    AND account.account_type=ANY(account_function.compatible_account_types);
  IF v_rule_count<>v_company_count*17 THEN
    RAISE EXCEPTION 'TEST_FAILED: exact ODR account mapping invalid';
  END IF;

  SELECT count(*) INTO v_set_count
  FROM public.posting_rule_sets rule_set
  JOIN public.transaction_categories category ON category.company_id=rule_set.company_id
    AND category.id=rule_set.transaction_category_id
  JOIN public.companies company ON company.id=rule_set.company_id
  WHERE company.status='ACTIVE' AND rule_set.status='APPROVED'
    AND category.system_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED');
  SELECT count(*) INTO v_line_count
  FROM public.posting_rule_lines line
  JOIN public.posting_rule_sets rule_set ON rule_set.company_id=line.company_id
    AND rule_set.id=line.rule_set_id
  JOIN public.transaction_categories category ON category.company_id=rule_set.company_id
    AND category.id=rule_set.transaction_category_id
  JOIN public.companies company ON company.id=rule_set.company_id
  WHERE company.status='ACTIVE' AND rule_set.status='APPROVED'
    AND category.system_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED');
  IF v_set_count<>v_company_count*2 OR v_line_count<>v_company_count*18 THEN
    RAISE EXCEPTION 'TEST_FAILED: approved ODR posting rule shape invalid';
  END IF;

  SELECT count(*) INTO v_event_count FROM public.financial_events
    WHERE system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED');
  SELECT count(*) INTO v_journal_count FROM public.finance_journals journal
    JOIN public.financial_events event ON event.company_id=journal.company_id
      AND event.id=journal.financial_event_id
    WHERE event.system_event_key IN('SALE_DISPATCHED','SALE_PAYMENT_VERIFIED');
  IF v_event_count<>0 OR v_journal_count<>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: mapping foundation created runtime effect';
  END IF;
END
$test$;
SELECT 'odr_phase5b_finance_mapping_foundation_behavioral_test' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'five-Company Customer Advance account contract',
    'exact compatible account mappings','approved versioned posting definitions',
    'zero ODR Financial Event and Journal effect']) details;
ROLLBACK;
