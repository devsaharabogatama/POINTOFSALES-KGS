-- G2 phase 38 postflight: code-less simple master import.
-- SELECT-only. Expected: all rows PASS with violation_rows = 0.

WITH checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        abs(count(*)-1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260724040000'

    UNION ALL

    SELECT 'public_validator_wrapper',
        CASE WHEN count(*)=1
               AND bool_and(p.prosecdef)
               AND bool_and(
                   COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
                   @> ARRAY['search_path=public, pg_temp']::TEXT[]
               )
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    WHERE p.oid=to_regprocedure(
        'public.validate_master_import_job(uuid,bigint)'
    )

    UNION ALL

    SELECT 'private_phase31_validator',
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='private'
      AND p.proname='validate_master_import_job_phase31'
      AND pg_get_function_identity_arguments(p.oid)='p_job_id uuid, p_master_version bigint'

    UNION ALL

    SELECT 'wrapper_codeless_contract',
        CASE WHEN count(*)=1
               AND bool_and(pg_get_functiondef(p.oid) LIKE '%__system_code%')
               AND bool_and(
                   pg_get_functiondef(p.oid) LIKE
                   '%private.allocate_master_code%'
               )
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    WHERE p.oid=to_regprocedure(
        'public.validate_master_import_job(uuid,bigint)'
    )

    UNION ALL

    SELECT 'warehouse_generated_code_validator',
        CASE WHEN count(*)=1
               AND bool_and(
                   pg_get_functiondef(p.oid) LIKE
                   '%^WH-[0-9]{6,18}$%'
               )
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    WHERE p.oid=to_regprocedure(
        'private.trg_g2_validate_import_business_fields()'
    )

    UNION ALL

    SELECT 'validator_privilege_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.validate_master_import_job(uuid,bigint)','EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.validate_master_import_job(uuid,bigint)','EXECUTE'
            )
            AND NOT has_function_privilege(
                'authenticated',
                'private.validate_master_import_job_phase31(uuid,bigint)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object(
            'authenticated_public_execute',has_function_privilege(
                'authenticated',
                'public.validate_master_import_job(uuid,bigint)','EXECUTE'
            ),
            'anon_public_execute',has_function_privilege(
                'anon',
                'public.validate_master_import_job(uuid,bigint)','EXECUTE'
            )
        )

    UNION ALL

    SELECT 'nonterminal_import_jobs',0::BIGINT,
        jsonb_build_object(
            'job_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status NOT IN (
        'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
    )
)
SELECT check_name,
    CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows>0 THEN 1 ELSE 2 END,check_name;
