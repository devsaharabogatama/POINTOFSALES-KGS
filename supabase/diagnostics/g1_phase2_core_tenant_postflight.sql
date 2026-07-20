-- G1 phase 2 postflight. SELECT-only.

WITH expected_constraints(table_name, constraint_name, expected_type) AS (
    VALUES
        ('stores', 'uq_stores_company_id_id', 'u'),
        ('warehouses', 'uq_warehouses_company_id_id', 'u'),
        ('products', 'uq_products_company_id_id', 'u'),
        ('uoms', 'uq_uoms_company_id_id', 'u'),
        ('pos_terminals', 'fk_pos_terminals_company_store', 'f'),
        ('store_memberships', 'fk_store_memberships_company_store', 'f'),
        ('products', 'fk_products_company_uom', 'f'),
        ('product_bundle_items', 'fk_bundle_items_company_bundle', 'f'),
        ('product_bundle_items', 'fk_bundle_items_company_item', 'f'),
        ('product_stocks', 'fk_product_stocks_company_product', 'f'),
        ('product_stocks', 'fk_product_stocks_company_warehouse', 'f'),
        ('product_uom_conversions', 'fk_uom_conversions_company_product', 'f'),
        ('product_uom_conversions', 'fk_uom_conversions_company_from', 'f'),
        ('product_uom_conversions', 'fk_uom_conversions_company_to', 'f'),
        ('product_batches', 'fk_product_batches_company_product', 'f'),
        ('product_batches', 'fk_product_batches_company_warehouse', 'f')
), constraint_checks AS (
    SELECT
        'constraint:' || e.constraint_name AS check_name,
        CASE
            WHEN c.oid IS NULL THEN 'FAIL'
            WHEN c.contype::text <> e.expected_type THEN 'FAIL'
            WHEN NOT c.convalidated THEN 'FAIL'
            ELSE 'PASS'
        END AS status,
        jsonb_build_object(
            'table', e.table_name,
            'exists', c.oid IS NOT NULL,
            'type', c.contype,
            'validated', COALESCE(c.convalidated, FALSE)
        ) AS details
    FROM expected_constraints e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel
      ON rel.relnamespace = n.oid
     AND rel.relname = e.table_name
    LEFT JOIN pg_constraint c
      ON c.conrelid = rel.oid
     AND c.conname = e.constraint_name
), other_checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count', count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260720120000'

    UNION ALL

    SELECT
        'all_composite_foreign_keys_validated',
        CASE WHEN count(*) FILTER (WHERE status = 'PASS') = 12
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'expected', 12,
            'passed', count(*) FILTER (WHERE status = 'PASS')
        )
    FROM constraint_checks
    WHERE check_name LIKE 'constraint:fk_%'
)
SELECT check_name, status, details
FROM (
    SELECT * FROM constraint_checks
    UNION ALL
    SELECT * FROM other_checks
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END, check_name;
