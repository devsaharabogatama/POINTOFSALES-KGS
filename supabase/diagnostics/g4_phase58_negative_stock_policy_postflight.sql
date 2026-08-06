-- G4 phase 58 postflight: negative-stock configuration foundation.
-- SAFETY: SELECT-only and aggregate-only.

WITH expected_tables(table_name) AS (VALUES
    ('pos_negative_stock_policies'),('pos_negative_stock_permissions'),
    ('pos_negative_stock_authorizations'),('negative_stock_sale_allocations'),
    ('negative_stock_replenishment_allocations'),
    ('pos_negative_stock_configuration_audit')
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations WHERE version='20260805190000'

    UNION ALL
    SELECT 'required_negative_stock_tables',
        CASE WHEN count(state.table_name)=6 THEN 'PASS' ELSE 'FAIL' END,
        6-count(state.table_name),jsonb_build_object(
            'expected',6,'table_rows',count(state.table_name),
            'missing',COALESCE(jsonb_agg(expected.table_name ORDER BY expected.table_name)
                FILTER(WHERE state.table_name IS NULL),'[]'::JSONB))
    FROM expected_tables expected LEFT JOIN information_schema.tables state
      ON state.table_schema='public' AND state.table_name=expected.table_name

    UNION ALL
    SELECT 'negative_stock_feature_catalog',
        CASE WHEN count(*)=1 AND bool_and(is_active) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 AND bool_and(is_active) THEN 0 ELSE 1 END,
        jsonb_build_object('catalog_rows',count(*))
    FROM public.platform_features WHERE feature_code='pos_negative_stock_enabled'

    UNION ALL
    SELECT 'active_company_default_policy_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    LEFT JOIN public.pos_negative_stock_policies policy
      ON policy.company_id=company.id
    WHERE company.status='ACTIVE'
      AND (policy.id IS NULL OR policy.is_active OR NOT policy.require_reason)

    UNION ALL
    SELECT 'negative_stock_entitlement_default_off',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('enabled_companies',count(*))
    FROM public.company_features feature
    WHERE feature.feature_code='pos_negative_stock_enabled'
      AND feature.is_enabled

    UNION ALL
    SELECT 'warehouse_opt_in_default_off',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('enabled_warehouses',count(*))
    FROM public.warehouses WHERE allow_negative_stock

    UNION ALL
    SELECT 'required_guarded_configuration_routines',
        CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,3-count(*),
        jsonb_build_object('routine_rows',count(*),'expected',3)
    FROM pg_proc routine JOIN pg_namespace namespace
      ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='public' AND routine.proname IN(
        'save_pos_negative_stock_policy','set_warehouse_negative_stock_opt_in',
        'save_pos_negative_stock_permission'
    )

    UNION ALL
    SELECT 'sale_runtime_remains_fail_closed',
        CASE WHEN definition~'STOCK_SHORTAGE'
                  AND definition!~'NEGATIVE_STOCK_AUTHORIZATION'
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN definition~'STOCK_SHORTAGE'
                  AND definition!~'NEGATIVE_STOCK_AUTHORIZATION'
             THEN 0 ELSE 1 END,jsonb_build_object('routine_rows',1)
    FROM (SELECT pg_get_functiondef(
        'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) definition) runtime

    UNION ALL
    SELECT 'negative_inventory_remains_closed',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT 1 FROM public.product_stocks WHERE stock_qty<0
        UNION ALL
        SELECT 1 FROM public.product_batches
        WHERE qty_purchased<0 OR qty_remaining<0
    ) invalid

    UNION ALL
    SELECT 'configuration_reference_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pos_negative_stock_permissions permission
    LEFT JOIN public.warehouses warehouse
      ON warehouse.company_id=permission.company_id
     AND warehouse.id=permission.warehouse_id
    LEFT JOIN public.profiles profile ON profile.id=permission.user_id
    WHERE warehouse.id IS NULL OR profile.id IS NULL

    UNION ALL
    SELECT 'browser_negative_stock_write_boundary',
        CASE WHEN NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_policies','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_permissions','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_authorizations','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.warehouses','UPDATE') THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_policies','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_permissions','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.pos_negative_stock_authorizations','INSERT,UPDATE,DELETE')
                  AND NOT has_table_privilege('authenticated',
                  'public.warehouses','UPDATE') THEN 0 ELSE 1 END,
        jsonb_build_object(
            'policy_write',has_table_privilege('authenticated',
                'public.pos_negative_stock_policies','INSERT,UPDATE,DELETE'),
            'permission_write',has_table_privilege('authenticated',
                'public.pos_negative_stock_permissions','INSERT,UPDATE,DELETE'),
            'warehouse_update',has_table_privilege('authenticated',
                'public.warehouses','UPDATE'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
