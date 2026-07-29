-- G2 phase 44 postflight: Product-Supplier import contract.
-- Expected result: 11 PASS rows with violation_rows = 0.
-- SELECT-only.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260727160000'

    UNION ALL

    SELECT
        'product_supplier_job_type_constraint',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND rel.relname = 'master_import_jobs'
      AND con.conname = 'master_import_jobs_type_check'
      AND pg_get_constraintdef(con.oid) LIKE '%PRODUCT_SUPPLIER%'

    UNION ALL

    SELECT
        'create_job_whitelist',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.oid = to_regprocedure(
        'public.create_master_import_job(uuid,text,text,text,text,text,text)'
    )
      AND p.prosrc LIKE '%PRODUCT_SUPPLIER%'

    UNION ALL

    SELECT
        'phase32_product_supplier_dispatch',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_validate_import_business_fields'
      AND p.prosrc LIKE '%PRODUCT_SUPPLIER%'

    UNION ALL

    SELECT
        'matched_version_capture',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_capture_import_master_version'
      AND p.prosrc LIKE '%PRODUCT_SUPPLIER%'
      AND p.prosrc LIKE '%product_suppliers%'

    UNION ALL

    SELECT
        'private_validator_contract',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'validate_master_import_product_supplier_job'
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]

    UNION ALL

    SELECT
        'private_commit_contract',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'commit_master_import_product_supplier_job'
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]
      AND p.prosrc LIKE '%save_product_supplier%'
      AND p.prosrc LIKE '%''COMPLETE''%'

    UNION ALL

    SELECT
        'public_dispatcher_contract',
        CASE WHEN count(*) = 2 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'validate_master_import_job','commit_master_import_job'
      )
      AND p.prosrc LIKE '%PRODUCT_SUPPLIER%'

    UNION ALL

    SELECT
        'private_routine_execute_boundary',
        count(*)::BIGINT,
        jsonb_build_object(
            'executable_routines',COALESCE(
                jsonb_agg(p.proname ORDER BY p.proname),'[]'::JSONB
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname IN (
          'validate_master_import_product_supplier_job',
          'commit_master_import_product_supplier_job',
          'g2_phase44_import_error'
      )
      AND (
          has_function_privilege('anon',p.oid,'EXECUTE')
          OR has_function_privilege('authenticated',p.oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'direct_product_supplier_write_boundary',
        CASE WHEN has_table_privilege(
            'authenticated','public.product_suppliers',
            'INSERT,UPDATE,DELETE'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated','public.product_suppliers',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        count(*)::BIGINT,
        jsonb_build_object(
            'job_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status NOT IN (
        'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
    )
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
