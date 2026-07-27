-- G1 phase 5B preflight: catalog/inventory tenant integrity.
-- SELECT-only. Every row must PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'negative_product_stock'::text AS check_name,
        count(*)::bigint AS violation_rows
    FROM public.product_stocks
    WHERE stock_qty < 0

    UNION ALL

    SELECT 'invalid_product_batch_balance', count(*)
    FROM public.product_batches
    WHERE qty_purchased < 0
       OR qty_remaining < 0
       OR qty_remaining > qty_purchased

    UNION ALL

    SELECT 'catalog_tables_without_rls', count(*)
    FROM (VALUES
        ('products'), ('product_bundle_items'), ('product_stocks'),
        ('customers'), ('uoms'), ('product_uom_conversions'),
        ('product_batches')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')
    WHERE c.oid IS NULL OR NOT c.relrowsecurity

    UNION ALL

    SELECT
        'legacy_import_rpc_missing',
        CASE WHEN to_regprocedure(
            'public.import_products_for_company(uuid,jsonb)'
        ) IS NULL THEN 1 ELSE 0 END
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END, check_name;
