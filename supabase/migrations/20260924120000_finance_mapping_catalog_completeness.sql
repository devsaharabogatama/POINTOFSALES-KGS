BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended(
  '20260924120000_finance_mapping_catalog_completeness',0));

DO $guard$
DECLARE
  v_definition text;
  v_category record;
  v_function text;
  v_account uuid;
  v_direct_count bigint;
  v_fallback_count bigint;
  v_system_count bigint;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260924120000') THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260722150000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260919141000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260919143000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required Finance/Purchase Return ledger missing';
  END IF;
  IF to_regprocedure('private.resolve_opening_stock_account(uuid,uuid,text,timestamp with time zone)') IS NULL
    OR to_regprocedure('public.post_backoffice_purchase_return(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Return runtime missing';
  END IF;
  IF (SELECT count(*) FROM public.system_events WHERE system_key='PURCHASE_RETURN')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: PURCHASE_RETURN catalog identity invalid';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF (SELECT count(*) FROM public.companies company WHERE company.status='ACTIVE' AND (
      (company.id='4eedbf12-3c60-40e0-b2b7-1a48ca62b6f8'::uuid AND company.company_name='Khadijah Muda Sejahtera') OR
      (company.id='07bdffb9-8c56-444c-a49b-81ac86745674'::uuid AND company.company_name='Latorti Sari Median') OR
      (company.id='809abdd9-d05f-4525-9726-1951a0ae1a81'::uuid AND company.company_name='Smart Muda Solusi')))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: KMS/SMS/LSM identity mismatch';
  END IF;
  SELECT pg_get_functiondef('public.post_backoffice_purchase_return(uuid,bigint,uuid)'::regprocedure)
  INTO v_definition;
  FOREACH v_function IN ARRAY ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL',
    'SUPPLIER_AP_FINAL','SUPPLIER_REFUND_RECEIVABLE','PURCHASE_PRICE_VARIANCE','INPUT_TAX']::text[]
  LOOP
    IF v_definition NOT LIKE '%'||quote_literal(v_function)||'%' THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: runtime account anchor missing %',v_function;
    END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM public.system_events event
    WHERE event.system_key='PURCHASE_RETURN'
      AND event.required_account_functions @> ARRAY['SUPPLIER_AP_PROVISIONAL']::text[]
      AND event.conditional_account_functions @> ARRAY['PURCHASE_PRICE_VARIANCE','INPUT_TAX']::text[]) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: target catalog already present';
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
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Company PURCHASE_RETURN category missing %',v_category.company_id;
    END IF;
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
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ambiguous % for Company %',
          v_function,v_category.company_id;
      END IF;
      v_account:=private.resolve_opening_stock_account(
        v_category.company_id,v_category.category_id,v_function,clock_timestamp());
      IF v_account IS NULL THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unresolved % for Company %',
          v_function,v_category.company_id;
      END IF;
      IF NOT EXISTS(SELECT 1 FROM public.chart_of_accounts account
        JOIN public.account_functions function_state
          ON function_state.function_key=v_function AND function_state.is_active
        WHERE account.company_id=v_category.company_id AND account.id=v_account
          AND account.is_active AND account.is_postable
          AND account.account_type=ANY(function_state.compatible_account_types)) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: incompatible % for Company %',
          v_function,v_category.company_id;
      END IF;
    END LOOP;
  END LOOP;
END
$guard$;

UPDATE public.system_events SET
  required_account_functions=ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL']::text[],
  conditional_account_functions=ARRAY['INPUT_TAX','PURCHASE_PRICE_VARIANCE',
    'SUPPLIER_AP_FINAL','SUPPLIER_REFUND_RECEIVABLE']::text[],
  optional_account_functions=ARRAY[]::text[]
WHERE system_key='PURCHASE_RETURN';

DO $verify$
BEGIN
  IF (SELECT count(*) FROM public.system_events event
    WHERE event.system_key='PURCHASE_RETURN'
      AND event.required_account_functions=
        ARRAY['INVENTORY_ASSET','SUPPLIER_AP_PROVISIONAL']::text[]
      AND event.conditional_account_functions=
        ARRAY['INPUT_TAX','PURCHASE_PRICE_VARIANCE','SUPPLIER_AP_FINAL',
          'SUPPLIER_REFUND_RECEIVABLE']::text[]
      AND event.optional_account_functions=ARRAY[]::text[])<>1 THEN
    RAISE EXCEPTION 'MIGRATION_FAILED: PURCHASE_RETURN catalog mismatch';
  END IF;
END
$verify$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260924120000','finance_mapping_catalog_completeness',
  'Align PURCHASE_RETURN account-function catalog with the six functions used by its active posting runtime; metadata only, with no COA mapping, Stock, Payment, Event, or Journal mutation');
NOTIFY pgrst,'reload schema';
COMMIT;
