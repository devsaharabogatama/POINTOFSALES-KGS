-- G2 phase 26 postflight: guarded Product/Category Tax assignment.
-- Expected result: all rows PASS with violation_rows = 0.

WITH required_routines(signature) AS (
    VALUES
        ('public.save_product_category_tax_assignment(uuid,bigint,uuid,uuid)'),
        ('public.save_product_tax_assignment(uuid,bigint,uuid,uuid)'),
        ('public.save_product_with_uoms(uuid,bigint,text,text,uuid,uuid,uuid,numeric,boolean,text,boolean,jsonb,uuid,uuid)')
), assignment_rows AS (
    SELECT
        pc.company_id,
        assignment.tax_scope,
        assignment.tax_rule_id
    FROM public.product_categories pc
    CROSS JOIN LATERAL (
        VALUES
            ('SALES'::TEXT,pc.default_sales_tax_rule_id),
            ('PURCHASE'::TEXT,pc.default_purchase_tax_rule_id)
    ) assignment(tax_scope,tax_rule_id)
    WHERE assignment.tax_rule_id IS NOT NULL
    UNION ALL
    SELECT
        p.company_id,
        assignment.tax_scope,
        assignment.tax_rule_id
    FROM public.products p
    CROSS JOIN LATERAL (
        VALUES
            ('SALES'::TEXT,p.sales_tax_rule_id),
            ('PURCHASE'::TEXT,p.purchase_tax_rule_id)
    ) assignment(tax_scope,tax_rule_id)
    WHERE assignment.tax_rule_id IS NOT NULL
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260723040000'

    UNION ALL

    SELECT
        'tax_assignment_audit_table',
        CASE WHEN to_regclass('public.tax_assignment_audit') IS NOT NULL
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'exists',to_regclass('public.tax_assignment_audit') IS NOT NULL
        )

    UNION ALL

    SELECT
        'tax_assignment_audit_rls',
        CASE WHEN c.relrowsecurity THEN 0 ELSE 1 END,
        jsonb_build_object('rls_enabled',COALESCE(c.relrowsecurity,FALSE))
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = 'tax_assignment_audit'

    UNION ALL

    SELECT
        'required_assignment_routines',
        count(*) FILTER(WHERE to_regprocedure(signature) IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(signature ORDER BY signature)
                    FILTER(WHERE to_regprocedure(signature) IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_routines

    UNION ALL

    SELECT
        'authenticated_assignment_execute',
        count(*) FILTER(
            WHERE to_regprocedure(signature) IS NULL
               OR NOT has_function_privilege(
                    'authenticated',to_regprocedure(signature),'EXECUTE'
               )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM required_routines

    UNION ALL

    SELECT
        'anon_assignment_execute',
        count(*) FILTER(
            WHERE to_regprocedure(signature) IS NOT NULL
              AND has_function_privilege(
                    'anon',to_regprocedure(signature),'EXECUTE'
              )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM required_routines

    UNION ALL

    SELECT
        'assignment_guard_trigger',
        CASE WHEN count(*) = 2 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND t.tgname IN (
          'g2_guard_product_category_tax_assignment',
          'g2_guard_product_tax_assignment'
      )
      AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'direct_category_tax_column_write',
        (
            has_column_privilege(
                'authenticated','public.product_categories',
                'default_sales_tax_rule_id','INSERT'
            )::INT
            + has_column_privilege(
                'authenticated','public.product_categories',
                'default_sales_tax_rule_id','UPDATE'
            )::INT
            + has_column_privilege(
                'authenticated','public.product_categories',
                'default_purchase_tax_rule_id','INSERT'
            )::INT
            + has_column_privilege(
                'authenticated','public.product_categories',
                'default_purchase_tax_rule_id','UPDATE'
            )::INT
        )::BIGINT,
        jsonb_build_object(
            'table_insert',has_table_privilege(
                'authenticated','public.product_categories','INSERT'
            ),
            'table_update',has_table_privilege(
                'authenticated','public.product_categories','UPDATE'
            )
        )

    UNION ALL

    SELECT
        'category_identity_column_compatibility',
        CASE WHEN
            has_column_privilege(
                'authenticated','public.product_categories',
                'company_id','INSERT'
            )
            AND has_column_privilege(
                'authenticated','public.product_categories',
                'category_code','INSERT'
            )
            AND has_column_privilege(
                'authenticated','public.product_categories',
                'category_code','UPDATE'
            )
            AND has_column_privilege(
                'authenticated','public.product_categories',
                'category_name','INSERT'
            )
            AND has_column_privilege(
                'authenticated','public.product_categories',
                'category_name','UPDATE'
            )
            AND has_column_privilege(
                'authenticated','public.product_categories',
                'is_active','INSERT'
            )
            AND has_column_privilege(
                'authenticated','public.product_categories',
                'is_active','UPDATE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object('column_grants_present',TRUE)

    UNION ALL

    SELECT
        'invalid_effective_assignment',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM assignment_rows a
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.tax_rules r
        JOIN public.tax_rule_versions v
          ON v.company_id = r.company_id AND v.tax_rule_id = r.id
        WHERE r.company_id = a.company_id
          AND r.id = a.tax_rule_id
          AND r.tax_scope = a.tax_scope
          AND r.is_active
          AND v.status = 'ACTIVE'
          AND v.effective_from <= CURRENT_TIMESTAMP
          AND (v.effective_to IS NULL OR v.effective_to > CURRENT_TIMESTAMP)
    )

    UNION ALL

    SELECT
        'audit_browser_write_boundary',
        CASE WHEN has_table_privilege(
            'authenticated','public.tax_assignment_audit',
            'INSERT,UPDATE,DELETE'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated','public.tax_assignment_audit',
                'INSERT,UPDATE,DELETE'
            )
        )
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
