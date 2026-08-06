-- G4 phase 18 postflight: POS Customer quick-create contract.
-- SELECT-only.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260730040000'

    UNION ALL

    SELECT
        'quick_create_rpc',
        CASE WHEN to_regprocedure(
            'public.quick_create_pos_customer(text,text,text,text,text)'
        ) IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN to_regprocedure(
            'public.quick_create_pos_customer(text,text,text,text,text)'
        ) IS NULL THEN 1 ELSE 0 END,
        jsonb_build_object(
            'rpc_exists',
            to_regprocedure(
                'public.quick_create_pos_customer(text,text,text,text,text)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'quick_create_rpc_boundary',
        CASE WHEN
            NOT has_function_privilege(
                'anon',
                'public.quick_create_pos_customer(text,text,text,text,text)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.quick_create_pos_customer(text,text,text,text,text)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_function_privilege(
                'anon',
                'public.quick_create_pos_customer(text,text,text,text,text)',
                'EXECUTE'
            )
            OR NOT has_function_privilege(
                'authenticated',
                'public.quick_create_pos_customer(text,text,text,text,text)',
                'EXECUTE'
            )
        THEN 1 ELSE 0 END,
        jsonb_build_object(
            'anon_execute',has_function_privilege(
                'anon',
                'public.quick_create_pos_customer(text,text,text,text,text)',
                'EXECUTE'
            ),
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.quick_create_pos_customer(text,text,text,text,text)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'browser_customer_direct_write_boundary',
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.customers','INSERT,UPDATE,DELETE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_table_privilege(
            'authenticated','public.customers','INSERT,UPDATE,DELETE'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated','public.customers','INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'active_company_customer_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('invalid_rows',count(*))
    FROM public.customers c
    LEFT JOIN public.companies co ON co.id = c.company_id
    LEFT JOIN public.customer_categories cc
      ON cc.company_id = c.company_id
     AND cc.id = c.customer_category_id
    WHERE co.id IS NULL OR cc.id IS NULL
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
