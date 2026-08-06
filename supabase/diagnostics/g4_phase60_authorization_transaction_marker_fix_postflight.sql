-- G4 phase 60 forward-fix 2 postflight. SELECT-only aggregate verification.

WITH guard_definition AS (
    SELECT pg_get_functiondef(
        'private.trg_g4_guard_offline_reserved_stock()'::regprocedure
    ) AS definition
), marker_definition AS (
    SELECT pg_get_functiondef(
        'private.trg_g4_mark_negative_stock_authorization()'::regprocedure
    ) AS definition
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260805233000'

    UNION ALL

    SELECT 'transaction_marker_trigger',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public'
      AND c.relname='pos_negative_stock_authorizations'
      AND t.tgname='g4_mark_negative_stock_authorization'
      AND NOT t.tgisinternal

    UNION ALL

    SELECT 'transaction_marker_routine_contract',
        CASE WHEN count(*) FILTER(
            WHERE definition ~* 'set_config'
              AND definition ~* 'kgs\.negative_stock_sale_id'
              AND definition ~* 'NEW\.sales_id'
        )=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) FILTER(
            WHERE definition ~* 'set_config'
              AND definition ~* 'kgs\.negative_stock_sale_id'
              AND definition ~* 'NEW\.sales_id'
        )=1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM marker_definition

    UNION ALL

    SELECT 'offline_guard_transaction_binding_contract',
        CASE WHEN count(*) FILTER(
            WHERE definition ~* 'current_setting'
              AND definition ~* 'kgs\.negative_stock_sale_id'
              AND definition ~* 'authz\.sales_id = v_authorized_sale_id'
              AND definition ~* 'v_reserved > 0'
        )=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) FILTER(
            WHERE definition ~* 'current_setting'
              AND definition ~* 'kgs\.negative_stock_sale_id'
              AND definition ~* 'authz\.sales_id = v_authorized_sale_id'
              AND definition ~* 'v_reserved > 0'
        )=1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM guard_definition
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
