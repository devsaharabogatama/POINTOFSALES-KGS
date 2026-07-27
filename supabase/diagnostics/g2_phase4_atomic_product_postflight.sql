-- G2 phase 4 postflight: atomic Product + Product-UOM contract.
-- SELECT-only. Expected result: every row PASS.

WITH function_state AS (
    SELECT
        p.oid,
        p.prosecdef,
        p.proconfig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.oid = to_regprocedure(
          'public.save_product_with_uoms(uuid,bigint,text,text,uuid,uuid,uuid,numeric,boolean,text,boolean,jsonb)'
      )
), checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260721210000'

    UNION ALL

    SELECT
        'table:product_master_audit',
        CASE WHEN c.oid IS NOT NULL AND c.relrowsecurity
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'exists',c.oid IS NOT NULL,
            'rls_enabled',COALESCE(c.relrowsecurity,FALSE)
        )
    FROM (VALUES (to_regclass('public.product_master_audit'))) expected(oid)
    LEFT JOIN pg_class c ON c.oid = expected.oid

    UNION ALL

    SELECT
        'policy:product_master_audit',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('policy_count',count(*))
    FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'product_master_audit'

    UNION ALL

    SELECT
        'constraint:product_uom_factor_not_below_base',
        CASE WHEN count(*) = 1 AND bool_and(convalidated)
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'row_count',count(*),
            'validated',COALESCE(bool_and(convalidated),FALSE)
        )
    FROM pg_constraint
    WHERE conrelid = 'public.product_uoms'::regclass
      AND conname = 'product_uoms_factor_not_below_base'

    UNION ALL

    SELECT
        'index:normalized_product_sku',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('row_count',count(*))
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'uq_products_company_normalized_sku'

    UNION ALL

    SELECT
        'function:atomic_product_rpc',
        CASE WHEN count(*) = 1
                  AND bool_and(prosecdef)
                  AND bool_and(
                      COALESCE(proconfig,ARRAY[]::TEXT[])::TEXT[]
                      @> ARRAY['search_path=public, pg_temp']::TEXT[]
                  )
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'row_count',count(*),
            'security_definer',COALESCE(bool_and(prosecdef),FALSE),
            'fixed_search_path',COALESCE(bool_and(
                COALESCE(proconfig,ARRAY[]::TEXT[])::TEXT[]
                @> ARRAY['search_path=public, pg_temp']::TEXT[]
            ),FALSE)
        )
    FROM function_state

    UNION ALL

    SELECT
        'atomic_product_rpc_privileges',
        CASE WHEN has_function_privilege(
                      'authenticated',oid,'EXECUTE'
                  )
                  AND NOT has_function_privilege('anon',oid,'EXECUTE')
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',oid,'EXECUTE'
            ),
            'anon_execute',has_function_privilege('anon',oid,'EXECUTE')
        )
    FROM function_state

    UNION ALL

    SELECT
        'legacy_import_not_authenticated',
        CASE WHEN NOT has_function_privilege(
            'authenticated',
            'public.import_products_for_company(uuid,jsonb)',
            'EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('authenticated_execute',has_function_privilege(
            'authenticated',
            'public.import_products_for_company(uuid,jsonb)',
            'EXECUTE'
        ))

    UNION ALL

    SELECT
        'direct_product_group_write_revoked',
        CASE WHEN NOT has_table_privilege(
                      'authenticated','public.products','INSERT,UPDATE,DELETE'
                  )
                  AND NOT has_table_privilege(
                      'authenticated','public.product_uoms','INSERT,UPDATE,DELETE'
                  )
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'products_write',has_table_privilege(
                'authenticated','public.products','INSERT,UPDATE,DELETE'
            ),
            'product_uoms_write',has_table_privilege(
                'authenticated','public.product_uoms','INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'audit_browser_mutation_revoked',
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.product_master_audit','INSERT,UPDATE,DELETE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('browser_write',has_table_privilege(
            'authenticated','public.product_master_audit','INSERT,UPDATE,DELETE'
        ))

    UNION ALL

    SELECT
        'existing_product_canonical_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('violation_rows',count(*))
    FROM public.products p
    WHERE p.category_id IS NULL
       OR p.uom_id IS NULL
       OR p.weight_reference_uom_id IS NULL
       OR p.weight_per_uom_kg <= 0
       OR NOT EXISTS (
           SELECT 1 FROM public.product_uoms pu
           WHERE pu.company_id = p.company_id
             AND pu.product_id = p.id
             AND pu.uom_id = p.uom_id
             AND pu.factor_to_base = 1
       )
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
