-- G2 phase 42 postflight: grouped Product + Product-UOM import.
-- SELECT-only. Expected result: every row PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260727130000'

    UNION ALL

    SELECT
        'product_import_job_type',
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = rel.relnamespace
            WHERE n.nspname = 'public'
              AND rel.relname = 'master_import_jobs'
              AND con.conname = 'master_import_jobs_type_check'
              AND position(
                  '''PRODUCT''' IN pg_get_constraintdef(con.oid)
              ) > 0
        ) THEN 0 ELSE 1 END,
        jsonb_build_object('supported',EXISTS (
            SELECT 1
            FROM pg_constraint con
            JOIN pg_class rel ON rel.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = rel.relnamespace
            WHERE n.nspname = 'public'
              AND rel.relname = 'master_import_jobs'
              AND con.conname = 'master_import_jobs_type_check'
              AND position(
                  '''PRODUCT''' IN pg_get_constraintdef(con.oid)
              ) > 0
        ))

    UNION ALL

    SELECT
        'required_product_import_routines',
        5 - count(*),
        jsonb_build_object('routine_rows',count(*))
    FROM (
        VALUES
            (to_regprocedure(
                'private.validate_master_import_product_job(uuid,bigint)'
            )),
            (to_regprocedure(
                'private.commit_master_import_product_job(uuid,bigint,integer)'
            )),
            (to_regprocedure(
                'private.validate_master_import_job_phase40(uuid,bigint)'
            )),
            (to_regprocedure(
                'private.commit_master_import_job_phase40(uuid,bigint,integer)'
            )),
            (to_regprocedure(
                'private.g2_phase42_normalized_name(text)'
            ))
    ) routines(oid)
    WHERE oid IS NOT NULL

    UNION ALL

    SELECT
        'public_import_dispatch',
        count(*) FILTER (
            WHERE p.oid IS NULL
               OR position('PRODUCT' IN pg_get_functiondef(p.oid)) = 0
        ),
        jsonb_build_object('routine_rows',count(*) FILTER (
            WHERE p.oid IS NOT NULL
        ))
    FROM (
        VALUES
            (to_regprocedure(
                'public.create_master_import_job(uuid,text,text,text,text,text,text)'
            )),
            (to_regprocedure(
                'public.validate_master_import_job(uuid,bigint)'
            )),
            (to_regprocedure(
                'public.commit_master_import_job(uuid,bigint,integer)'
            ))
    ) expected(oid)
    LEFT JOIN pg_proc p ON p.oid = expected.oid

    UNION ALL

    SELECT
        'phase32_product_dispatch',
        CASE WHEN p.oid IS NOT NULL
              AND position(
                  '''PRODUCT'''
                  IN pg_get_functiondef(p.oid)
              ) > 0
             THEN 0 ELSE 1 END,
        jsonb_build_object('dispatch_exists',p.oid IS NOT NULL AND position(
            '''PRODUCT''' IN pg_get_functiondef(p.oid)
        ) > 0)
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
        'private.trg_g2_validate_import_business_fields()'
    )

    UNION ALL

    SELECT
        'product_master_version_capture',
        CASE WHEN p.oid IS NOT NULL
              AND position(
                  'v_import_type = ''PRODUCT'''
                  IN pg_get_functiondef(p.oid)
              ) > 0
             THEN 0 ELSE 1 END,
        jsonb_build_object('capture_exists',p.oid IS NOT NULL AND position(
            'v_import_type = ''PRODUCT''' IN pg_get_functiondef(p.oid)
        ) > 0)
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
        'private.trg_g2_capture_import_master_version()'
    )

    UNION ALL

    SELECT
        'browser_import_rpc_boundary',
        count(*) FILTER (WHERE unsafe),
        jsonb_build_object(
            'unsafe_routines',COALESCE(
                jsonb_agg(signature ORDER BY signature)
                    FILTER (WHERE unsafe),
                '[]'::JSONB
            )
        )
    FROM (
        SELECT
            p.oid::regprocedure::TEXT AS signature,
            has_function_privilege('anon',p.oid,'EXECUTE')
            OR NOT has_function_privilege(
                'authenticated',p.oid,'EXECUTE'
            ) AS unsafe
        FROM pg_proc p
        WHERE p.oid IN (
            to_regprocedure(
                'public.create_master_import_job(uuid,text,text,text,text,text,text)'
            ),
            to_regprocedure(
                'public.validate_master_import_job(uuid,bigint)'
            ),
            to_regprocedure(
                'public.commit_master_import_job(uuid,bigint,integer)'
            )
        )
    ) rpc

    UNION ALL

    SELECT
        'private_product_import_execute_boundary',
        count(*),
        jsonb_build_object(
            'executable_routines',COALESCE(
                jsonb_agg(p.oid::regprocedure::TEXT),
                '[]'::JSONB
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname IN (
          'validate_master_import_product_job',
          'commit_master_import_product_job',
          'validate_master_import_job_phase40',
          'commit_master_import_job_phase40'
      )
      AND (
          has_function_privilege('anon',p.oid,'EXECUTE')
          OR has_function_privilege('authenticated',p.oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'direct_product_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.products','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.product_uoms','INSERT,UPDATE,DELETE'
            )
        THEN 1 ELSE 0 END,
        jsonb_build_object(
            'products_write',has_table_privilege(
                'authenticated','public.products','INSERT,UPDATE,DELETE'
            ),
            'product_uoms_write',has_table_privilege(
                'authenticated','public.product_uoms','INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'legacy_product_import_execute_boundary',
        count(*),
        jsonb_build_object(
            'executable_routines',COALESCE(
                jsonb_agg(p.oid::regprocedure::TEXT),
                '[]'::JSONB
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'import_products_for_company'
      AND (
          has_function_privilege('anon',p.oid,'EXECUTE')
          OR has_function_privilege('authenticated',p.oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        count(*),
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
ORDER BY
    CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,
    check_name;
