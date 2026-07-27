-- G1 phase 5C preflight: transaction tenant/RLS boundary.
-- SELECT-only. Every row must PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'transaction_tables_without_rls'::text AS check_name,
        count(*)::bigint AS violation_rows
    FROM (VALUES
        ('cashier_sessions'), ('sales_headers'), ('sales_details'),
        ('sales_payments'), ('purchases_headers'), ('purchases_details')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')
    WHERE c.oid IS NULL OR NOT c.relrowsecurity

    UNION ALL

    SELECT 'transaction_scope_nulls', count(*)
    FROM (
        SELECT id FROM public.cashier_sessions
        WHERE store_id IS NULL OR pos_id IS NULL
        UNION ALL
        SELECT id FROM public.sales_headers
        WHERE store_id IS NULL OR pos_id IS NULL
        UNION ALL
        SELECT id FROM public.purchases_headers
        WHERE store_id IS NULL
    ) missing_scope

    UNION ALL

    SELECT 'transaction_tenant_mismatch', count(*)
    FROM (
        SELECT d.id
        FROM public.sales_details d
        JOIN public.sales_headers h ON h.id = d.sales_id
        WHERE d.company_id IS DISTINCT FROM h.company_id

        UNION ALL

        SELECT p.id
        FROM public.sales_payments p
        JOIN public.sales_headers h ON h.id = p.sales_id
        WHERE p.company_id IS DISTINCT FROM h.company_id
           OR p.session_id IS DISTINCT FROM h.session_id

        UNION ALL

        SELECT d.id
        FROM public.purchases_details d
        JOIN public.purchases_headers h ON h.id = d.purchase_id
        WHERE d.company_id IS DISTINCT FROM h.company_id
    ) mismatches

    UNION ALL

    SELECT
        'checkout_rpc_missing',
        CASE WHEN to_regprocedure(
            'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)'
        ) IS NULL THEN 1 ELSE 0 END

    UNION ALL

    SELECT
        'checkout_rpc_unsafe_definition',
        count(*)
    FROM pg_proc p
    WHERE p.oid = to_regprocedure(
        'public.create_sales_transaction(text,uuid,uuid,boolean,timestamp with time zone,boolean,text,numeric,numeric,numeric,numeric,numeric,numeric,payment_status,uuid,jsonb,jsonb,jsonb)'
    )
      AND (
          NOT p.prosecdef
          OR NOT COALESCE(p.proconfig,ARRAY[]::text[])::text[]
              @> ARRAY['search_path=public, pg_temp']::text[]
      )
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
