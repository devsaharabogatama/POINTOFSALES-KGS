-- G4 phase 49 digest forward-fix postflight. SELECT-only.

WITH routine AS (
    SELECT procedure.oid,pg_get_functiondef(procedure.oid) AS definition
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname='request_customer_balance_correction'
      AND procedure.pronargs=8
), checks AS (
    SELECT 'digest_fix_migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260805100000'

    UNION ALL
    SELECT 'customer_balance_digest_runtime_contract',
        CASE WHEN count(*)=1
                  AND bool_and(definition LIKE '%extensions.digest%')
                  AND bool_and(definition LIKE '%convert_to%')
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'schema_qualified_digest',COALESCE(bool_or(
                definition LIKE '%extensions.digest%'
            ),FALSE),
            'bytea_conversion',COALESCE(bool_or(
                definition LIKE '%convert_to%'
            ),FALSE)
        )
    FROM routine

    UNION ALL
    SELECT 'customer_balance_request_rpc_boundary',
        CASE WHEN count(*)=1
                  AND bool_and(has_function_privilege(
                      'authenticated',oid,'EXECUTE'
                  ))
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'authenticated_execute',COALESCE(bool_and(
                has_function_privilege('authenticated',oid,'EXECUTE')
            ),FALSE)
        )
    FROM routine
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
