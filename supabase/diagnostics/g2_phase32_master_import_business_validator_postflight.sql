-- G2 phase 32 postflight: business-field import dry-run validator.
-- Expected result: every row PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260723160000'

    UNION ALL

    SELECT
        'business_validator_trigger_routine',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_validate_import_business_fields'
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]

    UNION ALL

    SELECT
        'business_validator_trigger',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'master_import_rows'
      AND t.tgname = 'g2_validate_import_business_fields'
      AND NOT t.tgisinternal
      AND t.tgenabled <> 'D'

    UNION ALL

    SELECT
        'private_business_validator_browser_execute',
        count(*),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_validate_import_business_fields'
      AND (
          has_function_privilege('anon',p.oid,'EXECUTE')
          OR has_function_privilege('authenticated',p.oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'public_identity_validator_contract',
        CASE WHEN to_regprocedure(
            'public.validate_master_import_job(uuid,bigint)'
        ) IS NOT NULL
        AND has_function_privilege(
            'authenticated',
            'public.validate_master_import_job(uuid,bigint)',
            'EXECUTE'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'routine_exists',to_regprocedure(
                'public.validate_master_import_job(uuid,bigint)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'legacy_import_api_role_execute',
        count(*),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'import_products_for_company',
          'private_import_products_for_company_g1_legacy'
      )
      AND (
          has_function_privilege('anon',p.oid,'EXECUTE')
          OR has_function_privilege('authenticated',p.oid,'EXECUTE')
          OR has_function_privilege('service_role',p.oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'commit_cutover_absent',
        count(*),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'commit_master_import_job'
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
