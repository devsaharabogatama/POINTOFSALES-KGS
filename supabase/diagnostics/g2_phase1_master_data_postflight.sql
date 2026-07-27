-- G2 phase 1 postflight. SELECT-only.
-- Expected result: every row PASS.

WITH expected_tables(table_name, expected_policies) AS (
    VALUES
        ('product_categories', 3),
        ('product_uoms', 3)
), expected_columns(table_name, column_name, nullable) AS (
    VALUES
        ('product_categories','company_id','NO'),
        ('product_categories','category_code','NO'),
        ('product_categories','category_name','NO'),
        ('product_categories','master_version','NO'),
        ('uoms','uom_type','NO'),
        ('uoms','allow_decimal','NO'),
        ('uoms','decimal_precision','NO'),
        ('uoms','is_active','NO'),
        ('uoms','master_version','NO'),
        ('warehouses','warehouse_type','YES'),
        ('warehouses','store_id','YES'),
        ('warehouses','allow_negative_stock','NO'),
        ('warehouses','master_version','NO'),
        ('products','category_id','YES'),
        ('products','weight_reference_uom_id','YES'),
        ('products','image_url','YES'),
        ('products','master_version','NO'),
        ('product_uoms','company_id','NO'),
        ('product_uoms','product_id','NO'),
        ('product_uoms','uom_id','NO'),
        ('product_uoms','factor_to_base','NO'),
        ('product_uoms','purchase_price','YES'),
        ('product_uoms','sale_price','YES'),
        ('product_uoms','conversion_version','NO'),
        ('product_uoms','master_version','NO')
), expected_constraints(table_name, constraint_name) AS (
    VALUES
        ('warehouses','fk_warehouses_company_store'),
        ('products','fk_products_company_category'),
        ('products','fk_products_company_weight_reference_uom'),
        ('product_uoms','fk_product_uoms_company_product'),
        ('product_uoms','fk_product_uoms_company_uom'),
        ('product_uoms','product_uoms_company_product_uom_unique')
), expected_triggers(table_name, trigger_name) AS (
    VALUES
        ('product_categories','g2_touch_product_categories'),
        ('uoms','g2_touch_uoms'),
        ('warehouses','g2_touch_warehouses'),
        ('products','g2_guard_products_base_uom'),
        ('products','g2_touch_products'),
        ('product_uoms','g2_guard_product_uoms'),
        ('product_uoms','g2_touch_product_uoms')
), table_checks AS (
    SELECT
        'table:' || e.table_name AS check_name,
        CASE
            WHEN c.oid IS NOT NULL
             AND c.relrowsecurity
             AND count(p.policyname) = e.expected_policies
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists', c.oid IS NOT NULL,
            'rls_enabled', COALESCE(c.relrowsecurity,FALSE),
            'expected_policies', e.expected_policies,
            'actual_policies', count(p.policyname)
        ) AS details
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')
    LEFT JOIN pg_policies p
      ON p.schemaname = 'public'
     AND p.tablename = e.table_name
    GROUP BY e.table_name,e.expected_policies,c.oid,c.relrowsecurity
), column_checks AS (
    SELECT
        'column:' || e.table_name || '.' || e.column_name AS check_name,
        CASE WHEN c.column_name IS NOT NULL
                   AND c.is_nullable = e.nullable
             THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'exists', c.column_name IS NOT NULL,
            'expected_nullable', e.nullable,
            'actual_nullable', c.is_nullable
        ) AS details
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name
), constraint_checks AS (
    SELECT
        'constraint:' || e.constraint_name AS check_name,
        CASE WHEN c.oid IS NOT NULL AND c.convalidated
             THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'table',e.table_name,
            'exists',c.oid IS NOT NULL,
            'validated',COALESCE(c.convalidated,FALSE)
        ) AS details
    FROM expected_constraints e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel
      ON rel.relnamespace = n.oid AND rel.relname = e.table_name
    LEFT JOIN pg_constraint c
      ON c.conrelid = rel.oid AND c.conname = e.constraint_name
), trigger_checks AS (
    SELECT
        'trigger:' || e.table_name || '.' || e.trigger_name AS check_name,
        CASE WHEN t.oid IS NOT NULL AND t.tgenabled <> 'D'
             THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object(
            'exists',t.oid IS NOT NULL,
            'enabled',COALESCE(t.tgenabled::text,'')
        ) AS details
    FROM expected_triggers e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel
      ON rel.relnamespace = n.oid AND rel.relname = e.table_name
    LEFT JOIN pg_trigger t
      ON t.tgrelid = rel.oid
     AND t.tgname = e.trigger_name
     AND NOT t.tgisinternal
), function_checks AS (
    SELECT
        'function:' || p.proname AS check_name,
        CASE
            WHEN p.oid IS NOT NULL
             AND (p.proname = 'trg_g2_touch_master' OR p.prosecdef)
             AND COALESCE(p.proconfig,ARRAY[]::text[])::text[]
                 @> ARRAY['search_path=public, pg_temp']::text[]
             AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'security_definer',p.prosecdef,
            'authenticated_execute',
                has_function_privilege('authenticated',p.oid,'EXECUTE'),
            'config',COALESCE(to_jsonb(p.proconfig),'[]'::jsonb)
        ) AS details
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname IN (
          'trg_g2_touch_master',
          'trg_g2_guard_product_base_uom',
          'trg_g2_guard_product_uom'
      )
), other_checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260721180000'

    UNION ALL

    SELECT
        'new_master_privileges',
        CASE
            WHEN has_table_privilege(
                'authenticated','public.product_categories','SELECT'
            )
             AND has_table_privilege(
                'authenticated','public.product_categories','INSERT'
            )
             AND has_table_privilege(
                'authenticated','public.product_categories','UPDATE'
            )
             AND has_table_privilege(
                'authenticated','public.product_uoms','SELECT'
            )
             AND has_table_privilege(
                'authenticated','public.product_uoms','INSERT'
            )
             AND has_table_privilege(
                'authenticated','public.product_uoms','UPDATE'
            )
             AND NOT has_table_privilege(
                'authenticated','public.product_categories','DELETE'
            )
             AND NOT has_table_privilege(
                'authenticated','public.product_uoms','DELETE'
            )
             AND NOT has_table_privilege(
                'anon','public.product_categories','SELECT'
            )
            THEN 'PASS' ELSE 'FAIL'
        END,
        jsonb_build_object(
            'authenticated_category_delete',has_table_privilege(
                'authenticated','public.product_categories','DELETE'
            ),
            'authenticated_product_uom_delete',has_table_privilege(
                'authenticated','public.product_uoms','DELETE'
            ),
            'anon_category_select',has_table_privilege(
                'anon','public.product_categories','SELECT'
            )
        )

    UNION ALL

    SELECT
        'legacy_compatibility_surface',
        CASE
            WHEN to_regclass('public.product_uom_conversions') IS NOT NULL
             AND EXISTS (
                 SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'products'
                   AND column_name = 'category'
             )
             AND EXISTS (
                 SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public'
                   AND table_name = 'products'
                   AND column_name = 'uom'
             )
            THEN 'PASS' ELSE 'FAIL'
        END,
        jsonb_build_object(
            'legacy_conversion_table',
                to_regclass('public.product_uom_conversions') IS NOT NULL,
            'legacy_product_category_column',EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'products'
                  AND column_name = 'category'
            ),
            'legacy_product_uom_column',EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'products'
                  AND column_name = 'uom'
            )
        )
)
SELECT check_name,status,details
FROM (
    SELECT * FROM table_checks
    UNION ALL SELECT * FROM column_checks
    UNION ALL SELECT * FROM constraint_checks
    UNION ALL SELECT * FROM trigger_checks
    UNION ALL SELECT * FROM function_checks
    UNION ALL SELECT * FROM other_checks
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
