-- G2 phase 42 Product import completion-event forward-fix postflight.
-- SELECT-only. Expected result: 4 PASS rows with violation_rows = 0.

WITH checks AS (
    SELECT
        'phase42_dependency'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260727130000'

    UNION ALL

    SELECT
        'forward_fix_ledger',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('ledger_rows',count(*))
    FROM private.kgs_schema_migrations
    WHERE version = '20260727140000'

    UNION ALL

    SELECT
        'product_commit_complete_event',
        CASE WHEN p.oid IS NOT NULL
              AND strpos(
                  p.prosrc,
                  'v_company,p_job_id,''COMPLETE'',v_actor,'
              ) > 0
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'routine_exists',p.oid IS NOT NULL,
            'complete_event',p.oid IS NOT NULL AND strpos(
                p.prosrc,
                'v_company,p_job_id,''COMPLETE'',v_actor,'
            ) > 0
        )
    FROM (
        SELECT to_regprocedure(
            'private.commit_master_import_product_job(uuid,bigint,integer)'
        ) AS oid
    ) expected
    LEFT JOIN pg_proc p ON p.oid = expected.oid

    UNION ALL

    SELECT
        'product_commit_invalid_event_removed',
        CASE WHEN p.oid IS NOT NULL
              AND strpos(
                  p.prosrc,
                  'v_company,p_job_id,''COMMIT'',v_actor,'
              ) = 0
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'invalid_event_present',p.oid IS NOT NULL AND strpos(
                p.prosrc,
                'v_company,p_job_id,''COMMIT'',v_actor,'
            ) > 0
        )
    FROM (
        SELECT to_regprocedure(
            'private.commit_master_import_product_job(uuid,bigint,integer)'
        ) AS oid
    ) expected
    LEFT JOIN pg_proc p ON p.oid = expected.oid
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
