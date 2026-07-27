-- G1 phase 3 preflight: transaction tenant topology.
-- SELECT-only. Every row must PASS with mismatch_rows = 0 before migration.

WITH relation_checks AS (
    SELECT 'cashier_sessions.store_id -> stores'::text AS check_name,
           count(*)::bigint AS mismatch_rows
    FROM public.cashier_sessions c
    JOIN public.stores p ON p.id = c.store_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'cashier_sessions.pos_id -> pos_terminals', count(*)
    FROM public.cashier_sessions c
    JOIN public.pos_terminals p ON p.id = c.pos_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'cashier_sessions.store_id/pos_id consistency', count(*)
    FROM public.cashier_sessions c
    JOIN public.pos_terminals p ON p.id = c.pos_id
    WHERE c.store_id IS NOT NULL
      AND c.store_id IS DISTINCT FROM p.store_id

    UNION ALL
    SELECT 'sales_headers.session_id -> cashier_sessions', count(*)
    FROM public.sales_headers c
    JOIN public.cashier_sessions p ON p.id = c.session_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_headers.store_id -> stores', count(*)
    FROM public.sales_headers c
    JOIN public.stores p ON p.id = c.store_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_headers.pos_id -> pos_terminals', count(*)
    FROM public.sales_headers c
    JOIN public.pos_terminals p ON p.id = c.pos_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_headers.customer_id -> customers', count(*)
    FROM public.sales_headers c
    JOIN public.customers p ON p.id = c.customer_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_headers.store_id/pos_id/session_id consistency', count(*)
    FROM public.sales_headers c
    JOIN public.cashier_sessions p ON p.id = c.session_id
    WHERE c.store_id IS NOT NULL
      AND c.pos_id IS NOT NULL
      AND (c.store_id IS DISTINCT FROM p.store_id
           OR c.pos_id IS DISTINCT FROM p.pos_id)

    UNION ALL
    SELECT 'sales_details.sales_id -> sales_headers', count(*)
    FROM public.sales_details c
    JOIN public.sales_headers p ON p.id = c.sales_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_details.product_id -> products', count(*)
    FROM public.sales_details c
    JOIN public.products p ON p.id = c.product_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_details.warehouse_id -> warehouses', count(*)
    FROM public.sales_details c
    JOIN public.warehouses p ON p.id = c.warehouse_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_payments.sales_id -> sales_headers', count(*)
    FROM public.sales_payments c
    JOIN public.sales_headers p ON p.id = c.sales_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_payments.session_id -> cashier_sessions', count(*)
    FROM public.sales_payments c
    JOIN public.cashier_sessions p ON p.id = c.session_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'sales_payments.sales_id/session_id consistency', count(*)
    FROM public.sales_payments c
    JOIN public.sales_headers p ON p.id = c.sales_id
    WHERE c.session_id IS DISTINCT FROM p.session_id

    UNION ALL
    SELECT 'sales_payments.reversal_ref_id -> sales_payments', count(*)
    FROM public.sales_payments c
    JOIN public.sales_payments p ON p.id = c.reversal_ref_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'purchases_headers.store_id -> stores', count(*)
    FROM public.purchases_headers c
    JOIN public.stores p ON p.id = c.store_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'purchases_headers.warehouse_id -> warehouses', count(*)
    FROM public.purchases_headers c
    JOIN public.warehouses p ON p.id = c.warehouse_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'purchases_details.purchase_id -> purchases_headers', count(*)
    FROM public.purchases_details c
    JOIN public.purchases_headers p ON p.id = c.purchase_id
    WHERE c.company_id IS DISTINCT FROM p.company_id

    UNION ALL
    SELECT 'purchases_details.product_id -> products', count(*)
    FROM public.purchases_details c
    JOIN public.products p ON p.id = c.product_id
    WHERE c.company_id IS DISTINCT FROM p.company_id
)
SELECT
    check_name,
    CASE WHEN mismatch_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    mismatch_rows
FROM relation_checks
ORDER BY CASE WHEN mismatch_rows > 0 THEN 1 ELSE 2 END, check_name;
