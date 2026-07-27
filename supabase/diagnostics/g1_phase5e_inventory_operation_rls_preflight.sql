-- G1 phase 5E preflight: inventory-operation tenant and privilege boundary.
-- SELECT-only. Every row must PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'inventory_operation_tables_without_rls'::text AS check_name,
        count(*)::bigint AS violation_rows
    FROM (VALUES
        ('sales_fifo_allocations'), ('stock_opnames'),
        ('stock_opname_details'), ('stock_adjustments'), ('stock_movements')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')
    WHERE c.oid IS NULL OR NOT c.relrowsecurity

    UNION ALL

    SELECT 'inventory_operation_tenant_mismatch', count(*)
    FROM (
        SELECT a.id
        FROM public.sales_fifo_allocations a
        JOIN public.sales_details d ON d.id = a.sales_detail_id
        WHERE a.company_id IS DISTINCT FROM d.company_id

        UNION ALL

        SELECT a.id
        FROM public.sales_fifo_allocations a
        JOIN public.product_batches b ON b.id = a.product_batch_id
        WHERE a.company_id IS DISTINCT FROM b.company_id

        UNION ALL

        SELECT o.id
        FROM public.stock_opnames o
        JOIN public.warehouses w ON w.id = o.warehouse_id
        WHERE o.company_id IS DISTINCT FROM w.company_id

        UNION ALL

        SELECT d.id
        FROM public.stock_opname_details d
        JOIN public.stock_opnames o ON o.id = d.opname_id
        WHERE d.company_id IS DISTINCT FROM o.company_id

        UNION ALL

        SELECT d.id
        FROM public.stock_opname_details d
        JOIN public.products p ON p.id = d.product_id
        WHERE d.company_id IS DISTINCT FROM p.company_id

        UNION ALL

        SELECT a.id
        FROM public.stock_adjustments a
        JOIN public.products p ON p.id = a.product_id
        WHERE a.company_id IS DISTINCT FROM p.company_id

        UNION ALL

        SELECT a.id
        FROM public.stock_adjustments a
        JOIN public.warehouses w ON w.id = a.warehouse_id
        WHERE a.company_id IS DISTINCT FROM w.company_id

        UNION ALL

        SELECT a.id
        FROM public.stock_adjustments a
        JOIN public.stock_opname_details d ON d.id = a.opname_detail_id
        WHERE a.company_id IS DISTINCT FROM d.company_id

        UNION ALL

        SELECT m.id
        FROM public.stock_movements m
        JOIN public.products p ON p.id = m.product_id
        WHERE m.company_id IS DISTINCT FROM p.company_id

        UNION ALL

        SELECT m.id
        FROM public.stock_movements m
        JOIN public.warehouses w ON w.id = m.warehouse_id
        WHERE m.company_id IS DISTINCT FROM w.company_id
    ) mismatches

    UNION ALL

    SELECT 'invalid_fifo_allocation_quantity', count(*)
    FROM public.sales_fifo_allocations
    WHERE qty_allocated <= 0 OR cogs_unit < 0

    UNION ALL

    SELECT 'invalid_stock_opname_arithmetic', count(*)
    FROM public.stock_opname_details
    WHERE system_qty < 0
       OR physical_qty < 0
       OR difference <> physical_qty - system_qty

    UNION ALL

    SELECT
        'authenticated_transfer_execute',
        CASE WHEN has_function_privilege(
            'authenticated',
            'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
            'EXECUTE'
        ) THEN 1 ELSE 0 END
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
