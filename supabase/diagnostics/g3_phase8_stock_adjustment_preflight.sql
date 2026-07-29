-- G3 phase 8 preflight: canonical Stock Adjustment readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Product/business rows.
--
-- PURPOSE:
-- - replace the legacy one-row Adjustment record with a canonical
--   Draft/Posted/Canceled source document;
-- - establish Adjustment before Stock Opname because posted Opname creates
--   Adjustment for its variance lines;
-- - verify Base-UOM, balance, FIFO valuation, reason, tenant, role, and
--   Finance readiness before any migration is written.

WITH required_versions(version) AS (
    VALUES ('20260728180000')
), normalized_legacy_adjustments AS (
    SELECT
        a.*,
        lower(regexp_replace(btrim(COALESCE(a.reason,'')),'\s+',' ','g'))
            AS normalized_reason
    FROM public.stock_adjustments a
), adjustment_movements AS (
    SELECT *
    FROM public.stock_movements
    WHERE movement_type = 'ADJUSTMENT'::public.stock_movement_type
       OR reference_table = 'stock_adjustments'
), movement_totals AS (
    SELECT
        company_id,product_id,warehouse_id,sum(qty_change) AS movement_qty
    FROM public.stock_movements
    GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
    SELECT
        company_id,product_id,warehouse_id,
        sum(qty_remaining) AS remaining_qty
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), required_finance_functions(function_key) AS (
    VALUES ('INVENTORY_ASSET'),('STOCK_GAIN_INCOME'),('STOCK_LOSS_EXPENSE')
), company_finance_readiness AS (
    SELECT c.id AS company_id,f.function_key
    FROM public.companies c
    CROSS JOIN required_finance_functions f
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.chart_of_accounts coa
          WHERE coa.company_id = c.id
            AND coa.system_function_key = f.function_key
            AND coa.is_active
            AND coa.is_postable
      )
      AND NOT EXISTS (
          SELECT 1
          FROM public.company_account_function_fallbacks af
          JOIN public.chart_of_accounts coa
            ON coa.company_id = af.company_id
           AND coa.id = af.account_id
           AND coa.is_active
           AND coa.is_postable
          WHERE af.company_id = c.id
            AND af.account_function_key = f.function_key
            AND af.status = 'ACTIVE'
            AND af.effective_from <= clock_timestamp()
            AND (
                af.effective_to IS NULL
                OR af.effective_to > clock_timestamp()
            )
      )
), required_system_keys(system_key) AS (
    VALUES ('STOCK_GAIN'),('STOCK_LOSS')
), expected_adjustment_tables(table_name) AS (
    VALUES
        ('stock_adjustment_reasons'),
        ('stock_adjustment_documents'),
        ('stock_adjustment_lines'),
        ('stock_adjustment_fifo_allocations'),
        ('stock_adjustment_audit')
), checks AS (
    SELECT
        'g3_stock_adjustment_dependency'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'invalid_legacy_adjustment_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM normalized_legacy_adjustments
    WHERE qty_adjusted = 0
       OR cogs_unit < 0
       OR normalized_reason = ''

    UNION ALL

    SELECT
        'legacy_adjustment_without_movement',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM normalized_legacy_adjustments a
    WHERE NOT EXISTS (
        SELECT 1
        FROM adjustment_movements sm
        WHERE sm.company_id = a.company_id
          AND sm.product_id = a.product_id
          AND sm.warehouse_id = a.warehouse_id
          AND sm.qty_change = a.qty_adjusted
          AND (
              sm.reference_id = a.id
              OR (
                  a.opname_detail_id IS NOT NULL
                  AND sm.reference_id = a.opname_detail_id
              )
          )
    )

    UNION ALL

    SELECT
        'legacy_adjustment_movement_without_source',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM adjustment_movements sm
    WHERE sm.reference_table = 'stock_adjustments'
      AND NOT EXISTS (
          SELECT 1
          FROM normalized_legacy_adjustments a
          WHERE a.company_id = sm.company_id
            AND a.product_id = sm.product_id
            AND a.warehouse_id = sm.warehouse_id
            AND a.qty_adjusted = sm.qty_change
            AND (
                sm.reference_id = a.id
                OR (
                    a.opname_detail_id IS NOT NULL
                    AND sm.reference_id = a.opname_detail_id
                )
            )
      )

    UNION ALL

    SELECT
        'incomplete_existing_adjustment_movement_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count',count(*))
    FROM adjustment_movements
    WHERE base_uom_id IS NULL
       OR base_uom_name_snapshot IS NULL
       OR balance_after_base_qty IS NULL
       OR actor_id IS NULL
       OR posted_at IS NULL
       OR source_line_id IS NULL
       OR movement_status <> 'POSTED'

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
        'invalid_fifo_batch_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_batches
    WHERE qty_purchased <= 0
       OR qty_remaining < 0
       OR qty_remaining > qty_purchased
       OR cogs_unit < 0

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
        'active_company_adjustment_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'missing_company_category_rows',count(*),
            'companies_affected',count(DISTINCT c.id)
        )
    FROM public.companies c
    CROSS JOIN required_system_keys k
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.transaction_categories tc
          WHERE tc.company_id = c.id
            AND tc.system_key = k.system_key
            AND tc.is_active
            AND tc.is_system_default
      )

    UNION ALL

    SELECT
        'stock_adjustment_finance_function_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'missing_company_function_rows',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM company_finance_readiness

    UNION ALL

    SELECT
        'canonical_stock_adjustment_schema_state',
        'INFO',
        jsonb_build_object(
            'legacy_table_exists',
                to_regclass('public.stock_adjustments') IS NOT NULL,
            'missing_tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (
                        WHERE to_regclass('public.' || e.table_name) IS NULL
                    ),
                '[]'::JSONB
            ),
            'save_rpc_exists',to_regprocedure(
                'public.save_stock_adjustment_document(uuid,bigint,uuid,date,text,jsonb)'
            ) IS NOT NULL,
            'post_rpc_exists',to_regprocedure(
                'public.post_stock_adjustment(uuid,bigint,uuid)'
            ) IS NOT NULL
        )
    FROM expected_adjustment_tables e

    UNION ALL

    SELECT
        'direct_adjustment_write_privilege',
        'INFO',
        jsonb_build_object(
            'legacy_adjustment_insert',has_table_privilege(
                'authenticated','public.stock_adjustments','INSERT'
            ),
            'legacy_adjustment_update',has_table_privilege(
                'authenticated','public.stock_adjustments','UPDATE'
            ),
            'product_stocks_update',has_table_privilege(
                'authenticated','public.product_stocks','UPDATE'
            ),
            'stock_movements_insert',has_table_privilege(
                'authenticated','public.stock_movements','INSERT'
            )
        )

    UNION ALL

    SELECT
        'legacy_adjustment_reason_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'adjustment_rows',count(*),
            'normalized_reason_groups',count(DISTINCT (
                company_id,normalized_reason
            ))
        )
    FROM normalized_legacy_adjustments

    UNION ALL

    SELECT
        'stock_adjustment_inventory',
        'INFO',
        jsonb_build_object(
            'legacy_adjustments',(
                SELECT count(*) FROM normalized_legacy_adjustments
            ),
            'legacy_opname_linked_adjustments',(
                SELECT count(*) FROM normalized_legacy_adjustments
                WHERE opname_detail_id IS NOT NULL
            ),
            'adjustment_movement_rows',(
                SELECT count(*) FROM adjustment_movements
            ),
            'positive_balance_pairs',(
                SELECT count(*) FROM public.product_stocks WHERE stock_qty > 0
            ),
            'zero_balance_pairs',(
                SELECT count(*) FROM public.product_stocks WHERE stock_qty = 0
            ),
            'positive_fifo_layers',(
                SELECT count(*) FROM public.product_batches
                WHERE qty_remaining > 0
            ),
            'zero_cost_positive_fifo_layers',(
                SELECT count(*) FROM public.product_batches
                WHERE qty_remaining > 0 AND cogs_unit = 0
            )
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
