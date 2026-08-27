-- Invoice date display policy postflight. SELECT-only.
WITH routine_state AS (
  SELECT count(*) routine_rows FROM pg_proc routine
  JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='save_company_document_visibility'
    AND pg_get_function_identity_arguments(routine.oid)=
      'p_expected_master_version bigint, p_show_logo_on_documents boolean, p_show_stamp_on_documents boolean, p_show_bank_account_on_invoice boolean, p_invoice_date_display_mode text'
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    count(*)-1 violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827150000'
  UNION ALL
  SELECT 'invoice_date_policy_column',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,jsonb_build_object('columnRows',count(*))
  FROM information_schema.columns WHERE table_schema='public'
    AND table_name='company_branding_profiles' AND column_name='invoice_date_display_mode'
  UNION ALL
  SELECT 'invoice_date_policy_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.company_branding_profiles
  WHERE invoice_date_display_mode NOT IN('ORDER_DATE','POSTED_DATE')
  UNION ALL
  SELECT 'invoice_date_policy_save_runtime',CASE WHEN routine_rows=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN routine_rows=1 THEN 0 ELSE 1 END,jsonb_build_object('routineRows',routine_rows)
  FROM routine_state
  UNION ALL
  SELECT 'invoice_snapshot_builder_policy_contract',
    CASE WHEN pg_get_functiondef(routine.oid) ILIKE '%invoiceDateDisplayMode%'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN pg_get_functiondef(routine.oid) ILIKE '%invoiceDateDisplayMode%'
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',1)
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='build_sales_invoice_snapshot'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
