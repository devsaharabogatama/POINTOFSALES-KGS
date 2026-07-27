-- G2 phase 14 Payment Method foundation postflight. SELECT-only.
-- Expected result: 13 PASS rows.

WITH expected_tables(table_name) AS (
    VALUES
        ('payment_methods'),
        ('payment_method_store_assignments'),
        ('payment_method_master_audit')
), expected_snapshot_columns(column_name) AS (
    VALUES
        ('payment_method_id'),
        ('payment_method_code_snapshot'),
        ('payment_method_name_snapshot'),
        ('payment_method_type_snapshot'),
        ('settlement_route_snapshot'),
        ('fee_bearer_snapshot'),
        ('fee_type_snapshot'),
        ('fee_percent_snapshot'),
        ('fee_fixed_amount_snapshot'),
        ('configured_fee_amount'),
        ('customer_surcharge_amount')
), checks AS (
    SELECT 'migration_ledger'::text AS check_name,
        count(*) = 1 AS passed,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722120000'

    UNION ALL
    SELECT 'canonical_tables',count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NOT NULL
        ) = count(*),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(table_name ORDER BY table_name)
                FILTER (WHERE to_regclass('public.' || table_name) IS NULL),
                '[]'::jsonb)
        )
    FROM expected_tables

    UNION ALL
    SELECT 'canonical_tables_rls',count(*) FILTER (
            WHERE c.relrowsecurity
        ) = count(*),
        jsonb_build_object('rls_tables',count(*) FILTER (WHERE c.relrowsecurity))
    FROM expected_tables e
    JOIN pg_class c ON c.oid = ('public.' || e.table_name)::regclass

    UNION ALL
    SELECT 'canonical_table_policies',count(*) = 3,
        jsonb_build_object('policy_rows',count(*))
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
          'payment_methods','payment_method_store_assignments',
          'payment_method_master_audit'
      )

    UNION ALL
    SELECT 'sales_payment_snapshot_columns',count(*) FILTER (
            WHERE c.column_name IS NOT NULL
        ) = count(*),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(e.column_name ORDER BY e.column_name)
                FILTER (WHERE c.column_name IS NULL),'[]'::jsonb)
        )
    FROM expected_snapshot_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_payments'
     AND c.column_name = e.column_name

    UNION ALL
    SELECT 'sales_payment_method_fk',count(*) = 1,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint
    WHERE conrelid = 'public.sales_payments'::regclass
      AND conname = 'fk_sales_payments_company_payment_method'
      AND convalidated

    UNION ALL
    SELECT 'active_company_default_invariant',count(*) = 0,
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT c.id
        FROM public.companies c
        LEFT JOIN public.payment_methods pm
          ON pm.company_id = c.id
         AND pm.is_default
         AND pm.is_active
        WHERE c.status = 'ACTIVE'
        GROUP BY c.id
        HAVING count(pm.id) <> 1
    ) invalid

    UNION ALL
    SELECT 'default_cash_provisioning',count(*) = 0,
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1 FROM public.payment_methods pm
          WHERE pm.company_id = c.id
            AND pm.payment_method_code = 'CASH'
            AND pm.payment_method_name = 'Tunai'
            AND pm.method_type = 'CASH'
            AND pm.settlement_route = 'CASH_DRAWER'
            AND pm.is_default
            AND pm.is_active
      )

    UNION ALL
    SELECT 'invalid_store_assignment',count(*) = 0,
        jsonb_build_object('row_count',count(*))
    FROM public.payment_method_store_assignments a
    JOIN public.payment_methods pm
      ON pm.company_id = a.company_id AND pm.id = a.payment_method_id
    WHERE pm.available_all_stores

    UNION ALL
    SELECT 'guard_triggers',count(*) = 5,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger
    WHERE NOT tgisinternal
      AND tgname IN (
          'g2_touch_payment_methods',
          'g2_guard_payment_method_history',
          'g2_require_default_payment_method',
          'g2_guard_company_activation_payment_method',
          'g2_provision_default_payment_method'
      )

    UNION ALL
    SELECT 'guarded_rpc_privilege',has_function_privilege(
        'authenticated',
        'public.save_payment_method(uuid,bigint,text,text,text,text,boolean,boolean,uuid[],text,boolean,text,text,numeric,numeric,text,text,timestamp with time zone,timestamp with time zone,boolean)',
        'EXECUTE'
    ),jsonb_build_object('expected','authenticated executable')

    UNION ALL
    SELECT 'direct_browser_writes_closed',
        NOT has_table_privilege(
            'authenticated','public.payment_methods','INSERT,UPDATE,DELETE'
        ) AND NOT has_table_privilege(
            'authenticated',
            'public.payment_method_store_assignments','INSERT,UPDATE,DELETE'
        ) AND NOT has_table_privilege(
            'authenticated',
            'public.payment_method_master_audit','INSERT,UPDATE,DELETE'
        ),jsonb_build_object('expected','guarded RPC only')

    UNION ALL
    SELECT 'legacy_checkout_compatibility',count(*) = 4,
        jsonb_build_object(
            'enum_labels',COALESCE(jsonb_agg(e.enumlabel ORDER BY e.enumsortorder),
                '[]'::jsonb)
        )
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE n.nspname = 'public' AND t.typname = 'payment_method'
)
SELECT check_name,
    CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS status,
    details
FROM checks
ORDER BY CASE WHEN passed THEN 2 ELSE 1 END,check_name;
