-- G2 phase 31 postflight: dry-run import identity validator.
-- Expected result: every row PASS with violation_rows = 0.

WITH required_routines(signature) AS (
    VALUES
        ('public.validate_master_import_job(uuid,bigint)')
), legacy_routines(signature) AS (
    VALUES
        ('public.import_products_for_company(uuid,jsonb)'),
        ('public.private_import_products_for_company_g1_legacy(uuid,jsonb)')
), import_tables(table_name) AS (
    VALUES
        ('master_import_jobs'),
        ('master_import_rows'),
        ('master_import_job_events')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260723130000'

    UNION ALL

    SELECT
        'required_validation_routine',
        count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(signature) FILTER(
                    WHERE to_regprocedure(signature) IS NULL
                ),'[]'::JSONB
            )
        )
    FROM required_routines

    UNION ALL

    SELECT
        'validation_routine_security',
        count(*) FILTER(
            WHERE p.oid IS NULL
               OR NOT p.prosecdef
               OR NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
                   @> ARRAY['search_path=public, pg_temp']::TEXT[]
        ),
        jsonb_build_object('routine_rows',count(p.oid))
    FROM required_routines required
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(required.signature)

    UNION ALL

    SELECT
        'authenticated_validation_execute',
        count(*) FILTER(
            WHERE to_regprocedure(signature) IS NULL
               OR NOT has_function_privilege(
                    'authenticated',to_regprocedure(signature),'EXECUTE'
               )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM required_routines

    UNION ALL

    SELECT
        'anon_validation_execute',
        count(*) FILTER(
            WHERE to_regprocedure(signature) IS NOT NULL
              AND has_function_privilege(
                    'anon',to_regprocedure(signature),'EXECUTE'
              )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM required_routines

    UNION ALL

    SELECT
        'browser_direct_import_table_write',
        count(*),
        jsonb_build_object(
            'table_count',count(*),
            'tables',COALESCE(jsonb_agg(table_name),'[]'::JSONB)
        )
    FROM import_tables
    WHERE has_table_privilege(
        'authenticated','public.' || table_name,'INSERT,UPDATE,DELETE'
    ) OR has_table_privilege(
        'anon','public.' || table_name,'INSERT,UPDATE,DELETE'
    )

    UNION ALL

    SELECT
        'legacy_import_api_role_execute',
        count(*) FILTER(
            WHERE to_regprocedure(signature) IS NOT NULL AND (
                has_function_privilege(
                    'anon',to_regprocedure(signature),'EXECUTE'
                ) OR has_function_privilege(
                    'authenticated',to_regprocedure(signature),'EXECUTE'
                ) OR has_function_privilege(
                    'service_role',to_regprocedure(signature),'EXECUTE'
                )
            )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM legacy_routines

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
