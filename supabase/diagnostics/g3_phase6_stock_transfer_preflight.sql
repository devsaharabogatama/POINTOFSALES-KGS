-- G3 phase 6 preflight: canonical Stock Transfer document readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Product/business rows.
--
-- PURPOSE:
-- - retire the unsafe legacy transfer path behind a canonical Draft/Posted
--   source document;
-- - preserve Base-UOM, FIFO value, tenant, idempotency, and immutable movement
--   invariants before any transfer migration is written.

WITH required_versions(version) AS (
    VALUES ('20260728150000')
), transfer_movements AS (
    SELECT *
    FROM public.stock_movements
    WHERE movement_type IN (
        'TRANSFER_IN'::public.stock_movement_type,
        'TRANSFER_OUT'::public.stock_movement_type
    )
), transfer_groups AS (
    SELECT
        company_id,
        reference_table,
        reference_id,
        product_id,
        count(*) FILTER (
            WHERE movement_type =
                'TRANSFER_OUT'::public.stock_movement_type
        ) AS out_rows,
        count(*) FILTER (
            WHERE movement_type =
                'TRANSFER_IN'::public.stock_movement_type
        ) AS in_rows,
        count(DISTINCT warehouse_id) AS warehouse_count,
        sum(qty_change) AS net_qty,
        abs(min(qty_change) FILTER (WHERE qty_change < 0)) AS out_qty,
        max(qty_change) FILTER (WHERE qty_change > 0) AS in_qty
    FROM transfer_movements
    GROUP BY company_id,reference_table,reference_id,product_id
), movement_totals AS (
    SELECT
        company_id,
        product_id,
        warehouse_id,
        sum(qty_change) AS movement_qty
    FROM public.stock_movements
    GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
    SELECT
        company_id,
        product_id,
        warehouse_id,
        sum(qty_remaining) AS remaining_qty
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), expected_transfer_tables(table_name) AS (
    VALUES
        ('stock_transfer_documents'),
        ('stock_transfer_lines'),
        ('stock_transfer_audit')
), checks AS (
    SELECT
        'g3_stock_transfer_dependency'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'invalid_existing_transfer_pair',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('group_count',count(*))
    FROM transfer_groups
    WHERE out_rows <> 1
       OR in_rows <> 1
       OR warehouse_count <> 2
       OR net_qty <> 0
       OR out_qty IS DISTINCT FROM in_qty

    UNION ALL

    SELECT
        'incomplete_existing_transfer_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM transfer_movements
    WHERE base_uom_id IS NULL
       OR base_uom_name_snapshot IS NULL
       OR balance_after_base_qty IS NULL
       OR actor_id IS NULL
       OR posted_at IS NULL
       OR source_line_id IS NULL
       OR movement_status <> 'POSTED'

    UNION ALL

    SELECT
        'legacy_transfer_movement_source',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM transfer_movements
    WHERE reference_table = 'product_stocks'

    UNION ALL

    SELECT
        'stock_balance_movement_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    FULL JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    WHERE ps.product_id IS NULL
       OR mt.product_id IS NULL
       OR ps.stock_qty IS DISTINCT FROM mt.movement_qty

    UNION ALL

    SELECT
        'negative_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks
    WHERE stock_qty < 0

    UNION ALL

    SELECT
        'fifo_remaining_balance_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    LEFT JOIN fifo_totals ft
      ON ft.company_id = ps.company_id
     AND ft.product_id = ps.product_id
     AND ft.warehouse_id = ps.warehouse_id
    WHERE ps.stock_qty > 0
      AND ps.stock_qty IS DISTINCT FROM COALESCE(ft.remaining_qty,0)

    UNION ALL

    SELECT
        'active_stock_product_without_valid_base_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM public.products p
    LEFT JOIN public.uoms u
      ON u.company_id = p.company_id
     AND u.id = p.uom_id
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
     AND pu.uom_id = p.uom_id
     AND pu.factor_to_base = 1
     AND pu.is_active
    WHERE p.is_active
      AND NOT p.is_bundle
      AND (
          p.uom_id IS NULL
          OR u.id IS NULL
          OR NOT u.is_active
          OR pu.id IS NULL
      )

    UNION ALL

    SELECT
        'active_company_stock_transfer_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.transaction_categories tc
          WHERE tc.company_id = c.id
            AND tc.system_key = 'STOCK_TRANSFER'
            AND tc.is_active
            AND tc.is_system_default
      )

    UNION ALL

    SELECT
        'canonical_stock_transfer_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE to_regclass(
                        'public.' || e.table_name
                    ) IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_transfer_tables e

    UNION ALL

    SELECT
        'legacy_transfer_rpc_state',
        CASE WHEN to_regprocedure(
            'public.transfer_product_stock(uuid,uuid,uuid,numeric)'
        ) IS NULL THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'exists',to_regprocedure(
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)'
            ) IS NOT NULL,
            'anon_execute',COALESCE(has_function_privilege(
                'anon',
                to_regprocedure(
                    'public.transfer_product_stock(uuid,uuid,uuid,numeric)'
                ),
                'EXECUTE'
            ),FALSE),
            'authenticated_execute',COALESCE(has_function_privilege(
                'authenticated',
                to_regprocedure(
                    'public.transfer_product_stock(uuid,uuid,uuid,numeric)'
                ),
                'EXECUTE'
            ),FALSE)
        )

    UNION ALL

    SELECT
        'direct_stock_write_privilege',
        'INFO',
        jsonb_build_object(
            'product_stocks_insert',has_table_privilege(
                'authenticated','public.product_stocks','INSERT'
            ),
            'product_stocks_update',has_table_privilege(
                'authenticated','public.product_stocks','UPDATE'
            ),
            'stock_movements_insert',has_table_privilege(
                'authenticated','public.stock_movements','INSERT'
            ),
            'stock_movements_update',has_table_privilege(
                'authenticated','public.stock_movements','UPDATE'
            )
        )

    UNION ALL

    SELECT
        'stock_transfer_eligibility_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'active_warehouses',(
                SELECT count(*) FROM public.warehouses WHERE is_active
            ),
            'companies_with_multiple_active_warehouses',(
                SELECT count(*)
                FROM (
                    SELECT company_id
                    FROM public.warehouses
                    WHERE is_active
                    GROUP BY company_id
                    HAVING count(*) >= 2
                ) companies
            ),
            'positive_source_balances',(
                SELECT count(*) FROM public.product_stocks WHERE stock_qty > 0
            ),
            'transfer_movement_rows',(SELECT count(*) FROM transfer_movements),
            'transfer_groups',(SELECT count(*) FROM transfer_groups)
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
