-- G2 phase 4 preflight: canonical Product + Product-UOM atomic CRUD readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or privilege change.
-- - Returns aggregate counts only; no Product/master names or business rows.
-- - Run the entire file in Supabase SQL Editor and export the final result.

WITH company_readiness AS (
    SELECT
        c.id AS company_id,
        EXISTS (
            SELECT 1 FROM public.product_categories pc
            WHERE pc.company_id = c.id AND pc.is_active
        ) AS has_active_category,
        EXISTS (
            SELECT 1 FROM public.uoms u
            WHERE u.company_id = c.id AND u.is_active
        ) AS has_active_uom
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
), product_uom_summary AS (
    SELECT
        p.id AS product_id,
        count(pu.id) AS uom_count,
        count(pu.id) FILTER (
            WHERE pu.uom_id = p.uom_id
              AND pu.factor_to_base = 1
        ) AS valid_base_rows,
        count(pu.id) FILTER (
            WHERE pu.uom_id = p.weight_reference_uom_id
        ) AS weight_reference_rows,
        count(pu.id) FILTER (
            WHERE pu.sales_allowed AND pu.is_active
        ) AS active_sales_uoms,
        count(pu.id) FILTER (
            WHERE pu.purchase_allowed AND pu.is_active
        ) AS active_purchase_uoms
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
    GROUP BY p.id
), checks AS (
    SELECT
        'g2_phase1_dependency'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('ledger_rows', count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260721180000'

    UNION ALL

    SELECT
        'active_company_master_readiness',
        CASE WHEN count(*) FILTER (
            WHERE NOT has_active_category OR NOT has_active_uom
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_companies', count(*),
            'companies_without_active_category', count(*) FILTER (
                WHERE NOT has_active_category
            ),
            'companies_without_active_uom', count(*) FILTER (
                WHERE NOT has_active_uom
            )
        )
    FROM company_readiness

    UNION ALL

    SELECT
        'canonical_master_inventory',
        'INFO',
        jsonb_build_object(
            'categories', (SELECT count(*) FROM public.product_categories),
            'active_categories', (
                SELECT count(*) FROM public.product_categories WHERE is_active
            ),
            'uoms', (SELECT count(*) FROM public.uoms),
            'active_uoms', (SELECT count(*) FROM public.uoms WHERE is_active),
            'warehouses', (SELECT count(*) FROM public.warehouses),
            'active_warehouses', (
                SELECT count(*) FROM public.warehouses WHERE is_active
            )
        )

    UNION ALL

    SELECT
        'product_inventory',
        'INFO',
        jsonb_build_object(
            'products', count(*),
            'stock_products', count(*) FILTER (WHERE NOT is_bundle),
            'bundle_products', count(*) FILTER (WHERE is_bundle),
            'active_products', count(*) FILTER (WHERE is_active),
            'products_with_movements', count(*) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM public.stock_movements sm
                    WHERE sm.company_id = products.company_id
                      AND sm.product_id = products.id
                )
            )
        )
    FROM public.products

    UNION ALL

    SELECT
        'duplicate_normalized_product_sku',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT
            company_id,
            upper(regexp_replace(btrim(sku), '\s+', ' ', 'g'))
        FROM public.products
        GROUP BY
            company_id,
            upper(regexp_replace(btrim(sku), '\s+', ' ', 'g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'duplicate_normalized_product_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT
            company_id,
            lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))
        FROM public.products
        GROUP BY
            company_id,
            lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'products_missing_canonical_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count', count(*))
    FROM public.products
    WHERE category_id IS NULL
       OR uom_id IS NULL
       OR weight_reference_uom_id IS NULL

    UNION ALL

    SELECT
        'products_without_positive_reference_weight',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count', count(*))
    FROM public.products
    WHERE weight_per_uom_kg <= 0

    UNION ALL

    SELECT
        'products_without_product_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count', count(*))
    FROM product_uom_summary
    WHERE uom_count = 0

    UNION ALL

    SELECT
        'invalid_product_base_uom_rows',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count', count(*))
    FROM product_uom_summary
    WHERE uom_count > 0 AND valid_base_rows <> 1

    UNION ALL

    SELECT
        'invalid_product_weight_reference_rows',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count', count(*))
    FROM product_uom_summary
    WHERE uom_count > 0 AND weight_reference_rows <> 1

    UNION ALL

    SELECT
        'products_without_active_sales_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('product_count', count(*))
    FROM product_uom_summary
    WHERE uom_count > 0 AND active_sales_uoms = 0

    UNION ALL

    SELECT
        'stock_products_without_active_purchase_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('product_count', count(*))
    FROM product_uom_summary s
    JOIN public.products p ON p.id = s.product_id
    WHERE NOT p.is_bundle
      AND s.uom_count > 0
      AND s.active_purchase_uoms = 0

    UNION ALL

    SELECT
        'inactive_reference_used_by_active_product',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM public.products p
    JOIN public.product_categories pc
      ON pc.company_id = p.company_id AND pc.id = p.category_id
    JOIN public.uoms base_uom
      ON base_uom.company_id = p.company_id AND base_uom.id = p.uom_id
    JOIN public.uoms weight_uom
      ON weight_uom.company_id = p.company_id
     AND weight_uom.id = p.weight_reference_uom_id
    WHERE p.is_active
      AND (NOT pc.is_active OR NOT base_uom.is_active OR NOT weight_uom.is_active)

    UNION ALL

    SELECT
        'legacy_category_uom_text_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM public.products p
    JOIN public.product_categories pc
      ON pc.company_id = p.company_id AND pc.id = p.category_id
    JOIN public.uoms u
      ON u.company_id = p.company_id AND u.id = p.uom_id
    WHERE lower(regexp_replace(btrim(COALESCE(p.category, '')), '\s+', ' ', 'g'))
              <> lower(regexp_replace(btrim(pc.category_name), '\s+', ' ', 'g'))
       OR upper(regexp_replace(btrim(COALESCE(p.uom, '')), '\s+', ' ', 'g'))
              <> upper(regexp_replace(btrim(u.code), '\s+', ' ', 'g'))

    UNION ALL

    SELECT
        'legacy_uom_conversion_rows',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM public.product_uom_conversions

    UNION ALL

    SELECT
        'direct_product_group_write_privilege',
        'INFO',
        jsonb_build_object(
            'products_insert', has_table_privilege(
                'authenticated', 'public.products', 'INSERT'
            ),
            'products_update', has_table_privilege(
                'authenticated', 'public.products', 'UPDATE'
            ),
            'product_uoms_insert', has_table_privilege(
                'authenticated', 'public.product_uoms', 'INSERT'
            ),
            'product_uoms_update', has_table_privilege(
                'authenticated', 'public.product_uoms', 'UPDATE'
            )
        )
)
SELECT check_name, status, details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'BACKFILL' THEN 2
        WHEN 'REVIEW' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
