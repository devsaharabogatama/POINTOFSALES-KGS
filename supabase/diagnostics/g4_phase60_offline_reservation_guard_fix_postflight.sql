-- G4 phase 60 forward-fix postflight. SELECT-only aggregate verification.

WITH function_contract AS (
    SELECT pg_get_functiondef(
        'private.trg_g4_guard_offline_reserved_stock()'::regprocedure
    ) AS definition
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260805230000'

    UNION ALL

    SELECT
        'offline_reservation_negative_sale_contract',
        CASE WHEN count(*) FILTER (
            WHERE definition ~* 'v_reserved > 0'
              AND definition ~* 'pos_negative_stock_authorizations'
              AND definition ~* 'transaction_timestamp'
              AND definition ~* 'document_status::text = ''DRAFT'''
        ) = 1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) FILTER (
            WHERE definition ~* 'v_reserved > 0'
              AND definition ~* 'pos_negative_stock_authorizations'
              AND definition ~* 'transaction_timestamp'
              AND definition ~* 'document_status::text = ''DRAFT'''
        ) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM function_contract

    UNION ALL

    SELECT
        'offline_stock_guard_triggers',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 3 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'product_stocks'
      AND t.tgname IN (
          'g4_guard_offline_reserved_stock',
          'g4_guard_offline_reserved_stock_delete',
          'g4_guard_offline_reserved_stock_insert'
      )
      AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'active_offline_reservation_within_stock',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT allowance.company_id,allowance.product_id,allowance.warehouse_id
        FROM public.pos_offline_stock_allowances allowance
        JOIN public.product_stocks stock
          ON stock.company_id = allowance.company_id
         AND stock.product_id = allowance.product_id
         AND stock.warehouse_id = allowance.warehouse_id
        WHERE allowance.status = 'ACTIVE'
        GROUP BY allowance.company_id,allowance.product_id,
            allowance.warehouse_id,stock.stock_qty
        HAVING sum(
            allowance.allocated_base_qty - allowance.consumed_base_qty
        ) > stock.stock_qty
    ) invalid_pairs
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
