-- G4 phase 14 postflight: authoritative Offline catalog snapshot RPC.
-- SAFETY: SELECT-only and aggregate-only.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260730010000'

    UNION ALL

    SELECT
        'offline_catalog_snapshot_rpc',
        CASE WHEN to_regprocedure(
            'public.get_pos_offline_catalog_snapshot(uuid)'
        ) IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'rpc_exists',to_regprocedure(
                'public.get_pos_offline_catalog_snapshot(uuid)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'offline_catalog_snapshot_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.get_pos_offline_catalog_snapshot(uuid)','EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.get_pos_offline_catalog_snapshot(uuid)','EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.get_pos_offline_catalog_snapshot(uuid)','EXECUTE'
            ),
            'anon_execute',has_function_privilege(
                'anon',
                'public.get_pos_offline_catalog_snapshot(uuid)','EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'offline_entitlement_remains_closed',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        jsonb_build_object('enabled_companies',count(*))
    FROM public.company_features
    WHERE feature_code = 'offline_pos_enabled' AND is_enabled

    UNION ALL

    SELECT
        'terminal_policy_configuration_scope',
        CASE WHEN count(*) = 0 THEN 'SETUP' ELSE 'INFO' END,
        jsonb_build_object(
            'enabled_terminal_policies',count(*),
            'active_companies',(
                SELECT count(*) FROM public.companies
                WHERE status = 'ACTIVE'
            )
        )
    FROM public.pos_offline_allowance_policies
    WHERE scope_type = 'TERMINAL' AND is_enabled

    UNION ALL

    SELECT
        'offline_snapshot_source_inventory',
        'INFO',
        jsonb_build_object(
            'active_product_uoms',(
                SELECT count(*) FROM public.product_uoms
                WHERE is_active AND sales_allowed
            ),
            'active_pricelist_rules',(
                SELECT count(*) FROM public.pricelist_rules WHERE is_active
            ),
            'active_sales_tax_rules',(
                SELECT count(*) FROM public.tax_rules
                WHERE is_active AND tax_scope = 'SALES'
            ),
            'active_payment_methods',(
                SELECT count(*) FROM public.payment_methods WHERE is_active
            ),
            'active_allowances',(
                SELECT count(*) FROM public.pos_offline_stock_allowances
                WHERE status = 'ACTIVE'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'SETUP' THEN 2
                WHEN 'PASS' THEN 3 ELSE 4 END,
    check_name;
