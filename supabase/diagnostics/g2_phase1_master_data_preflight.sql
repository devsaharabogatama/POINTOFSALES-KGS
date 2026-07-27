-- G2 phase 1 preflight: legacy Product/Category/UOM/Warehouse readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function call with side effects,
--   GRANT, or persistent change.
-- - Returns aggregate counts and normalized collision counts only.
-- - Run the entire file in Supabase SQL Editor and export the final result.
--
-- PURPOSE:
-- G2 will replace free-text Product category/UOM dependencies with canonical
-- tenant-scoped masters. This audit identifies rows that need an explicit
-- backfill rule before any G2 schema migration is written or applied.

WITH required_versions(version) AS (
    VALUES
        ('20260720090000'), ('20260720120000'), ('20260720150000'),
        ('20260720180000'), ('20260720210000'), ('20260720230000'),
        ('20260721090000'), ('20260721120000'), ('20260721150000')
), normalized_products AS (
    SELECT
        p.*,
        upper(regexp_replace(btrim(p.sku), '\s+', ' ', 'g')) AS normalized_sku,
        lower(regexp_replace(btrim(p.name), '\s+', ' ', 'g')) AS normalized_name,
        lower(regexp_replace(btrim(COALESCE(p.category, '')), '\s+', ' ', 'g'))
            AS normalized_category,
        upper(regexp_replace(btrim(COALESCE(p.uom, '')), '\s+', ' ', 'g'))
            AS normalized_uom
    FROM public.products p
), normalized_uoms AS (
    SELECT
        u.*,
        upper(regexp_replace(btrim(u.code), '\s+', ' ', 'g')) AS normalized_code,
        lower(regexp_replace(btrim(u.name), '\s+', ' ', 'g')) AS normalized_name
    FROM public.uoms u
), normalized_warehouses AS (
    SELECT
        w.*,
        upper(regexp_replace(btrim(w.code), '\s+', ' ', 'g')) AS normalized_code,
        lower(regexp_replace(btrim(w.name), '\s+', ' ', 'g')) AS normalized_name
    FROM public.warehouses w
), checks AS (
    SELECT
        'g1_migration_chain'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'expected', count(*),
            'missing', COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'product_inventory',
        'INFO',
        jsonb_build_object(
            'products', count(*),
            'stock_products', count(*) FILTER (WHERE NOT is_bundle),
            'bundle_products', count(*) FILTER (WHERE is_bundle),
            'active_products', count(*) FILTER (WHERE is_active)
        )
    FROM public.products

    UNION ALL

    SELECT
        'product_required_legacy_values',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('violation_rows', count(*))
    FROM normalized_products
    WHERE normalized_sku = ''
       OR normalized_name = ''
       OR normalized_category = ''
       OR normalized_uom = ''

    UNION ALL

    SELECT
        'duplicate_normalized_product_sku',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_sku
        FROM normalized_products
        GROUP BY company_id, normalized_sku
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'duplicate_normalized_product_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_name
        FROM normalized_products
        GROUP BY company_id, normalized_name
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'legacy_category_normalization_collisions',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('collision_groups', count(*))
    FROM (
        SELECT company_id, normalized_category
        FROM normalized_products
        WHERE normalized_category <> ''
        GROUP BY company_id, normalized_category
        HAVING count(DISTINCT category) > 1
    ) collision_groups

    UNION ALL

    SELECT
        'legacy_category_backfill_scope',
        'INFO',
        jsonb_build_object(
            'distinct_normalized_categories', count(*),
            'companies_with_categories', count(DISTINCT company_id)
        )
    FROM (
        SELECT DISTINCT company_id, normalized_category
        FROM normalized_products
        WHERE normalized_category <> ''
    ) categories

    UNION ALL

    SELECT
        'products_without_canonical_uom_id',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count', count(*))
    FROM public.products
    WHERE uom_id IS NULL

    UNION ALL

    SELECT
        'product_legacy_uom_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM normalized_products p
    JOIN normalized_uoms u ON u.id = p.uom_id
    WHERE p.normalized_uom NOT IN (u.normalized_code, upper(u.normalized_name))

    UNION ALL

    SELECT
        'movement_products_without_canonical_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count', count(*))
    FROM (
        SELECT DISTINCT p.id
        FROM public.products p
        JOIN public.stock_movements sm ON sm.product_id = p.id
        WHERE p.uom_id IS NULL
    ) affected_products

    UNION ALL

    SELECT
        'duplicate_normalized_uom_code',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_code
        FROM normalized_uoms
        GROUP BY company_id, normalized_code
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'duplicate_normalized_uom_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_name
        FROM normalized_uoms
        GROUP BY company_id, normalized_name
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'invalid_uom_conversion_factor',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM public.product_uom_conversions
    WHERE conversion_factor <= 0

    UNION ALL

    SELECT
        'legacy_conversion_not_touching_product_base_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM public.product_uom_conversions c
    JOIN public.products p ON p.id = c.product_id
    WHERE p.uom_id IS NOT NULL
      AND c.from_uom_id IS DISTINCT FROM p.uom_id
      AND c.to_uom_id IS DISTINCT FROM p.uom_id

    UNION ALL

    SELECT
        'master_uom_and_conversion_inventory',
        'INFO',
        jsonb_build_object(
            'uoms', (SELECT count(*) FROM public.uoms),
            'product_conversions',
                (SELECT count(*) FROM public.product_uom_conversions)
        )

    UNION ALL

    SELECT
        'invalid_warehouse_code_for_g2',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count', count(*))
    FROM normalized_warehouses
    WHERE normalized_code !~ '^[A-Z]{1,5}$'

    UNION ALL

    SELECT
        'duplicate_normalized_warehouse_code',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_code
        FROM normalized_warehouses
        GROUP BY company_id, normalized_code
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'duplicate_normalized_warehouse_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, normalized_name
        FROM normalized_warehouses
        GROUP BY company_id, normalized_name
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'warehouse_classification_backfill_scope',
        'INFO',
        jsonb_build_object(
            'warehouses', count(*),
            'active_warehouses', count(*) FILTER (WHERE is_active),
            'companies', count(DISTINCT company_id),
            'requires_type_assignment', count(*),
            'requires_store_scope_review', count(*)
        )
    FROM public.warehouses
)
SELECT check_name, status, details
FROM checks
ORDER BY
    CASE status
        WHEN 'FAIL' THEN 1
        WHEN 'BLOCKER' THEN 2
        WHEN 'REVIEW' THEN 3
        WHEN 'BACKFILL' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
