-- G2 phase 12 postflight: canonical Pricelist foundation.
-- SELECT-only. Expected result: every row PASS with violation_rows = 0.

WITH expected_tables(table_name) AS (
    VALUES
        ('pricelists'), ('pricelist_store_assignments'),
        ('pricelist_rules'), ('pricelist_master_audit')
), expected_snapshot_columns(column_name) AS (
    VALUES
        ('base_unit_price'), ('pricelist_id'), ('pricelist_rule_id'),
        ('resolved_unit_price'), ('line_discount_type'),
        ('line_discount_input'), ('line_discount_amount'),
        ('allocated_order_discount_amount'), ('unit_price_after_discount'),
        ('line_total'), ('pricing_resolved_at')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722070000'

    UNION ALL

    SELECT
        'canonical_tables_missing',
        count(*) FILTER (WHERE c.oid IS NULL),
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL),'[]'::JSONB
            )
        )
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_tables_without_rls_or_policy',
        count(*) FILTER (
            WHERE c.oid IS NULL OR NOT c.relrowsecurity
               OR COALESCE(p.policy_count,0) = 0
        ),
        jsonb_build_object(
            'tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name) FILTER (
                    WHERE c.oid IS NULL OR NOT c.relrowsecurity
                       OR COALESCE(p.policy_count,0) = 0
                ),'[]'::JSONB
            )
        )
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')
    LEFT JOIN (
        SELECT tablename,count(*) AS policy_count
        FROM pg_policies WHERE schemaname = 'public'
        GROUP BY tablename
    ) p ON p.tablename = e.table_name

    UNION ALL

    SELECT
        'sales_snapshot_columns_missing',
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),'[]'::JSONB
            )
        )
    FROM expected_snapshot_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_details'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'active_company_default_global_pricelist',
        count(*),
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT c.id
        FROM public.companies c
        LEFT JOIN public.pricelists p
          ON p.company_id = c.id
         AND p.scope = 'GLOBAL'
         AND p.is_default
         AND p.is_active
        WHERE c.status = 'ACTIVE'
        GROUP BY c.id
        HAVING count(p.id) <> 1
    ) invalid_companies

    UNION ALL

    SELECT
        'invalid_pricelist_scope_or_customer',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pricelists p
    LEFT JOIN public.customers c
      ON c.company_id = p.company_id AND c.id = p.customer_id
    WHERE (p.scope = 'GLOBAL' AND p.customer_id IS NOT NULL)
       OR (p.scope = 'CUSTOMER' AND (
            c.id IS NULL OR c.is_system_customer OR NOT c.is_active
       ))

    UNION ALL

    SELECT
        'invalid_pricelist_store_assignment',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pricelist_store_assignments a
    LEFT JOIN public.pricelists p
      ON p.company_id = a.company_id AND p.id = a.pricelist_id
    LEFT JOIN public.stores s
      ON s.company_id = a.company_id AND s.id = a.store_id
    WHERE p.id IS NULL OR s.id IS NULL OR p.applies_all_stores

    UNION ALL

    SELECT
        'invalid_pricelist_rule_reference',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pricelist_rules r
    LEFT JOIN public.pricelists p
      ON p.company_id = r.company_id AND p.id = r.pricelist_id
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = r.company_id
     AND pu.id = r.product_uom_id
     AND pu.product_id = r.product_id
    WHERE p.id IS NULL OR pu.id IS NULL

    UNION ALL

    SELECT
        'invalid_active_customer_tier',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pricelist_rules r
    JOIN public.pricelists p
      ON p.company_id = r.company_id AND p.id = r.pricelist_id
    WHERE p.scope = 'CUSTOMER' AND r.is_active AND r.min_qty <> 1

    UNION ALL

    SELECT
        'unvalidated_pricelist_foreign_keys',
        count(*),
        jsonb_build_object(
            'constraints',COALESCE(jsonb_agg(con.conname ORDER BY con.conname),'[]'::JSONB)
        )
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND rel.relname IN (
          'pricelists','pricelist_store_assignments','pricelist_rules',
          'pricelist_master_audit','sales_details'
      )
      AND con.contype = 'f'
      AND NOT con.convalidated

    UNION ALL

    SELECT
        'browser_privilege_boundary',
        (
            CASE WHEN EXISTS (
                SELECT 1 FROM expected_tables e
                WHERE has_table_privilege(
                    'anon','public.' || e.table_name,
                    'SELECT,INSERT,UPDATE,DELETE'
                )
            ) THEN 1 ELSE 0 END
            + CASE WHEN EXISTS (
                SELECT 1 FROM expected_tables e
                WHERE has_table_privilege(
                    'authenticated','public.' || e.table_name,
                    'INSERT,UPDATE,DELETE'
                )
            ) THEN 1 ELSE 0 END
            + CASE WHEN has_function_privilege(
                'anon',
                'public.save_pricelist_with_rules(uuid,bigint,text,text,text,uuid,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
                'EXECUTE'
            ) THEN 1 ELSE 0 END
            + CASE WHEN NOT has_function_privilege(
                'authenticated',
                'public.save_pricelist_with_rules(uuid,bigint,text,text,text,uuid,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
                'EXECUTE'
            ) THEN 1 ELSE 0 END
        )::BIGINT,
        jsonb_build_object('expected','anon denied; authenticated SELECT + guarded RPC only')

    UNION ALL

    SELECT
        'security_definer_without_fixed_search_path',
        count(*),
        jsonb_build_object(
            'routines',COALESCE(
                jsonb_agg(p.proname ORDER BY p.proname),'[]'::JSONB
            )
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','private')
      AND p.proname IN (
          'save_pricelist_with_rules','trg_g2_provision_default_pricelist'
      )
      AND p.prosecdef
      AND NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
              @> ARRAY['search_path=public, pg_temp']::TEXT[]
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
