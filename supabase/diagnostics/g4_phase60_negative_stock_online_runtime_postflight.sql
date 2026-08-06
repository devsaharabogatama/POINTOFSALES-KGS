-- G4 phase 60 postflight: controlled online negative-stock runtime.
-- SAFETY: SELECT-only and aggregate-only.
WITH core AS (
    SELECT pg_get_functiondef(
        'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) body
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations WHERE version='20260805220000'
    UNION ALL
    SELECT 'required_negative_stock_runtime_routines',
        CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,3-count(*),
        jsonb_build_object('expected',3,'routine_rows',count(*))
    FROM pg_proc routine JOIN pg_namespace namespace
      ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='private' AND routine.proname IN(
        'authorize_pos_negative_stock',
        'resolve_pos_negative_stock_provisional_cost',
        'reconcile_negative_stock_replenishment'
    )
    UNION ALL
    SELECT 'online_sale_negative_stock_contract',
        CASE WHEN body~'authorize_pos_negative_stock'
                  AND body~'pos_negative_stock_authorizations'
                  AND body~'negative_stock_sale_allocations'
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN body~'authorize_pos_negative_stock'
                  AND body~'pos_negative_stock_authorizations'
                  AND body~'negative_stock_sale_allocations'
             THEN 0 ELSE 1 END,jsonb_build_object('routine_rows',1)
    FROM core
    UNION ALL
    SELECT 'negative_movement_guard_contract',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,2-count(*),
        jsonb_build_object('expected',2,'object_rows',count(*))
    FROM (
        SELECT constraint_row.oid FROM pg_constraint constraint_row
        JOIN pg_class table_row ON table_row.oid=constraint_row.conrelid
        JOIN pg_namespace namespace ON namespace.oid=table_row.relnamespace
        WHERE namespace.nspname='public' AND table_row.relname='stock_movements'
          AND constraint_row.conname='stock_movements_balance_after_controlled'
        UNION ALL
        SELECT trigger_row.oid FROM pg_trigger trigger_row
        WHERE trigger_row.tgname='g4_guard_negative_sale_movement'
          AND NOT trigger_row.tgisinternal
    ) state
    UNION ALL
    SELECT 'replenishment_trigger_contract',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgname='g4_reconcile_negative_stock_replenishment'
      AND NOT trigger_row.tgisinternal
    UNION ALL
    SELECT 'negative_stock_entitlement_remains_default_off',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('enabled_companies',count(*))
    FROM public.company_features feature
    WHERE feature.feature_code='pos_negative_stock_enabled'
      AND feature.is_enabled
    UNION ALL
    SELECT 'negative_stock_balance_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT stock.company_id,stock.product_id,stock.warehouse_id
        FROM public.product_stocks stock
        WHERE stock.stock_qty<>
            COALESCE((SELECT sum(batch.qty_remaining)
                FROM public.product_batches batch
                WHERE batch.company_id=stock.company_id
                  AND batch.product_id=stock.product_id
                  AND batch.warehouse_id=stock.warehouse_id),0)
            -COALESCE((SELECT sum(allocation.shortage_base_qty
                                  -allocation.replenished_base_qty)
                FROM public.negative_stock_sale_allocations allocation
                WHERE allocation.company_id=stock.company_id
                  AND allocation.stock_product_id=stock.product_id
                  AND allocation.warehouse_id=stock.warehouse_id
                  AND allocation.reconciled_at IS NULL),0)
    ) mismatch
    UNION ALL
    SELECT 'stock_balance_movement_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT stock.company_id,stock.product_id,stock.warehouse_id
        FROM public.product_stocks stock
        LEFT JOIN public.stock_movements movement
          ON movement.company_id=stock.company_id
         AND movement.product_id=stock.product_id
         AND movement.warehouse_id=stock.warehouse_id
         AND movement.movement_status='POSTED'
        GROUP BY stock.company_id,stock.product_id,stock.warehouse_id,
                 stock.stock_qty
        HAVING stock.stock_qty<>COALESCE(sum(movement.qty_change),0)
    ) mismatch
    UNION ALL
    SELECT 'negative_allocation_replenishment_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('allocation_count',count(*))
    FROM public.negative_stock_sale_allocations allocation
    WHERE allocation.replenished_base_qty<>COALESCE((
        SELECT sum(item.replenished_base_qty)
        FROM public.negative_stock_replenishment_allocations item
        WHERE item.company_id=allocation.company_id
          AND item.negative_sale_allocation_id=allocation.id
    ),0)
    UNION ALL
    SELECT 'offline_negative_stock_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_sale_submissions submission
    WHERE submission.payload_snapshot::TEXT~'negativeStockReason'
    UNION ALL
    SELECT 'browser_negative_stock_runtime_boundary',
        CASE WHEN NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_authorizations','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.negative_stock_sale_allocations','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.product_stocks','UPDATE')
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_authorizations','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.negative_stock_sale_allocations','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.product_stocks','UPDATE') THEN 0 ELSE 1 END,
        jsonb_build_object('direct_stock_update',has_table_privilege(
            'authenticated','public.product_stocks','UPDATE'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
