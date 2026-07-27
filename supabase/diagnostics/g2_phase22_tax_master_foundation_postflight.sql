-- G2 phase 22 postflight: Tax master foundation.
-- Expected: 14 PASS rows with violation_rows = 0.

WITH expected_tables(table_name) AS (
    VALUES ('tax_rules'),('tax_rule_versions'),('tax_master_audit')
), expected_assignment_columns(table_name,column_name) AS (
    VALUES
        ('product_categories','default_sales_tax_rule_id'),
        ('product_categories','default_purchase_tax_rule_id'),
        ('products','sales_tax_rule_id'),
        ('products','purchase_tax_rule_id')
), expected_snapshot_columns(table_name,column_name) AS (
    VALUES
        ('sales_details','tax_rule_id'),
        ('sales_details','tax_rule_version'),
        ('sales_details','tax_code_snapshot'),
        ('sales_details','tax_name_snapshot'),
        ('sales_details','tax_scope_snapshot'),
        ('sales_details','tax_rate_percent_snapshot'),
        ('sales_details','tax_price_mode_snapshot'),
        ('sales_details','tax_calculation_scope_snapshot'),
        ('sales_details','tax_base'),
        ('sales_details','tax_amount'),
        ('sales_details','tax_rounding'),
        ('sales_details','tax_account_id'),
        ('sales_details','tax_account_code_snapshot'),
        ('sales_details','tax_account_name_snapshot'),
        ('purchases_details','tax_rule_id'),
        ('purchases_details','tax_rule_version'),
        ('purchases_details','tax_code_snapshot'),
        ('purchases_details','tax_name_snapshot'),
        ('purchases_details','tax_scope_snapshot'),
        ('purchases_details','tax_rate_percent_snapshot'),
        ('purchases_details','tax_price_mode_snapshot'),
        ('purchases_details','tax_calculation_scope_snapshot'),
        ('purchases_details','tax_is_recoverable_snapshot'),
        ('purchases_details','tax_base'),
        ('purchases_details','tax_amount'),
        ('purchases_details','tax_rounding'),
        ('purchases_details','tax_account_id'),
        ('purchases_details','tax_account_code_snapshot'),
        ('purchases_details','tax_account_name_snapshot')
), expected_private_routines(routine_name) AS (
    VALUES
        ('trg_g2_guard_tax_rule_header'),
        ('trg_g2_guard_tax_rule_version'),
        ('trg_g2_guard_tax_assignment')
), expected_triggers(table_name,trigger_name) AS (
    VALUES
        ('tax_rules','g2_guard_tax_rule_header'),
        ('tax_rules','g2_touch_tax_rules'),
        ('tax_rule_versions','g2_guard_tax_rule_versions'),
        ('product_categories','g2_guard_product_category_tax_assignment'),
        ('products','g2_guard_product_tax_assignment')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        count(*) <> 1 AS violated,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260723010000'

    UNION ALL

    SELECT
        'canonical_tax_tables',
        count(c.oid) <> 3,
        jsonb_build_object('table_rows',count(c.oid))
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'tax_assignment_columns',
        count(c.column_name) <> 4,
        jsonb_build_object('column_rows',count(c.column_name))
    FROM expected_assignment_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'tax_snapshot_columns',
        count(c.column_name) <> 29,
        jsonb_build_object('column_rows',count(c.column_name))
    FROM expected_snapshot_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'tax_private_guard_routines',
        count(p.oid) <> 3,
        jsonb_build_object('routine_rows',count(p.oid))
    FROM expected_private_routines e
    LEFT JOIN pg_namespace n ON n.nspname = 'private'
    LEFT JOIN pg_proc p
      ON p.pronamespace = n.oid
     AND p.proname = e.routine_name
     AND p.prosecdef
     AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
         @> ARRAY['search_path=public, pg_temp']::TEXT[]
     AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')

    UNION ALL

    SELECT
        'tax_guard_triggers',
        count(t.oid) <> 5,
        jsonb_build_object('trigger_rows',count(t.oid))
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
        'guarded_tax_rpc',
        p.oid IS NULL OR NOT p.prosecdef
        OR NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
            @> ARRAY['search_path=public, pg_temp']::TEXT[],
        jsonb_build_object('routine_rows',CASE WHEN p.oid IS NULL THEN 0 ELSE 1 END)
    FROM (SELECT to_regprocedure(
        'public.save_tax_rule(uuid,bigint,text,text,text,numeric,text,text,uuid,boolean,timestamp with time zone,timestamp with time zone,text,boolean)'
    ) AS oid) expected
    LEFT JOIN pg_proc p ON p.oid = expected.oid

    UNION ALL

    SELECT
        'guarded_tax_rpc_privilege',
        p.oid IS NULL
        OR has_function_privilege('anon',p.oid,'EXECUTE')
        OR NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
        OR NOT has_function_privilege('service_role',p.oid,'EXECUTE'),
        jsonb_build_object(
            'anon_execute',COALESCE(has_function_privilege('anon',p.oid,'EXECUTE'),FALSE),
            'authenticated_execute',COALESCE(
                has_function_privilege('authenticated',p.oid,'EXECUTE'),FALSE
            )
        )
    FROM (SELECT to_regprocedure(
        'public.save_tax_rule(uuid,bigint,text,text,text,numeric,text,text,uuid,boolean,timestamp with time zone,timestamp with time zone,text,boolean)'
    ) AS oid) expected
    LEFT JOIN pg_proc p ON p.oid = expected.oid

    UNION ALL

    SELECT
        'direct_tax_master_write_closed',
        has_table_privilege(
            'authenticated','public.tax_rules','INSERT,UPDATE,DELETE'
        ) OR has_table_privilege(
            'authenticated','public.tax_rule_versions','INSERT,UPDATE,DELETE'
        ) OR has_table_privilege(
            'authenticated','public.tax_master_audit','INSERT,UPDATE,DELETE'
        ),
        jsonb_build_object(
            'tax_rules_write',has_table_privilege(
                'authenticated','public.tax_rules','INSERT,UPDATE,DELETE'
            ),
            'tax_versions_write',has_table_privilege(
                'authenticated','public.tax_rule_versions','INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'tax_master_rls',
        count(*) <> 3,
        jsonb_build_object('rls_table_rows',count(*))
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN ('tax_rules','tax_rule_versions','tax_master_audit')
      AND c.relrowsecurity

    UNION ALL

    SELECT
        'tax_master_select_policies',
        count(*) <> 3,
        jsonb_build_object('policy_rows',count(*))
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('tax_rules','tax_rule_versions','tax_master_audit')
      AND cmd = 'SELECT'

    UNION ALL

    SELECT
        'existing_sales_tax_snapshot_untouched',
        count(*) > 0,
        jsonb_build_object('populated_rows',count(*))
    FROM public.sales_details
    WHERE tax_rule_id IS NOT NULL
       OR tax_rule_version IS NOT NULL
       OR tax_amount IS NOT NULL

    UNION ALL

    SELECT
        'existing_purchase_tax_snapshot_untouched',
        count(*) > 0,
        jsonb_build_object('populated_rows',count(*))
    FROM public.purchases_details
    WHERE tax_rule_id IS NOT NULL
       OR tax_rule_version IS NOT NULL
       OR tax_amount IS NOT NULL

    UNION ALL

    SELECT
        'tax_rule_version_integrity',
        count(*) > 0,
        jsonb_build_object('invalid_rows',count(*))
    FROM public.tax_rule_versions v
    JOIN public.tax_rules r
      ON r.company_id = v.company_id AND r.id = v.tax_rule_id
    JOIN public.chart_of_accounts coa
      ON coa.company_id = v.company_id AND coa.id = v.account_id
    WHERE (r.tax_scope = 'SALES' AND (
              v.account_function_key <> 'OUTPUT_TAX'
              OR v.default_price_mode <> 'INCLUSIVE'
              OR v.is_recoverable IS NOT NULL
              OR coa.account_type <> 'LIABILITY'
          ))
       OR (r.tax_scope = 'PURCHASE' AND (
              v.account_function_key <> 'INPUT_TAX'
              OR v.is_recoverable IS NULL
              OR coa.account_type <> 'ASSET'
          ))
)
SELECT
    check_name,
    CASE WHEN violated THEN 'FAIL' ELSE 'PASS' END AS status,
    CASE WHEN violated THEN 1 ELSE 0 END::BIGINT AS violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violated THEN 1 ELSE 2 END,check_name;

