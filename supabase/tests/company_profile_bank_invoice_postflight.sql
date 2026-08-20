-- Postflight: Company profile, bank identity, Invoice visibility, Supplier bank reference.
WITH checks AS (
  SELECT 'required_company_profile_columns' check_name,
    CASE WHEN count(*)=13 THEN 'PASS' ELSE 'FAIL' END status,
    jsonb_build_object('expected',13,'columnRows',count(*)) details
  FROM information_schema.columns WHERE table_schema='public' AND table_name='companies'
    AND column_name IN('address','city','province','postal_code','country','phone','email','website',
      'registration_no','bank_name','bank_account_number','bank_account_holder','profile_master_version')
  UNION ALL
  SELECT 'invoice_bank_visibility_default',
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='company_branding_profiles' AND column_name='show_bank_account_on_invoice'
    AND column_default ILIKE '%false%'
  UNION ALL
  SELECT 'required_company_profile_routines',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('expected',3,'routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname IN(
    'get_company_profile','save_company_profile','save_company_document_visibility')
  UNION ALL
  SELECT 'browser_company_profile_rpc_boundary',
    CASE WHEN count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE'))=0
      AND count(*) FILTER(WHERE has_function_privilege('authenticated',routine.oid,'EXECUTE'))=3
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object(
      'anonRows',count(*) FILTER(WHERE has_function_privilege('anon',routine.oid,'EXECUTE')),
      'authenticatedRows',count(*) FILTER(WHERE has_function_privilege('authenticated',routine.oid,'EXECUTE')))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname IN(
    'get_company_profile','save_company_profile','save_company_document_visibility')
  UNION ALL
  SELECT 'company_bank_identity_integrity',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('rowCount',count(*)) FROM public.companies company
  WHERE (
    CASE WHEN company.bank_name IS NULL THEN 0 ELSE 1 END
    + CASE WHEN company.bank_account_number IS NULL THEN 0 ELSE 1 END
    + CASE WHEN company.bank_account_holder IS NULL THEN 0 ELSE 1 END
  ) NOT IN(0,3)
  UNION ALL
  SELECT 'supplier_payment_bank_reference_contract',
    CASE WHEN pg_get_functiondef(routine.oid) LIKE '%bank_account_number%'
      AND pg_get_functiondef(routine.oid) LIKE '%bank_account_holder%' THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',1)
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='get_finance_supplier_payments'
  UNION ALL
  SELECT 'invoice_bank_snapshot_contract',
    CASE WHEN pg_get_functiondef(routine.oid) LIKE '%showBankAccountOnInvoice%'
      AND pg_get_functiondef(routine.oid) LIKE '%bankAccountNumber%'
      AND pg_get_functiondef(routine.oid) LIKE '%deliveryFeeInvoiceDisplayMode%'
      THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('routineRows',1)
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='build_sales_invoice_snapshot'
  UNION ALL
  SELECT 'migration_ledger',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    jsonb_build_object('ledgerRows',count(*)) FROM private.kgs_schema_migrations
  WHERE version='20260820120000'
)
SELECT check_name,status,details FROM checks ORDER BY
  CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
