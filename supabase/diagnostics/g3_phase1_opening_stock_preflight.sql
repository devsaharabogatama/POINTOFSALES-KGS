-- G3 phase 1 preflight: canonical Opening Stock posting readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Product/Gudang/business row details.

WITH required_versions(version) AS (
    VALUES ('20260722230000'), ('20260728090000')
), active_stock_products AS (
    SELECT p.id,p.company_id,p.uom_id
    FROM public.products p
    WHERE p.is_active AND NOT p.is_bundle
), eligible_pairs AS (
    SELECT p.company_id,p.id AS product_id,w.id AS warehouse_id
    FROM active_stock_products p
    JOIN public.warehouses w
      ON w.company_id = p.company_id
     AND w.is_active
    WHERE EXISTS (
        SELECT 1
        FROM public.product_uoms pu
        JOIN public.uoms u
          ON u.company_id = pu.company_id
         AND u.id = pu.uom_id
         AND u.is_active
        WHERE pu.company_id = p.company_id
          AND pu.product_id = p.id
          AND pu.uom_id = p.uom_id
          AND pu.factor_to_base = 1
          AND pu.is_active
    )
), movement_totals AS (
    SELECT company_id,product_id,warehouse_id,sum(qty_change) AS movement_qty
    FROM public.stock_movements
    GROUP BY company_id,product_id,warehouse_id
), batch_totals AS (
    SELECT
        company_id,product_id,warehouse_id,
        sum(qty_remaining) AS remaining_qty
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), required_finance_functions(function_key) AS (
    VALUES ('INVENTORY_ASSET'),('OPENING_BALANCE_CLEARING')
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
), expected_opening_columns(column_name) AS (
    VALUES
        ('company_id'),('warehouse_id'),('effective_date'),('status'),
        ('source_import_job_id'),('posted_by'),('posted_at'),
        ('master_version'),('created_by'),('updated_by')
), checks AS (
    SELECT
        'g3_opening_stock_dependencies'::TEXT AS check_name,
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
        'opening_stock_schema_state',
        'INFO',
        jsonb_build_object(
            'documents_table_exists',
                to_regclass('public.opening_stock_documents') IS NOT NULL,
            'lines_table_exists',
                to_regclass('public.opening_stock_lines') IS NOT NULL,
            'posting_rpc_exists',EXISTS (
                SELECT 1
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = 'public'
                  AND p.proname = 'post_opening_stock'
            ),
            'expected_document_columns',
                (SELECT count(*) FROM expected_opening_columns)
        )

    UNION ALL

    SELECT
        'stock_movement_enum_state',
        'INFO',
        jsonb_build_object(
            'labels',COALESCE(jsonb_agg(e.enumlabel ORDER BY e.enumsortorder),'[]'),
            'opening_balance_exists',COALESCE(
                bool_or(e.enumlabel = 'OPENING_BALANCE'),FALSE
            )
        )
    FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE t.typname = 'stock_movement_type'

    UNION ALL

    SELECT
        'financial_event_enum_state',
        'INFO',
        jsonb_build_object(
            'opening_stock_event_exists',COALESCE(
                bool_or(e.enumlabel IN ('OPENING_BALANCE','STOCK_OPENING')),
                FALSE
            )
        )
    FROM pg_type t
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE t.typname = 'event_type'

    UNION ALL

    SELECT
        'active_stock_product_without_valid_base_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM active_stock_products p
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.product_uoms pu
        JOIN public.uoms u
          ON u.company_id = pu.company_id
         AND u.id = pu.uom_id
         AND u.is_active
        WHERE pu.company_id = p.company_id
          AND pu.product_id = p.id
          AND pu.uom_id = p.uom_id
          AND pu.factor_to_base = 1
          AND pu.is_active
    )

    UNION ALL

    SELECT
        'ambiguous_active_product_sku',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,upper(regexp_replace(btrim(sku),'\s+',' ','g'))
        FROM public.products
        WHERE is_active AND NOT is_bundle
        GROUP BY company_id,upper(regexp_replace(btrim(sku),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'ambiguous_active_warehouse_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,
            lower(regexp_replace(btrim(name),'\s+',' ','g'))
        FROM public.warehouses
        WHERE is_active
        GROUP BY
            company_id,
            lower(regexp_replace(btrim(name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'invalid_product_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks
    WHERE stock_qty < 0

    UNION ALL

    SELECT
        'duplicate_product_warehouse_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,product_id,warehouse_id
        FROM public.product_stocks
        GROUP BY company_id,product_id,warehouse_id
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'invalid_stock_movement_quantity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements
    WHERE qty_change = 0

    UNION ALL

    SELECT
        'movement_pair_without_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM movement_totals m
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = m.company_id
     AND ps.product_id = m.product_id
     AND ps.warehouse_id = m.warehouse_id
    WHERE ps.id IS NULL

    UNION ALL

    SELECT
        'stock_balance_movement_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    LEFT JOIN movement_totals m
      ON m.company_id = ps.company_id
     AND m.product_id = ps.product_id
     AND m.warehouse_id = ps.warehouse_id
    WHERE ps.stock_qty <> COALESCE(m.movement_qty,0)

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
        'fifo_remaining_balance_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('pair_count',count(*))
    FROM batch_totals b
    JOIN public.product_stocks ps
      ON ps.company_id = b.company_id
     AND ps.product_id = b.product_id
     AND ps.warehouse_id = b.warehouse_id
    WHERE b.remaining_qty <> ps.stock_qty

    UNION ALL

    SELECT
        'opening_stock_finance_function_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'missing_company_function_rows',count(*),
            'companies_affected',count(DISTINCT company_id)
        )
    FROM company_finance_readiness

    UNION ALL

    SELECT
        'opening_stock_transaction_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.transaction_categories tc
          WHERE tc.company_id = c.id
            AND tc.system_key = 'STOCK_OPENING'
            AND tc.is_active
      )

    UNION ALL

    SELECT
        'opening_stock_eligibility_inventory',
        'INFO',
        jsonb_build_object(
            'eligible_pairs',count(*),
            'pairs_without_movement',count(*) FILTER (
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.stock_movements sm
                    WHERE sm.company_id = e.company_id
                      AND sm.product_id = e.product_id
                      AND sm.warehouse_id = e.warehouse_id
                )
            ),
            'pairs_with_movement',count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM public.stock_movements sm
                    WHERE sm.company_id = e.company_id
                      AND sm.product_id = e.product_id
                      AND sm.warehouse_id = e.warehouse_id
                )
            )
        )
    FROM eligible_pairs e

    UNION ALL

    SELECT
        'existing_stock_inventory',
        'INFO',
        jsonb_build_object(
            'balance_rows',(SELECT count(*) FROM public.product_stocks),
            'movement_rows',(SELECT count(*) FROM public.stock_movements),
            'batch_rows',(SELECT count(*) FROM public.product_batches),
            'zero_cost_batches',(
                SELECT count(*) FROM public.product_batches WHERE cogs_unit = 0
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'PASS' THEN 3
        ELSE 4
    END,
    check_name;
