-- G1 phase 2 preflight: core master/inventory tenant consistency.
-- SELECT-only. Returns counts only and never exposes business rows.

WITH mismatch_checks AS (
    SELECT 'pos_terminals.store_id'::text AS relation, count(*)::bigint AS mismatch_rows
    FROM public.pos_terminals c
    JOIN public.stores p ON p.id = c.store_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'store_memberships.store_id', count(*)
    FROM public.store_memberships c
    JOIN public.stores p ON p.id = c.store_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'products.uom_id', count(*)
    FROM public.products c
    JOIN public.uoms p ON p.id = c.uom_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_bundle_items.bundle_id', count(*)
    FROM public.product_bundle_items c
    JOIN public.products p ON p.id = c.bundle_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_bundle_items.item_id', count(*)
    FROM public.product_bundle_items c
    JOIN public.products p ON p.id = c.item_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_stocks.product_id', count(*)
    FROM public.product_stocks c
    JOIN public.products p ON p.id = c.product_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_stocks.warehouse_id', count(*)
    FROM public.product_stocks c
    JOIN public.warehouses p ON p.id = c.warehouse_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_uom_conversions.product_id', count(*)
    FROM public.product_uom_conversions c
    JOIN public.products p ON p.id = c.product_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_uom_conversions.from_uom_id', count(*)
    FROM public.product_uom_conversions c
    JOIN public.uoms p ON p.id = c.from_uom_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_uom_conversions.to_uom_id', count(*)
    FROM public.product_uom_conversions c
    JOIN public.uoms p ON p.id = c.to_uom_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_batches.product_id', count(*)
    FROM public.product_batches c
    JOIN public.products p ON p.id = c.product_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'product_batches.warehouse_id', count(*)
    FROM public.product_batches c
    JOIN public.warehouses p ON p.id = c.warehouse_id
    WHERE c.company_id IS DISTINCT FROM p.company_id
)
SELECT
    relation,
    CASE WHEN mismatch_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    mismatch_rows
FROM mismatch_checks
ORDER BY CASE WHEN mismatch_rows > 0 THEN 1 ELSE 2 END, relation;
