-- G2 phase 8 Customer foundation postflight.
-- SELECT-only. Expected: every row PASS with violation_rows = 0.

WITH expected_tables(table_name) AS (
    VALUES
        ('customer_categories'),
        ('customer_category_audit'),
        ('customer_master_audit')
), expected_customer_columns(column_name) AS (
    VALUES
        ('customer_category_id'),('email'),('customer_type'),
        ('credit_term_days'),('is_active'),('is_system_customer'),
        ('notes'),('master_version'),('created_by'),('updated_by'),
        ('updated_at')
), expected_triggers(table_name,trigger_name) AS (
    VALUES
        ('customer_categories','g2_touch_customer_categories'),
        ('customers','g2_touch_customers'),
        ('companies','g2_provision_customer_defaults')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722010000'

    UNION ALL

    SELECT
        'canonical_tables_exist',
        count(*) FILTER (WHERE c.oid IS NULL),
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL),
                '[]'::jsonb
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
        'customer_columns_exist',
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_customer_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'customers'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'customer_category_reference_required',
        count(*) FILTER (
            WHERE c.column_name IS NULL OR c.is_nullable <> 'NO'
        ),
        jsonb_build_object('is_nullable',max(c.is_nullable))
    FROM (VALUES ('customer_category_id')) required(column_name)
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'customers'
     AND c.column_name = required.column_name

    UNION ALL

    SELECT
        'customer_tenant_fk_validated',
        count(*) FILTER (
            WHERE con.oid IS NULL OR NOT con.convalidated
        ),
        jsonb_build_object(
            'constraint',max(con.conname),
            'validated',COALESCE(bool_and(con.convalidated),FALSE)
        )
    FROM (VALUES ('fk_customers_company_category')) expected(conname)
    LEFT JOIN pg_constraint con ON con.conname = expected.conname

    UNION ALL

    SELECT
        'rls_and_policy_present',
        count(*) FILTER (
            WHERE NOT c.relrowsecurity OR COALESCE(p.policy_count,0) = 0
        ),
        jsonb_build_object(
            'invalid',COALESCE(
                jsonb_agg(c.relname ORDER BY c.relname)
                    FILTER (
                        WHERE NOT c.relrowsecurity
                           OR COALESCE(p.policy_count,0) = 0
                    ),
                '[]'::jsonb
            )
        )
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN (
        SELECT tablename,count(*) AS policy_count
        FROM pg_policies
        WHERE schemaname = 'public'
        GROUP BY tablename
    ) p ON p.tablename = c.relname
    WHERE n.nspname = 'public'
      AND c.relname IN (
          'customers','customer_categories',
          'customer_category_audit','customer_master_audit'
      )

    UNION ALL

    SELECT
        'walk_in_exactly_one_per_company',
        count(*),
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT co.id
        FROM public.companies co
        LEFT JOIN public.customers c
          ON c.company_id = co.id
         AND c.is_system_customer
        GROUP BY co.id
        HAVING count(c.id) <> 1
    ) invalid

    UNION ALL

    SELECT
        'system_customer_invariant',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.customers
    WHERE is_system_customer
      AND (
          code <> 'WALK-IN'
          OR customer_type <> 'WALK_IN'
          OR NOT is_active
          OR current_balance <> 0
          OR credit_limit <> 0
      )

    UNION ALL

    SELECT
        'general_category_exactly_one_per_company',
        count(*),
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT co.id
        FROM public.companies co
        LEFT JOIN public.customer_categories cc
          ON cc.company_id = co.id
         AND cc.is_system_category
        GROUP BY co.id
        HAVING count(cc.id) <> 1
    ) invalid

    UNION ALL

    SELECT
        'customer_code_sequence_per_company',
        count(*),
        jsonb_build_object('company_count',count(*))
    FROM public.companies co
    LEFT JOIN private.customer_code_sequences s ON s.company_id = co.id
    WHERE s.company_id IS NULL OR s.next_value < 1

    UNION ALL

    SELECT
        'required_triggers_present',
        count(*) FILTER (WHERE t.oid IS NULL),
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(e.trigger_name ORDER BY e.trigger_name)
                    FILTER (WHERE t.oid IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_triggers e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid AND c.relname = e.table_name
    LEFT JOIN pg_trigger t
      ON t.tgrelid = c.oid
     AND t.tgname = e.trigger_name
     AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'authenticated_direct_write_closed',
        count(*),
        jsonb_build_object(
            'tables',COALESCE(jsonb_agg(v.table_name),'[]'::jsonb)
        )
    FROM (
        SELECT table_name
        FROM (VALUES
            ('customers'),('customer_categories'),
            ('customer_category_audit'),('customer_master_audit')
        ) expected(table_name)
        WHERE has_table_privilege(
            'authenticated','public.' || table_name,
            'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
        )
    ) v

    UNION ALL

    SELECT
        'guarded_rpc_privileges',
        count(*) FILTER (WHERE NOT authenticated_execute OR anon_execute),
        jsonb_build_object(
            'invalid',COALESCE(
                jsonb_agg(signature)
                    FILTER (WHERE NOT authenticated_execute OR anon_execute),
                '[]'::jsonb
            )
        )
    FROM (
        SELECT
            signature,
            has_function_privilege(
                'authenticated',signature,'EXECUTE'
            ) AS authenticated_execute,
            has_function_privilege('anon',signature,'EXECUTE') AS anon_execute
        FROM (VALUES
            ('public.save_customer_category(uuid,bigint,text,text,boolean)'),
            ('public.save_customer(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean)')
        ) expected(signature)
    ) privileges
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
