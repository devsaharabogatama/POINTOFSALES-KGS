-- G2 phase 46 postflight: Product-Warehouse minimum-stock foundation/import.
-- Expected: 12 PASS rows with violation_rows = 0.

WITH expected_columns(table_name,column_name) AS (
    VALUES
        ('product_warehouse_stock_settings','id'),
        ('product_warehouse_stock_settings','company_id'),
        ('product_warehouse_stock_settings','product_id'),
        ('product_warehouse_stock_settings','warehouse_id'),
        ('product_warehouse_stock_settings','minimum_stock_base_qty'),
        ('product_warehouse_stock_settings','low_stock_alert_enabled'),
        ('product_warehouse_stock_settings','master_version'),
        ('product_warehouse_stock_settings','created_by'),
        ('product_warehouse_stock_settings','updated_by'),
        ('product_warehouse_stock_settings','created_at'),
        ('product_warehouse_stock_settings','updated_at'),
        ('product_warehouse_stock_setting_audit','id'),
        ('product_warehouse_stock_setting_audit','company_id'),
        ('product_warehouse_stock_setting_audit','setting_id'),
        ('product_warehouse_stock_setting_audit','action'),
        ('product_warehouse_stock_setting_audit','actor_id'),
        ('product_warehouse_stock_setting_audit','before_state'),
        ('product_warehouse_stock_setting_audit','after_state'),
        ('product_warehouse_stock_setting_audit','created_at')
), expected_constraints(constraint_name) AS (
    VALUES
        ('product_warehouse_stock_settings_pair_unique'),
        ('fk_product_warehouse_stock_settings_product'),
        ('fk_product_warehouse_stock_settings_warehouse'),
        ('product_warehouse_stock_settings_minimum_nonnegative'),
        ('product_warehouse_stock_settings_alert_threshold'),
        ('product_warehouse_stock_settings_version_positive'),
        ('fk_product_warehouse_stock_setting_audit_setting')
), expected_indexes(index_name) AS (
    VALUES
        ('idx_product_warehouse_stock_settings_company_warehouse_alert'),
        ('idx_product_warehouse_stock_settings_company_product'),
        ('idx_product_warehouse_stock_setting_audit_setting_created')
), expected_routines(routine_name) AS (
    VALUES
        ('save_product_warehouse_stock_setting'),
        ('validate_master_import_minimum_stock_job'),
        ('commit_master_import_minimum_stock_job'),
        ('g2_phase46_import_error')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260728090000'

    UNION ALL

    SELECT
        'required_tables',
        count(*) FILTER (WHERE c.oid IS NULL),
        jsonb_build_object(
            'table_rows',count(*) FILTER (WHERE c.oid IS NOT NULL)
        )
    FROM (
        VALUES
            ('product_warehouse_stock_settings'),
            ('product_warehouse_stock_setting_audit')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'required_columns',
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'column_rows',count(*) FILTER (WHERE c.column_name IS NOT NULL)
        )
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'required_constraints',
        count(*) FILTER (WHERE con.oid IS NULL),
        jsonb_build_object(
            'constraint_rows',count(*) FILTER (WHERE con.oid IS NOT NULL)
        )
    FROM expected_constraints e
    LEFT JOIN pg_constraint con ON con.conname = e.constraint_name

    UNION ALL

    SELECT
        'required_indexes',
        count(*) FILTER (WHERE i.indexname IS NULL),
        jsonb_build_object(
            'index_rows',count(*) FILTER (WHERE i.indexname IS NOT NULL)
        )
    FROM expected_indexes e
    LEFT JOIN pg_indexes i
      ON i.schemaname = 'public'
     AND i.indexname = e.index_name

    UNION ALL

    SELECT
        'required_routines',
        count(*) FILTER (WHERE p.oid IS NULL),
        jsonb_build_object(
            'routine_rows',count(*) FILTER (WHERE p.oid IS NOT NULL)
        )
    FROM expected_routines e
    LEFT JOIN pg_namespace n
      ON n.nspname = CASE
          WHEN e.routine_name = 'save_product_warehouse_stock_setting'
          THEN 'public' ELSE 'private' END
    LEFT JOIN pg_proc p
      ON p.pronamespace = n.oid
     AND p.proname = e.routine_name

    UNION ALL

    SELECT
        'rls_and_policy_boundary',
        count(*) FILTER (
            WHERE NOT c.relrowsecurity OR COALESCE(p.policy_count,0) = 0
        ),
        jsonb_build_object(
            'secured_tables',count(*) FILTER (
                WHERE c.relrowsecurity AND COALESCE(p.policy_count,0) > 0
            )
        )
    FROM (
        VALUES
            ('product_warehouse_stock_settings'),
            ('product_warehouse_stock_setting_audit')
    ) e(table_name)
    JOIN pg_namespace n ON n.nspname = 'public'
    JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
    LEFT JOIN (
        SELECT tablename,count(*) AS policy_count
        FROM pg_policies
        WHERE schemaname = 'public'
        GROUP BY tablename
    ) p ON p.tablename = e.table_name

    UNION ALL

    SELECT
        'browser_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated',
                'public.product_warehouse_stock_settings',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated',
                'public.product_warehouse_stock_setting_audit',
                'INSERT,UPDATE,DELETE'
            )
            OR has_function_privilege(
                'anon',
                'public.save_product_warehouse_stock_setting(uuid,bigint,uuid,uuid,numeric,boolean)',
                'EXECUTE'
            )
            OR NOT has_function_privilege(
                'authenticated',
                'public.save_product_warehouse_stock_setting(uuid,bigint,uuid,uuid,numeric,boolean)',
                'EXECUTE'
            )
        THEN 1 ELSE 0 END::BIGINT,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated',
                'public.product_warehouse_stock_settings',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'minimum_stock_import_job_type',
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    WHERE n.nspname = 'public'
      AND rel.relname = 'master_import_jobs'
      AND con.conname = 'master_import_jobs_type_check'
      AND position(
          'PRODUCT_WAREHOUSE_MINIMUM_STOCK'
          IN pg_get_constraintdef(con.oid)
      ) > 0

    UNION ALL

    SELECT
        'minimum_stock_import_dispatch',
        CASE WHEN count(*) = 5 AND bool_and(
            position(
                'PRODUCT_WAREHOUSE_MINIMUM_STOCK' IN p.prosrc
            ) > 0
        ) THEN 0 ELSE 1 END::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE (n.nspname,p.proname) IN (
        ('public','create_master_import_job'),
        ('public','validate_master_import_job'),
        ('public','commit_master_import_job'),
        ('private','trg_g2_capture_import_master_version'),
        ('private','trg_g2_validate_import_business_fields')
    )

    UNION ALL

    SELECT
        'invalid_minimum_stock_setting',
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.product_warehouse_stock_settings s
    LEFT JOIN public.products p
      ON p.company_id = s.company_id AND p.id = s.product_id
    LEFT JOIN public.warehouses w
      ON w.company_id = s.company_id AND w.id = s.warehouse_id
    WHERE p.id IS NULL
       OR w.id IS NULL
       OR s.master_version <= 0
       OR s.minimum_stock_base_qty < 0
       OR (
           s.low_stock_alert_enabled
           AND s.minimum_stock_base_qty IS NULL
       )

    UNION ALL

    SELECT
        'duplicate_product_warehouse_setting',
        count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,product_id,warehouse_id
        FROM public.product_warehouse_stock_settings
        GROUP BY company_id,product_id,warehouse_id
        HAVING count(*) > 1
    ) duplicate_groups
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
