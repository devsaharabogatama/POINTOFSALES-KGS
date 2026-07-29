-- G2 phase 46 preflight: Product-Warehouse minimum-stock readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Product/Warehouse names.
-- - Minimum stock is configuration only. This diagnostic never changes
--   product_stocks, stock_movements, or creates a Stock Request.

WITH required_versions(version) AS (
    VALUES ('20260727160000')
), expected_setting_columns(column_name) AS (
    VALUES
        ('id'),('company_id'),('product_id'),('warehouse_id'),
        ('minimum_stock_base_qty'),('low_stock_alert_enabled'),
        ('master_version'),('created_by'),('updated_by'),
        ('created_at'),('updated_at')
), normalized_active_references AS (
    SELECT
        'PRODUCT_SKU'::TEXT AS reference_type,
        p.company_id,
        upper(regexp_replace(btrim(p.sku),'\s+',' ','g')) AS value
    FROM public.products p
    WHERE p.is_active
      AND NOT p.is_bundle

    UNION ALL

    SELECT
        'WAREHOUSE_NAME',
        w.company_id,
        lower(regexp_replace(btrim(w.name),'\s+',' ','g'))
    FROM public.warehouses w
    WHERE w.is_active
), active_stock_product_readiness AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        count(pu.id) FILTER (
            WHERE pu.uom_id = p.uom_id
              AND pu.factor_to_base = 1
              AND pu.is_active
              AND u.id IS NOT NULL
              AND u.is_active
        ) AS valid_active_base_rows
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
    LEFT JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
    WHERE p.is_active
      AND NOT p.is_bundle
    GROUP BY p.company_id,p.id
), eligible_pairs AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        w.id AS warehouse_id
    FROM public.products p
    JOIN public.warehouses w
      ON w.company_id = p.company_id
     AND w.is_active
    WHERE p.is_active
      AND NOT p.is_bundle
), movement_pairs AS (
    SELECT DISTINCT company_id,product_id,warehouse_id
    FROM public.stock_movements
), checks AS (
    SELECT
        'g2_phase44_dependency'::TEXT AS check_name,
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
        'canonical_minimum_stock_schema_state',
        'INFO',
        jsonb_build_object(
            'settings_table_exists',
                to_regclass(
                    'public.product_warehouse_stock_settings'
                ) IS NOT NULL,
            'missing_setting_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            ),
            'minimum_stock_job_type_supported',
                COALESCE((
                    SELECT bool_or(
                        position(
                            'PRODUCT_WAREHOUSE_MINIMUM_STOCK'
                            IN pg_get_constraintdef(con.oid)
                        ) > 0
                    )
                    FROM pg_constraint con
                    JOIN pg_class rel ON rel.oid = con.conrelid
                    JOIN pg_namespace n ON n.oid = rel.relnamespace
                    WHERE n.nspname = 'public'
                      AND rel.relname = 'master_import_jobs'
                      AND con.conname = 'master_import_jobs_type_check'
                ),FALSE),
            'guarded_save_rpc_exists',
                to_regprocedure(
                    'public.save_product_warehouse_stock_setting(uuid,bigint,uuid,uuid,numeric,boolean)'
                ) IS NOT NULL
        )
    FROM expected_setting_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'product_warehouse_stock_settings'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'blank_active_import_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM normalized_active_references
    WHERE value = ''

    UNION ALL

    SELECT
        'ambiguous_active_import_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'duplicate_groups',count(*),
            'reference_types',COALESCE(
                jsonb_agg(DISTINCT reference_type),
                '[]'::JSONB
            )
        )
    FROM (
        SELECT reference_type,company_id,value
        FROM normalized_active_references
        GROUP BY reference_type,company_id,value
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'active_stock_product_without_valid_base_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM active_stock_product_readiness
    WHERE valid_active_base_rows <> 1

    UNION ALL

    SELECT
        'invalid_existing_product_stock_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks ps
    LEFT JOIN public.products p
      ON p.company_id = ps.company_id
     AND p.id = ps.product_id
    LEFT JOIN public.warehouses w
      ON w.company_id = ps.company_id
     AND w.id = ps.warehouse_id
    WHERE p.id IS NULL OR w.id IS NULL

    UNION ALL

    SELECT
        'duplicate_product_warehouse_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,product_id,warehouse_id
        FROM public.product_stocks
        GROUP BY company_id,product_id,warehouse_id
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'negative_product_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks
    WHERE stock_qty < 0

    UNION ALL

    SELECT
        'movement_pair_without_materialized_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM movement_pairs mp
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = mp.company_id
     AND ps.product_id = mp.product_id
     AND ps.warehouse_id = mp.warehouse_id
    WHERE ps.id IS NULL

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'job_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status NOT IN (
        'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
    )

    UNION ALL

    SELECT
        'direct_stock_balance_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert',has_table_privilege(
                'authenticated','public.product_stocks','INSERT'
            ),
            'authenticated_update',has_table_privilege(
                'authenticated','public.product_stocks','UPDATE'
            ),
            'authenticated_delete',has_table_privilege(
                'authenticated','public.product_stocks','DELETE'
            )
        )

    UNION ALL

    SELECT
        'minimum_stock_eligibility_inventory',
        'INFO',
        jsonb_build_object(
            'eligible_pairs',count(*),
            'companies',count(DISTINCT company_id),
            'products',count(DISTINCT product_id),
            'warehouses',count(DISTINCT warehouse_id),
            'pairs_with_balance',count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1
                    FROM public.product_stocks ps
                    WHERE ps.company_id = eligible_pairs.company_id
                      AND ps.product_id = eligible_pairs.product_id
                      AND ps.warehouse_id = eligible_pairs.warehouse_id
                )
            ),
            'pairs_with_movement',count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1
                    FROM movement_pairs mp
                    WHERE mp.company_id = eligible_pairs.company_id
                      AND mp.product_id = eligible_pairs.product_id
                      AND mp.warehouse_id = eligible_pairs.warehouse_id
                )
            )
        )
    FROM eligible_pairs

    UNION ALL

    SELECT
        'stock_balance_inventory',
        'INFO',
        jsonb_build_object(
            'balance_rows',count(*),
            'active_pair_rows',count(*) FILTER (
                WHERE p.is_active
                  AND NOT p.is_bundle
                  AND w.is_active
            ),
            'inactive_or_bundle_pair_rows',count(*) FILTER (
                WHERE NOT p.is_active
                   OR p.is_bundle
                   OR NOT w.is_active
            ),
            'zero_balance_rows',count(*) FILTER (WHERE ps.stock_qty = 0)
        )
    FROM public.product_stocks ps
    JOIN public.products p
      ON p.company_id = ps.company_id
     AND p.id = ps.product_id
    JOIN public.warehouses w
      ON w.company_id = ps.company_id
     AND w.id = ps.warehouse_id
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'PASS' THEN 2
        ELSE 3
    END,
    check_name;
