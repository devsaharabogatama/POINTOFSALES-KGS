-- Expected: all PASS.
WITH checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
           count(*)=1 AS passed
    FROM private.kgs_schema_migrations WHERE version='20260722040000'
    UNION ALL
    SELECT 'parent_column',count(*)=1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='customers' AND column_name='parent_customer_id'
    UNION ALL
    SELECT 'parent_fk',count(*)=1 FROM pg_constraint WHERE conname='fk_customers_company_parent' AND convalidated
    UNION ALL
    SELECT 'warehouse_name_unique',count(*)=1 FROM pg_indexes
    WHERE schemaname='public' AND indexname='uq_warehouses_company_normalized_name'
    UNION ALL
    SELECT 'uom_code_unique',count(*)=1 FROM pg_indexes
    WHERE schemaname='public' AND indexname='uq_uoms_company_normalized_code'
    UNION ALL
    SELECT 'grouping_rpc',count(*)=1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='save_customer_with_parent'
    UNION ALL
    SELECT 'invalid_cross_company_parent',count(*)=0 FROM public.customers c
    JOIN public.customers p ON p.id=c.parent_customer_id
    WHERE c.company_id<>p.company_id
    UNION ALL
    SELECT 'nested_customer_group',count(*)=0 FROM public.customers c
    JOIN public.customers p ON p.id=c.parent_customer_id AND p.company_id=c.company_id
    WHERE p.parent_customer_id IS NOT NULL
)
SELECT check_name,CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END status FROM checks ORDER BY check_name;
