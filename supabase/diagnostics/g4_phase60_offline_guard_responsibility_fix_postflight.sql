-- G4 phase 60 forward-fix 3 postflight. SELECT-only aggregate verification.

WITH guard_definition AS (
    SELECT pg_get_functiondef(
        'private.trg_g4_guard_offline_reserved_stock()'::regprocedure
    ) AS definition
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260805234500'

    UNION ALL

    SELECT 'offline_guard_single_responsibility',
        CASE WHEN count(*) FILTER(
            WHERE definition ~* 'v_reserved > 0'
              AND definition ~* 'NEW\.stock_qty < v_reserved'
              AND definition !~* 'pos_negative_stock_authorizations'
              AND definition !~* 'current_setting'
        )=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) FILTER(
            WHERE definition ~* 'v_reserved > 0'
              AND definition ~* 'NEW\.stock_qty < v_reserved'
              AND definition !~* 'pos_negative_stock_authorizations'
              AND definition !~* 'current_setting'
        )=1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM guard_definition

    UNION ALL

    SELECT 'obsolete_transaction_marker_removed',
        CASE WHEN to_regprocedure(
            'private.trg_g4_mark_negative_stock_authorization()'
        ) IS NULL AND count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN to_regprocedure(
            'private.trg_g4_mark_negative_stock_authorization()'
        ) IS NULL AND count(*)=0 THEN 0 ELSE 1 END,
        jsonb_build_object(
            'routine_exists',to_regprocedure(
                'private.trg_g4_mark_negative_stock_authorization()'
            ) IS NOT NULL,
            'trigger_rows',count(*)
        )
    FROM pg_trigger t
    WHERE t.tgname='g4_mark_negative_stock_authorization'
      AND NOT t.tgisinternal

    UNION ALL

    SELECT 'negative_movement_authorization_guard',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public'
      AND c.relname='stock_movements'
      AND t.tgname='g4_guard_negative_sale_movement'
      AND NOT t.tgisinternal
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
