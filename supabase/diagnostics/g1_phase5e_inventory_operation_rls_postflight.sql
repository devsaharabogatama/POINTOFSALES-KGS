-- G1 phase 5E postflight. SELECT-only. Expected result: 32 PASS rows.

WITH expected_tables(table_name) AS (
    VALUES
        ('sales_fifo_allocations'), ('stock_opnames'),
        ('stock_opname_details'), ('stock_adjustments'), ('stock_movements')
), policy_counts AS (
    SELECT tablename,count(*)::integer AS policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
    GROUP BY tablename
), table_checks AS (
    SELECT
        'table_policy:' || e.table_name AS check_name,
        CASE
            WHEN c.oid IS NOT NULL
             AND c.relrowsecurity
             AND COALESCE(pc.policy_count,0) = 1
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists',c.oid IS NOT NULL,
            'rls_enabled',COALESCE(c.relrowsecurity,FALSE),
            'expected_policies',1,
            'actual_policies',COALESCE(pc.policy_count,0)
        ) AS details
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
    LEFT JOIN policy_counts pc ON pc.tablename = e.table_name
), privilege_checks AS (
    SELECT
        'privilege:' || table_name AS check_name,
        CASE
            WHEN has_table_privilege(
                'authenticated','public.' || table_name,'SELECT'
            )
             AND NOT has_table_privilege(
                'authenticated','public.' || table_name,'INSERT'
             )
             AND NOT has_table_privilege(
                'authenticated','public.' || table_name,'UPDATE'
             )
             AND NOT has_table_privilege(
                'authenticated','public.' || table_name,'DELETE'
             )
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'select',has_table_privilege(
                'authenticated','public.' || table_name,'SELECT'
            ),
            'insert',has_table_privilege(
                'authenticated','public.' || table_name,'INSERT'
            ),
            'update',has_table_privilege(
                'authenticated','public.' || table_name,'UPDATE'
            ),
            'delete',has_table_privilege(
                'authenticated','public.' || table_name,'DELETE'
            )
        ) AS details
    FROM expected_tables
), expected_constraints(table_name,constraint_name,expected_type) AS (
    VALUES
        ('sales_details','uq_sales_details_company_id_id','u'),
        ('product_batches','uq_product_batches_company_id_id','u'),
        ('stock_opnames','uq_stock_opnames_company_id_id','u'),
        ('stock_opname_details','uq_stock_opname_details_company_id_id','u'),
        ('sales_fifo_allocations','fk_fifo_allocations_company_sales_detail','f'),
        ('sales_fifo_allocations','fk_fifo_allocations_company_batch','f'),
        ('stock_opnames','fk_stock_opnames_company_warehouse','f'),
        ('stock_opname_details','fk_opname_details_company_opname','f'),
        ('stock_opname_details','fk_opname_details_company_product','f'),
        ('stock_adjustments','fk_stock_adjustments_company_product','f'),
        ('stock_adjustments','fk_stock_adjustments_company_warehouse','f'),
        ('stock_adjustments','fk_stock_adjustments_company_opname_detail','f'),
        ('stock_movements','fk_stock_movements_company_product','f'),
        ('stock_movements','fk_stock_movements_company_warehouse','f')
), constraint_checks AS (
    SELECT
        'constraint:' || e.constraint_name AS check_name,
        CASE
            WHEN c.oid IS NOT NULL
             AND c.contype::text = e.expected_type
             AND c.convalidated
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'table',e.table_name,
            'exists',c.oid IS NOT NULL,
            'type',c.contype,
            'validated',COALESCE(c.convalidated,FALSE)
        ) AS details
    FROM expected_constraints e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel
      ON rel.relnamespace = n.oid
     AND rel.relname = e.table_name
    LEFT JOIN pg_constraint c
      ON c.conrelid = rel.oid
     AND c.conname = e.constraint_name
), not_null_checks AS (
    SELECT
        'not_null:' || e.table_name || '.company_id' AS check_name,
        CASE WHEN c.is_nullable = 'NO' THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('is_nullable',c.is_nullable) AS details
    FROM expected_tables e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = 'company_id'
), function_check AS (
    SELECT
        'function:private_inventory_reviewer_visible'::text AS check_name,
        CASE
            WHEN p.oid IS NOT NULL
             AND p.prosecdef
             AND p.provolatile = 's'
             AND COALESCE(p.proconfig,ARRAY[]::text[])::text[]
                 @> ARRAY['search_path=public, pg_temp']::text[]
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists',p.oid IS NOT NULL,
            'security_definer',COALESCE(p.prosecdef,FALSE),
            'volatility',p.provolatile,
            'config',COALESCE(to_jsonb(p.proconfig),'[]'::jsonb)
        ) AS details
    FROM (VALUES (to_regprocedure(
        'public.private_inventory_reviewer_visible(uuid)'
    ))) expected(oid)
    LEFT JOIN pg_proc p ON p.oid = expected.oid
), transfer_check AS (
    SELECT
        'transfer_service_role_only'::text AS check_name,
        CASE
            WHEN NOT has_function_privilege(
                'authenticated',
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
                'EXECUTE'
            )
             AND has_function_privilege(
                'service_role',
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
                'EXECUTE'
             )
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
                'EXECUTE'
            ),
            'service_role_execute',has_function_privilege(
                'service_role',
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
                'EXECUTE'
            )
        ) AS details
), ledger_check AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260721150000'
)
SELECT check_name,status,details
FROM (
    SELECT * FROM table_checks
    UNION ALL SELECT * FROM privilege_checks
    UNION ALL SELECT * FROM constraint_checks
    UNION ALL SELECT * FROM not_null_checks
    UNION ALL SELECT * FROM function_check
    UNION ALL SELECT * FROM transfer_check
    UNION ALL SELECT * FROM ledger_check
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
