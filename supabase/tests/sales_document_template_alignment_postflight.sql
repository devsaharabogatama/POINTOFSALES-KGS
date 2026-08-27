-- Sales document template alignment postflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_ledger' check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(count(*)-1) violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260827151000'
  UNION ALL
  SELECT 'delivery_signature_template_contract',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*),jsonb_build_object('invalidRows',count(*))
  FROM public.company_branding_profiles
  WHERE delivery_signature_template NOT IN('WAREHOUSE','STORE')
  UNION ALL
  SELECT 'required_template_setting_runtime',CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 THEN 0 ELSE 1 END,jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='public' AND routine.proname='save_company_document_visibility'
    AND pg_get_function_identity_arguments(routine.oid)=
      'p_expected_master_version bigint, p_show_logo_on_documents boolean, p_show_stamp_on_documents boolean, p_show_bank_account_on_invoice boolean, p_invoice_date_display_mode text, p_delivery_signature_template text'
  UNION ALL
  SELECT 'sales_document_snapshot_template_contract',
    CASE WHEN count(*)=1
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%deliverySignatureTemplate%')
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%showLogoOnDocuments%')
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%showStampOnDocuments%')
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%deliverySignatureTemplate%')
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%showLogoOnDocuments%')
      AND bool_and(pg_get_functiondef(routine.oid) ILIKE '%showStampOnDocuments%')
      THEN 0 ELSE 1 END,jsonb_build_object('routineRows',count(*))
  FROM pg_proc routine JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
  WHERE namespace.nspname='private' AND routine.proname='build_sales_invoice_snapshot'
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
