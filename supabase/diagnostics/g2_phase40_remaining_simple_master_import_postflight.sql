-- G2 phase 40 postflight: remaining simple master import database gate.
-- Expected: 10 PASS rows with violation_rows = 0.
-- SAFETY: SELECT-only.

WITH expected_types(import_type) AS (
    VALUES
        ('PRODUCT_CATEGORY'),('UOM'),('WAREHOUSE'),('SUPPLIER'),
        ('CUSTOMER_CATEGORY'),('CHART_OF_ACCOUNT'),('TRANSACTION_CATEGORY')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260727090000'

    UNION ALL

    SELECT
        'import_type_constraint',
        count(*) FILTER (
            WHERE c.oid IS NULL
               OR pg_get_constraintdef(c.oid) NOT LIKE
                '%' || expected.import_type || '%'
        ),
        jsonb_build_object(
            'expected_types',count(*),
            'constraint_rows',count(DISTINCT c.oid)
        )
    FROM expected_types expected
    LEFT JOIN pg_constraint c
      ON c.conrelid = 'public.master_import_jobs'::REGCLASS
     AND c.conname = 'master_import_jobs_type_check'

    UNION ALL

    SELECT
        'public_import_routines',
        count(*) FILTER (WHERE routine_oid IS NULL),
        jsonb_build_object('routine_rows',count(routine_oid))
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
    ) routines(routine_oid)

    UNION ALL

    SELECT
        'private_compatibility_routines',
        count(*) FILTER (WHERE routine_oid IS NULL),
        jsonb_build_object('routine_rows',count(routine_oid))
    FROM (
        VALUES
            (to_regprocedure(
                'private.validate_master_import_job_phase31(uuid,bigint)'
            )),
            (to_regprocedure(
                'private.validate_master_import_job_phase38(uuid,bigint)'
            )),
            (to_regprocedure(
                'private.commit_master_import_job_phase33(uuid,bigint,integer)'
            ))
    ) routines(routine_oid)

    UNION ALL

    SELECT
        'master_version_capture_dispatch',
        CASE WHEN count(p.oid) = 1
            AND bool_and(
                pg_get_functiondef(p.oid) LIKE '%CUSTOMER_CATEGORY%'
                AND pg_get_functiondef(p.oid) LIKE '%CHART_OF_ACCOUNT%'
                AND pg_get_functiondef(p.oid) LIKE '%TRANSACTION_CATEGORY%'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(p.oid))
    FROM (
        VALUES (to_regprocedure(
            'private.trg_g2_capture_import_master_version()'
        ))
    ) expected(routine_oid)
    LEFT JOIN pg_proc p ON p.oid = expected.routine_oid

    UNION ALL

    SELECT
        'phase32_trigger_dispatch',
        CASE WHEN count(p.oid) = 1
            AND bool_and(
                pg_get_functiondef(p.oid) LIKE '%CUSTOMER_CATEGORY%'
                AND pg_get_functiondef(p.oid) LIKE '%CHART_OF_ACCOUNT%'
                AND pg_get_functiondef(p.oid) LIKE '%TRANSACTION_CATEGORY%'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(p.oid))
    FROM (
        VALUES (to_regprocedure(
            'private.trg_g2_validate_import_business_fields()'
        ))
    ) expected(routine_oid)
    LEFT JOIN pg_proc p ON p.oid = expected.routine_oid

    UNION ALL

    SELECT
        'browser_import_execute',
        count(*) FILTER (
            WHERE NOT has_function_privilege(
                'authenticated',routine_oid,'EXECUTE'
            )
        ),
        jsonb_build_object('routine_rows',count(*))
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
    ) routines(routine_oid)

    UNION ALL

    SELECT
        'private_import_execute_closed',
        count(*) FILTER (
            WHERE has_function_privilege(
                'authenticated',routine_oid,'EXECUTE'
            )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM (
        VALUES
            (to_regprocedure(
                'private.validate_master_import_job_phase38(uuid,bigint)'
            )),
            (to_regprocedure(
                'private.commit_master_import_job_phase33(uuid,bigint,integer)'
            )),
            (to_regprocedure(
                'private.g2_phase40_import_boolean(text,boolean)'
            ))
    ) routines(routine_oid)

    UNION ALL

    SELECT
        'direct_master_write_closed',
        (
            has_table_privilege(
                'authenticated','public.customer_categories',
                'INSERT,UPDATE,DELETE'
            )::INTEGER
            + has_table_privilege(
                'authenticated','public.chart_of_accounts',
                'INSERT,UPDATE,DELETE'
            )::INTEGER
            + has_table_privilege(
                'authenticated','public.transaction_categories',
                'INSERT,UPDATE,DELETE'
            )::INTEGER
        )::BIGINT,
        jsonb_build_object(
            'customer_category_write',has_table_privilege(
                'authenticated','public.customer_categories',
                'INSERT,UPDATE,DELETE'
            ),
            'coa_write',has_table_privilege(
                'authenticated','public.chart_of_accounts',
                'INSERT,UPDATE,DELETE'
            ),
            'transaction_category_write',has_table_privilege(
                'authenticated','public.transaction_categories',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        count(*),
        jsonb_build_object('job_count',count(*))
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
