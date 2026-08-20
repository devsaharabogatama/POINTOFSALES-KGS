WITH checks AS (
  SELECT 'migration_ledger' check_name,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260820110000') pass,
    jsonb_build_object('ledgerRows',(SELECT count(*) FROM private.kgs_schema_migrations WHERE version='20260820110000')) details
  UNION ALL SELECT 'branding_visibility_columns',
    (SELECT count(*)=2 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='company_branding_profiles'
      AND column_name IN('show_logo_on_documents','show_stamp_on_documents')
      AND data_type='boolean' AND is_nullable='NO'),
    jsonb_build_object('columnRows',(SELECT count(*) FROM information_schema.columns
      WHERE table_schema='public' AND table_name='company_branding_profiles'
        AND column_name IN('show_logo_on_documents','show_stamp_on_documents')))
  UNION ALL SELECT 'branding_visibility_rpc',
    (SELECT count(*)=1 FROM pg_proc procedure JOIN pg_namespace namespace
      ON namespace.oid=procedure.pronamespace WHERE namespace.nspname='public'
      AND procedure.proname='save_company_document_logo_visibility'
      AND procedure.pronargs=3),
    jsonb_build_object('routineRows',(SELECT count(*) FROM pg_proc procedure
      JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
      WHERE namespace.nspname='public'
        AND procedure.proname='save_company_document_logo_visibility'
        AND procedure.pronargs=3))
  UNION ALL SELECT 'branding_visibility_value_shape',
    NOT EXISTS(SELECT 1 FROM public.company_branding_profiles
      WHERE show_logo_on_documents IS NULL OR show_stamp_on_documents IS NULL),
    jsonb_build_object('nullRows',(SELECT count(*) FROM public.company_branding_profiles
      WHERE show_logo_on_documents IS NULL OR show_stamp_on_documents IS NULL))
  UNION ALL SELECT 'branding_visibility_audit_contract',
    EXISTS(SELECT 1 FROM pg_constraint constraint_state
      WHERE constraint_state.conrelid='public.company_branding_audit'::regclass
        AND constraint_state.contype='c'
        AND pg_get_constraintdef(constraint_state.oid) ILIKE '%VISIBILITY_UPDATE%'),
    jsonb_build_object('constraintRows',(SELECT count(*) FROM pg_constraint constraint_state
      WHERE constraint_state.conrelid='public.company_branding_audit'::regclass
        AND constraint_state.contype='c'
        AND pg_get_constraintdef(constraint_state.oid) ILIKE '%VISIBILITY_UPDATE%'))
)
SELECT check_name,CASE WHEN pass THEN 'PASS' ELSE 'FAIL' END status,
  CASE WHEN pass THEN 0 ELSE 1 END violation_rows,details
FROM checks ORDER BY check_name;
