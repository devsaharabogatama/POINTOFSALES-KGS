-- G2 phase 6 preflight: Supplier and Product-Supplier master readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, function side effect, TEMP table, or grants.
-- - Returns aggregate counts only and never exposes Supplier/business names.

WITH required_versions(version) AS (
    VALUES ('20260721210000')
), normalized_legacy_suppliers AS (
    SELECT
        ph.company_id,
        ph.supplier_name,
        lower(regexp_replace(btrim(ph.supplier_name), '\s+', ' ', 'g'))
            AS normalized_name
    FROM public.purchases_headers ph
), product_purchase_readiness AS (
    SELECT
        p.id AS product_id,
        count(pu.id) FILTER (
            WHERE pu.is_active AND pu.purchase_allowed
        ) AS active_purchase_uoms
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
    WHERE p.is_active
      AND NOT p.is_bundle
    GROUP BY p.id
), checks AS (
    SELECT
        'g2_phase4_dependency'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
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
        'canonical_supplier_table_state',
        'INFO',
        jsonb_build_object(
            'suppliers_exists', to_regclass('public.suppliers') IS NOT NULL,
            'product_suppliers_exists',
                to_regclass('public.product_suppliers') IS NOT NULL
        )

    UNION ALL

    SELECT
        'legacy_purchase_supplier_inventory',
        'INFO',
        jsonb_build_object(
            'purchase_rows', count(*),
            'companies', count(DISTINCT company_id),
            'distinct_normalized_supplier_names',
                count(DISTINCT (company_id, normalized_name))
        )
    FROM normalized_legacy_suppliers

    UNION ALL

    SELECT
        'blank_legacy_supplier_name',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM normalized_legacy_suppliers
    WHERE normalized_name = ''

    UNION ALL

    SELECT
        'legacy_supplier_normalization_collisions',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('collision_groups', count(*))
    FROM (
        SELECT company_id, normalized_name
        FROM normalized_legacy_suppliers
        WHERE normalized_name <> ''
        GROUP BY company_id, normalized_name
        HAVING count(DISTINCT supplier_name) > 1
    ) collision_groups

    UNION ALL

    SELECT
        'legacy_supplier_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'purchase_rows', count(*),
            'supplier_groups', count(DISTINCT (company_id, normalized_name))
        )
    FROM normalized_legacy_suppliers
    WHERE normalized_name <> ''

    UNION ALL

    SELECT
        'active_stock_products_without_purchase_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count', count(*))
    FROM product_purchase_readiness
    WHERE active_purchase_uoms = 0

    UNION ALL

    SELECT
        'invalid_purchase_uom_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM public.product_uoms pu
    LEFT JOIN public.products p
      ON p.company_id = pu.company_id
     AND p.id = pu.product_id
    LEFT JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
    WHERE pu.is_active
      AND pu.purchase_allowed
      AND (
          p.id IS NULL
          OR u.id IS NULL
          OR NOT u.is_active
          OR pu.purchase_price IS NULL
          OR pu.purchase_price < 0
      )

    UNION ALL

    SELECT
        'supplier_foundation_inventory',
        'INFO',
        jsonb_build_object(
            'companies', (SELECT count(*) FROM public.companies),
            'active_companies', (
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'products', (SELECT count(*) FROM public.products),
            'active_purchase_product_uoms', (
                SELECT count(*) FROM public.product_uoms
                WHERE is_active AND purchase_allowed
            )
        )
)
SELECT check_name, status, details
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
