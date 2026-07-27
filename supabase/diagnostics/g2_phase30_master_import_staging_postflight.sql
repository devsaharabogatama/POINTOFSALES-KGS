-- G2 phase 30 postflight: master import staging foundation.
-- Expected result: every row PASS with violation_rows = 0.

WITH required_tables(table_name) AS (
    VALUES
        ('master_import_jobs'),
        ('master_import_rows'),
        ('master_import_job_events')
), required_routines(signature) AS (
    VALUES
        ('public.create_master_import_job(uuid,text,text,text,text,text,text)'),
        ('public.stage_master_import_rows(uuid,bigint,jsonb,jsonb)')
), legacy_routines(signature) AS (
    VALUES
        ('public.import_products_for_company(uuid,jsonb)'),
        ('public.private_import_products_for_company_g1_legacy(uuid,jsonb)')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260723100000'

    UNION ALL

    SELECT
        'required_import_tables',
        count(*) FILTER(WHERE to_regclass('public.' || table_name) IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(table_name ORDER BY table_name)
                    FILTER(WHERE to_regclass('public.' || table_name) IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_tables

    UNION ALL

    SELECT
        'required_import_rls',
        count(*) FILTER(WHERE c.oid IS NULL OR NOT c.relrowsecurity),
        jsonb_build_object('table_rows',count(*))
    FROM required_tables required
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = required.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'required_import_select_policies',
        CASE WHEN count(*) = 3 THEN 0 ELSE 1 END,
        jsonb_build_object('policy_rows',count(*))
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
          'master_import_jobs','master_import_rows','master_import_job_events'
      )
      AND cmd = 'SELECT'

    UNION ALL

    SELECT
        'required_import_routines',
        count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(signature ORDER BY signature)
                    FILTER(WHERE to_regprocedure(signature) IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_routines

    UNION ALL

    SELECT
        'guarded_import_routine_security',
        count(*) FILTER(
            WHERE p.oid IS NULL
               OR NOT p.prosecdef
               OR NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
                   @> ARRAY['search_path=public, pg_temp']::TEXT[]
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM required_routines required
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(required.signature)

    UNION ALL

    SELECT
        'authenticated_guarded_import_execute',
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
        'anon_guarded_import_execute',
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
    FROM required_tables
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
        'validation_commit_cutover_absent',
        count(*),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'validate_master_import_job','commit_master_import_job'
      )
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
