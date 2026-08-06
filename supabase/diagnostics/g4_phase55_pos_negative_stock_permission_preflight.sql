-- G4 phase 55 preflight: explicitly authorized POS negative-stock readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - This audit does not enable negative stock or weaken current guards.

WITH required_versions(version) AS (
    VALUES ('20260805130000')
), expected_tables(table_name) AS (
    VALUES
        ('pos_negative_stock_policies'),
        ('pos_negative_stock_permissions'),
        ('pos_negative_stock_authorizations'),
        ('negative_stock_sale_allocations'),
        ('negative_stock_replenishment_allocations')
), sale_runtime AS (
    SELECT COALESCE(string_agg(pg_get_functiondef(routine.oid),'\n'),'') AS body
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='private'
      AND routine.proname IN ('post_pos_sale_core','post_pos_sale_online_core')
), warehouse_guard AS (
    SELECT COALESCE(string_agg(pg_get_constraintdef(item.oid),' '),'') AS body
    FROM pg_constraint item
    JOIN pg_class table_row ON table_row.oid=item.conrelid
    JOIN pg_namespace namespace ON namespace.oid=table_row.relnamespace
    WHERE namespace.nspname='public'
      AND table_row.relname='warehouses'
      AND item.conname='warehouses_nonnegative_only_check'
), checks AS (
    SELECT
        'g4_phase55_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER(WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'existing_negative_stock_balance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks stock
    WHERE stock.stock_qty<0

    UNION ALL

    SELECT
        'existing_negative_fifo_layer',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_batches batch
    WHERE batch.qty_remaining<0 OR batch.qty_purchased<0

    UNION ALL

    SELECT
        'stock_balance_fifo_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT
            stock.company_id,stock.product_id,stock.warehouse_id,
            stock.stock_qty,
            COALESCE(sum(batch.qty_remaining),0) AS fifo_qty
        FROM public.product_stocks stock
        LEFT JOIN public.product_batches batch
          ON batch.company_id=stock.company_id
         AND batch.product_id=stock.product_id
         AND batch.warehouse_id=stock.warehouse_id
        GROUP BY stock.company_id,stock.product_id,stock.warehouse_id,
                 stock.stock_qty
        HAVING stock.stock_qty<>COALESCE(sum(batch.qty_remaining),0)
    ) mismatch

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT
            stock.company_id,stock.product_id,stock.warehouse_id,
            stock.stock_qty,
            COALESCE(sum(movement.qty_change),0) AS movement_qty
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

    SELECT
        'posted_sale_without_fifo_cost_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM public.sales_details detail
    JOIN public.sales_headers sale
      ON sale.company_id=detail.company_id AND sale.id=detail.sales_id
    WHERE sale.document_status='POSTED'
      AND NOT EXISTS (
          SELECT 1 FROM public.products product
          WHERE product.company_id=detail.company_id
            AND product.id=detail.product_id
            AND product.is_bundle
      )
      AND detail.quantity_base>0
      AND NOT EXISTS (
          SELECT 1 FROM public.sale_fifo_allocations allocation
          WHERE allocation.company_id=detail.company_id
            AND allocation.sales_detail_id=detail.id
      )

    UNION ALL

    SELECT
        'warehouse_negative_stock_guard_state',
        CASE WHEN body~*'allow_negative_stock = false'
             THEN 'SETUP' ELSE 'REVIEW' END,
        jsonb_build_object(
            'hard_false_guard_present',body~*'allow_negative_stock = false'
        )
    FROM warehouse_guard

    UNION ALL

    SELECT
        'canonical_negative_stock_schema_state',
        CASE WHEN count(*) FILTER(WHERE table_state.table_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER(WHERE table_state.table_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_tables expected
    LEFT JOIN information_schema.tables table_state
      ON table_state.table_schema='public'
     AND table_state.table_name=expected.table_name

    UNION ALL

    SELECT
        'canonical_sale_shortage_runtime_state',
        CASE WHEN body~'STOCK_SHORTAGE'
                   AND body!~'NEGATIVE_STOCK_AUTHORIZATION'
             THEN 'SETUP' ELSE 'REVIEW' END,
        jsonb_build_object(
            'shortage_draft_guard_present',body~'STOCK_SHORTAGE',
            'negative_authorization_present',
                body~'NEGATIVE_STOCK_AUTHORIZATION'
        )
    FROM sale_runtime

    UNION ALL

    SELECT
        'active_sale_source_warehouse_inventory',
        'INFO',
        jsonb_build_object(
            'warehouses',count(*),
            'companies',count(DISTINCT warehouse.company_id),
            'allow_negative_stock_true',count(*) FILTER(
                WHERE warehouse.allow_negative_stock
            )
        )
    FROM public.warehouses warehouse
    WHERE warehouse.is_active AND warehouse.is_sale_source

    UNION ALL

    SELECT
        'negative_stock_cost_basis_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('product_warehouse_pairs',count(*))
    FROM (
        SELECT product.company_id,product.id,warehouse.id
        FROM public.products product
        JOIN public.warehouses warehouse
          ON warehouse.company_id=product.company_id
         AND warehouse.is_active
         AND warehouse.is_sale_source
        WHERE product.is_active AND NOT product.is_bundle
          AND NOT EXISTS (
              SELECT 1 FROM public.product_batches batch
              WHERE batch.company_id=product.company_id
                AND batch.product_id=product.id
                AND batch.warehouse_id=warehouse.id
                AND batch.cogs_unit>=0
          )
    ) missing_cost_basis

    UNION ALL

    SELECT
        'offline_negative_stock_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_stock_allowances allowance
    WHERE allowance.allocated_base_qty<0
       OR allowance.consumed_base_qty<0

    UNION ALL

    SELECT
        'browser_direct_negative_stock_write_boundary',
        'INFO',
        jsonb_build_object(
            'stock_update',has_table_privilege(
                'authenticated','public.product_stocks','UPDATE'
            ),
            'fifo_insert',has_table_privilege(
                'authenticated','public.product_batches','INSERT'
            ),
            'movement_insert',has_table_privilege(
                'authenticated','public.stock_movements','INSERT'
            ),
            'warehouse_update',has_table_privilege(
                'authenticated','public.warehouses','UPDATE'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
