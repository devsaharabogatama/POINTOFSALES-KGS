-- G2 phase 6 postflight: canonical Supplier foundation. SELECT-only.

WITH expected_tables(table_name) AS (
    VALUES
        ('suppliers'),('product_suppliers'),
        ('supplier_master_audit'),('product_supplier_audit')
), expected_constraints(table_name,constraint_name) AS (
    VALUES
        ('suppliers','suppliers_company_id_id_unique'),
        ('product_suppliers','product_suppliers_company_product_supplier_unique'),
        ('product_suppliers','fk_product_suppliers_company_product'),
        ('product_suppliers','fk_product_suppliers_company_supplier'),
        ('product_suppliers','fk_product_suppliers_company_product_uom'),
        ('supplier_master_audit','fk_supplier_audit_company_supplier'),
        ('product_supplier_audit','fk_product_supplier_audit_company_relation')
), expected_indexes(index_name) AS (
    VALUES
        ('uq_suppliers_company_normalized_code'),
        ('uq_suppliers_company_normalized_name'),
        ('uq_product_suppliers_one_active_preferred')
), expected_functions(signature) AS (
    VALUES
        ('public.save_supplier(uuid,bigint,text,text,text,text,text,text,text,text,text,text,boolean)'),
        ('public.save_product_supplier(uuid,bigint,uuid,uuid,uuid,text,numeric,boolean,boolean)')
), checks AS (
    SELECT
        'canonical_supplier_tables'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE c.oid IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'supplier_tables_rls_and_policy',
        CASE WHEN count(*) FILTER (
            WHERE c.oid IS NULL OR NOT c.relrowsecurity
               OR COALESCE(p.policy_count,0) = 0
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'failed',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name) FILTER (
                    WHERE c.oid IS NULL OR NOT c.relrowsecurity
                       OR COALESCE(p.policy_count,0) = 0
                ),
                '[]'::jsonb
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
        'supplier_constraints_validated',
        CASE WHEN count(*) FILTER (
            WHERE con.oid IS NULL OR NOT con.convalidated
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'expected',count(*),
            'failed',COALESCE(
                jsonb_agg(e.constraint_name ORDER BY e.constraint_name)
                    FILTER (WHERE con.oid IS NULL OR NOT con.convalidated),
                '[]'::jsonb
            )
        )
    FROM expected_constraints e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel
      ON rel.relnamespace = n.oid AND rel.relname = e.table_name
    LEFT JOIN pg_constraint con
      ON con.conrelid = rel.oid AND con.conname = e.constraint_name

    UNION ALL

    SELECT
        'supplier_unique_indexes',
        CASE WHEN count(*) FILTER (WHERE i.indexname IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(e.index_name ORDER BY e.index_name)
                    FILTER (WHERE i.indexname IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_indexes e
    LEFT JOIN pg_indexes i
      ON i.schemaname = 'public' AND i.indexname = e.index_name

    UNION ALL

    SELECT
        'supplier_rpc_security',
        CASE WHEN count(*) FILTER (
            WHERE p.oid IS NULL
               OR NOT p.prosecdef
               OR NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
                    @> ARRAY['search_path=public, pg_temp']::TEXT[]
               OR NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
               OR has_function_privilege('anon',p.oid,'EXECUTE')
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'expected',count(*),
            'failed',COALESCE(
                jsonb_agg(e.signature ORDER BY e.signature) FILTER (
                    WHERE p.oid IS NULL
                       OR NOT p.prosecdef
                       OR NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
                            @> ARRAY['search_path=public, pg_temp']::TEXT[]
                       OR NOT has_function_privilege(
                            'authenticated',p.oid,'EXECUTE'
                       )
                       OR has_function_privilege('anon',p.oid,'EXECUTE')
                ),
                '[]'::jsonb
            )
        )
    FROM expected_functions e
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.signature)

    UNION ALL

    SELECT
        'authenticated_supplier_direct_write_closed',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('privilege_rows',count(*))
    FROM expected_tables e
    WHERE has_table_privilege(
        'authenticated','public.' || e.table_name,
        'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
    )

    UNION ALL

    SELECT
        'anon_supplier_table_privilege_closed',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('privilege_rows',count(*))
    FROM expected_tables e
    WHERE has_table_privilege(
        'anon','public.' || e.table_name,
        'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
    )

    UNION ALL

    SELECT
        'supplier_touch_triggers',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('expected',2,'actual',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND t.tgname IN ('g2_touch_suppliers','g2_touch_product_suppliers')
      AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'migration_ledger',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('row_count',count(*))
    FROM private.kgs_schema_migrations
    WHERE version = '20260721230000'
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
