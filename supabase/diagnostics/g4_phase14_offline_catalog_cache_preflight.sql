-- G4 phase 14 preflight: authoritative Offline catalog/cache readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Aggregate-only; no Product, Customer, Payment, or business names.
-- - Entitlement must remain disabled until cache + queue UAT is complete.

WITH required_versions(version) AS (
    VALUES ('20260729180000'),('20260729210000')
), active_company_features AS (
    SELECT
        c.id AS company_id,
        COALESCE(cf.is_enabled,FALSE) AS offline_enabled
    FROM public.companies c
    LEFT JOIN public.company_features cf
      ON cf.company_id = c.id
     AND cf.feature_code = 'offline_pos_enabled'
    WHERE c.status = 'ACTIVE'
), open_session_scope AS (
    SELECT
        cs.company_id,
        cs.id AS cashier_session_id,
        cs.store_id,
        cs.pos_id AS terminal_id,
        cs.sales_warehouse_id AS warehouse_id,
        EXISTS (
            SELECT 1
            FROM public.pos_offline_allowance_policies p
            WHERE p.company_id = cs.company_id
              AND p.scope_type = 'TERMINAL'
              AND p.store_id = cs.store_id
              AND p.terminal_id = cs.pos_id
              AND p.is_enabled
        ) AS terminal_enabled,
        EXISTS (
            SELECT 1
            FROM public.payment_methods pm
            WHERE pm.company_id = cs.company_id
              AND pm.is_active
              AND pm.method_type = 'CASH'
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments pmsa
                      WHERE pmsa.company_id = pm.company_id
                        AND pmsa.payment_method_id = pm.id
                        AND pmsa.store_id = cs.store_id
                  )
              )
        ) AS has_cash
    FROM public.cashier_sessions cs
    WHERE cs.status = 'OPEN'::public.session_status
), active_sale_product_uoms AS (
    SELECT
        pu.company_id,
        pu.product_id,
        pu.id AS product_uom_id,
        pu.uom_id,
        pu.factor_to_base,
        pu.sale_price,
        p.uom_id AS base_uom_id,
        p.is_bundle,
        u.allow_decimal,
        u.decimal_precision
    FROM public.product_uoms pu
    JOIN public.products p
      ON p.company_id = pu.company_id
     AND p.id = pu.product_id
     AND p.is_active
    JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
     AND u.is_active
    WHERE pu.is_active
      AND pu.sales_allowed
), checks AS (
    SELECT
        'g4_phase14_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'offline_entitlement_remains_closed',
        CASE WHEN count(*) FILTER (WHERE offline_enabled) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_companies',count(*),
            'enabled_companies',count(*) FILTER (WHERE offline_enabled)
        )
    FROM active_company_features

    UNION ALL

    SELECT
        'canonical_offline_catalog_snapshot_rpc',
        CASE WHEN to_regprocedure(
            'public.get_pos_offline_catalog_snapshot(uuid)'
        ) IS NULL THEN 'SETUP' ELSE 'PASS' END,
        jsonb_build_object(
            'rpc_exists',to_regprocedure(
                'public.get_pos_offline_catalog_snapshot(uuid)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'open_session_terminal_policy_readiness',
        CASE WHEN count(*) FILTER (WHERE NOT terminal_enabled) = 0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'open_sessions',count(*),
            'sessions_without_terminal_policy',
                count(*) FILTER (WHERE NOT terminal_enabled),
            'sessions_without_cash',
                count(*) FILTER (WHERE NOT has_cash)
        )
    FROM open_session_scope

    UNION ALL

    SELECT
        'open_session_offline_cash_readiness',
        CASE WHEN count(*) FILTER (WHERE NOT has_cash) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'sessions_without_cash',
                count(*) FILTER (WHERE NOT has_cash)
        )
    FROM open_session_scope

    UNION ALL

    SELECT
        'invalid_active_sales_product_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM active_sale_product_uoms
    WHERE factor_to_base <= 0
       OR sale_price IS NULL
       OR sale_price < 0
       OR allow_decimal IS NULL
       OR decimal_precision IS NULL
       OR (NOT is_bundle AND base_uom_id IS NULL)

    UNION ALL

    SELECT
        'offline_product_catalog_inventory',
        'INFO',
        jsonb_build_object(
            'companies',count(DISTINCT company_id),
            'product_uoms',count(*),
            'products',count(DISTINCT (company_id,product_id)),
            'bundle_uoms',count(*) FILTER (WHERE is_bundle),
            'stock_product_uoms',count(*) FILTER (WHERE NOT is_bundle)
        )
    FROM active_sale_product_uoms

    UNION ALL

    SELECT
        'offline_pricing_snapshot_complexity',
        'INFO',
        jsonb_build_object(
            'active_pricelists',(
                SELECT count(*) FROM public.pricelists WHERE is_active
            ),
            'active_pricelist_rules',(
                SELECT count(*) FROM public.pricelist_rules WHERE is_active
            ),
            'customers_with_default_pricelist',(
                SELECT count(*) FROM public.customers
                WHERE is_active AND default_pricelist_id IS NOT NULL
            ),
            'store_assignments',(
                SELECT count(*) FROM public.pricelist_store_assignments
            )
        )

    UNION ALL

    SELECT
        'offline_tax_snapshot_complexity',
        'INFO',
        jsonb_build_object(
            'active_sales_tax_rules',(
                SELECT count(*)
                FROM public.tax_rules tr
                WHERE tr.is_active AND tr.tax_scope = 'SALES'
            ),
            'product_tax_overrides',(
                SELECT count(*) FROM public.products
                WHERE sales_tax_rule_id IS NOT NULL
            ),
            'category_tax_assignments',(
                SELECT count(*) FROM public.product_categories
                WHERE default_sales_tax_rule_id IS NOT NULL
            )
        )

    UNION ALL

    SELECT
        'offline_allowance_inventory',
        'INFO',
        jsonb_build_object(
            'active_allowances',count(*) FILTER (WHERE status = 'ACTIVE'),
            'active_sessions',count(DISTINCT cashier_session_id)
                FILTER (WHERE status = 'ACTIVE'),
            'reserved_remaining_base_qty',COALESCE(sum(
                allocated_base_qty - consumed_base_qty
            ) FILTER (WHERE status = 'ACTIVE'),0)
        )
    FROM public.pos_offline_stock_allowances

    UNION ALL

    SELECT
        'nonterminal_offline_submission',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('submission_count',count(*))
    FROM public.pos_offline_sale_submissions
    WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION','FAILED')

    UNION ALL

    SELECT
        'canonical_offline_sync_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.submit_pos_offline_sale(jsonb)','EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.process_pos_offline_sale_submission(uuid)','EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.get_pos_offline_submission_status(uuid)','EXECUTE'
            )
        THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('expected_rpc_rows',3)

    UNION ALL

    SELECT
        'browser_direct_offline_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.pos_offline_stock_allowances',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
        THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object(
            'allowance_write',has_table_privilege(
                'authenticated','public.pos_offline_stock_allowances',
                'INSERT,UPDATE,DELETE'
            ),
            'submission_write',has_table_privilege(
                'authenticated','public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            ),
            'stock_write',has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
