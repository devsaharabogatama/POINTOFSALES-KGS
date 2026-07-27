-- G2 phase 33 postflight: guarded non-stock import partial commit.
-- Expected result: every row PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260723190000'

    UNION ALL

    SELECT
        'matched_master_version_column',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('column_rows',count(*))
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'master_import_rows'
      AND column_name = 'matched_master_version'
      AND data_type = 'bigint'

    UNION ALL

    SELECT
        'capture_version_trigger_routine',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_capture_import_master_version'
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]

    UNION ALL

    SELECT
        'capture_version_trigger',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'master_import_rows'
      AND t.tgname = 'g2_capture_import_master_version'
      AND NOT t.tgisinternal AND t.tgenabled <> 'D'

    UNION ALL

    SELECT
        'commit_routine_security',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
        'public.commit_master_import_job(uuid,bigint,integer)'
    )
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]

    UNION ALL

    SELECT
        'authenticated_commit_execute',
        CASE WHEN to_regprocedure(
            'public.commit_master_import_job(uuid,bigint,integer)'
        ) IS NOT NULL
        AND has_function_privilege(
            'authenticated',
            'public.commit_master_import_job(uuid,bigint,integer)',
            'EXECUTE'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'routine_exists',to_regprocedure(
                'public.commit_master_import_job(uuid,bigint,integer)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'anon_commit_execute',
        CASE WHEN to_regprocedure(
            'public.commit_master_import_job(uuid,bigint,integer)'
        ) IS NOT NULL
        AND has_function_privilege(
            'anon','public.commit_master_import_job(uuid,bigint,integer)',
            'EXECUTE'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object('anon_execute',COALESCE(
            has_function_privilege(
                'anon','public.commit_master_import_job(uuid,bigint,integer)',
                'EXECUTE'
            ),FALSE
        ))

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
        'commit_scope_excludes_product_and_stock',
        CASE WHEN count(*) <> 1 THEN 1
             WHEN bool_or(
                pg_get_functiondef(p.oid) ~*
                '(product_stocks|stock_movements|public\.products|public\.product_uoms)'
             ) THEN 1 ELSE 0 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
        'public.commit_master_import_job(uuid,bigint,integer)'
    )
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
