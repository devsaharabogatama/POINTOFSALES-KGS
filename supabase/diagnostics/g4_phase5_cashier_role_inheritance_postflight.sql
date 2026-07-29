-- G4 phase 5 Cashier role-inheritance forward-fix postflight.
-- SAFETY: SELECT-only.

WITH checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*) AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729080000'

    UNION ALL

    SELECT
        'open_session_routine_count',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'open_cashier_session'
      AND pg_get_function_identity_arguments(p.oid)
          = 'p_pos_terminal_id uuid, p_sales_warehouse_id uuid, p_opening_cash_actual numeric'

    UNION ALL

    SELECT
        'approved_role_inheritance_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1),
        jsonb_build_object('matching_routines',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'open_cashier_session'
      AND p.prosrc LIKE '%private_is_super_admin(v_actor)%'
      AND p.prosrc LIKE '%COMPANY_OWNER%'
      AND p.prosrc LIKE '%COMPANY_ADMIN%'
      AND p.prosrc LIKE '%ACTIVE_CASHIER_ASSIGNMENT_REQUIRED%'

    UNION ALL

    SELECT
        'browser_execute_boundary',
        CASE
            WHEN has_function_privilege(
                'authenticated',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
             AND NOT has_function_privilege(
                'anon',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
            THEN 'PASS' ELSE 'FAIL'
        END,
        CASE
            WHEN has_function_privilege(
                'authenticated',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
             AND NOT has_function_privilege(
                'anon',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
            THEN 0 ELSE 1
        END,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            ),
            'anon_execute',has_function_privilege(
                'anon',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
