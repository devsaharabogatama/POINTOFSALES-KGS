-- G6 corrective phase 1 quarantine postflight.
-- SAFETY: SELECT-only aggregate metadata; no routine execution or business row.

WITH unsafe_routine_names(routine_name) AS (
    VALUES
        ('post_financial_event'),('post_pending_financial_events'),
        ('ensure_accounting_period_open'),('resolve_account_for_function'),
        ('resolve_account_by_code'),('get_general_ledger_report'),
        ('get_trial_balance_report'),('get_income_statement_report'),
        ('get_balance_sheet_report'),('get_account_journal_lines')
), routines AS (
    SELECT routine.oid,routine.proname
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    JOIN unsafe_routine_names unsafe ON unsafe.routine_name = routine.proname
    WHERE namespace.nspname = 'public'
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260810170000'

    UNION ALL

    SELECT
        'browser_finance_routine_execution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'executable_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(DISTINCT proname ORDER BY proname),
                '[]'::jsonb
            )
        )
    FROM routines
    WHERE has_function_privilege('authenticated',oid,'EXECUTE')
       OR has_function_privilege('anon',oid,'EXECUTE')

    UNION ALL

    SELECT
        'service_role_finance_routine_execution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'missing_execute_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(DISTINCT proname ORDER BY proname),
                '[]'::jsonb
            )
        )
    FROM routines
    WHERE NOT has_function_privilege('service_role',oid,'EXECUTE')

    UNION ALL

    SELECT
        'quarantined_finance_routine_inventory',
        'INFO',
        0,
        jsonb_build_object(
            'routine_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(DISTINCT proname ORDER BY proname),
                '[]'::jsonb
            )
        )
    FROM routines
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
