-- G2 phase 40 COA parent UUID aggregate forward-fix postflight.
-- Expected: 4 PASS rows with violation_rows = 0.
-- SAFETY: SELECT-only.

WITH validator AS (
    SELECT p.oid,p.prosrc AS source
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
        'public.validate_master_import_job(uuid,bigint)'
    )
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260727100000'

    UNION ALL

    SELECT
        'public_validator_exists',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM validator

    UNION ALL

    SELECT
        'coa_parent_uuid_aggregate_fixed',
        CASE WHEN count(*) = 1 AND bool_and(
            strpos(source,'min(x.id::TEXT)::UUID') > 0
            AND strpos(source,'min(x.id)') = 0
        ) THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM validator

    UNION ALL

    SELECT
        'browser_validator_execute',
        CASE WHEN has_function_privilege(
            'authenticated',
            'public.validate_master_import_job(uuid,bigint)',
            'EXECUTE'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.validate_master_import_job(uuid,bigint)',
                'EXECUTE'
            )
        )
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
