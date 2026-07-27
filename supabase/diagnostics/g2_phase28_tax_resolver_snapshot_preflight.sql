-- G2 phase 28 preflight: Tax resolver and transaction snapshot readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP object, side-effect function, or grant.
-- - Returns aggregate counts only; no business names or identifiers.
-- - This audit does not enable Tax calculation, checkout, Purchase posting,
--   journal posting, return/reversal, or official tax reporting.

WITH dependency AS (
    SELECT count(*) AS ledger_rows
    FROM private.kgs_schema_migrations
    WHERE version = '20260723040000'
), tax_scopes(tax_scope,feature_code) AS (
    VALUES
        ('SALES'::TEXT,'tax_sales_enabled'::TEXT),
        ('PURCHASE'::TEXT,'tax_purchase_enabled'::TEXT)
), company_tax_scopes AS (
    SELECT
        c.id AS company_id,
        s.tax_scope,
        COALESCE(cf.is_enabled,FALSE) AS is_enabled
    FROM public.companies c
    CROSS JOIN tax_scopes s
    LEFT JOIN public.company_features cf
      ON cf.company_id = c.id
     AND cf.feature_code = s.feature_code
    WHERE c.status = 'ACTIVE'
), current_version_counts AS (
    SELECT
        v.company_id,
        v.tax_rule_id,
        count(*) AS version_count
    FROM public.tax_rule_versions v
    WHERE v.status = 'ACTIVE'
      AND v.effective_from <= CURRENT_TIMESTAMP
      AND (v.effective_to IS NULL OR v.effective_to > CURRENT_TIMESTAMP)
    GROUP BY v.company_id,v.tax_rule_id
), current_rule_versions AS (
    SELECT
        r.company_id,
        r.id AS tax_rule_id,
        r.tax_scope,
        v.rule_version,
        v.rate_percent,
        v.calculation_scope,
        v.default_price_mode,
        v.account_function_key,
        v.account_id,
        v.is_recoverable
    FROM public.tax_rules r
    JOIN current_version_counts vc
      ON vc.company_id = r.company_id
     AND vc.tax_rule_id = r.id
     AND vc.version_count = 1
    JOIN public.tax_rule_versions v
      ON v.company_id = r.company_id
     AND v.tax_rule_id = r.id
     AND v.status = 'ACTIVE'
     AND v.effective_from <= CURRENT_TIMESTAMP
     AND (v.effective_to IS NULL OR v.effective_to > CURRENT_TIMESTAMP)
    WHERE r.is_active
), product_scope_resolution AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        scope.tax_scope,
        feature.is_enabled,
        scope.product_rule_id,
        scope.category_rule_id,
        COALESCE(scope.product_rule_id,scope.category_rule_id)
            AS resolved_rule_id
    FROM public.products p
    LEFT JOIN public.product_categories pc
      ON pc.company_id = p.company_id
     AND pc.id = p.category_id
    CROSS JOIN LATERAL (
        VALUES
            ('SALES'::TEXT,p.sales_tax_rule_id,pc.default_sales_tax_rule_id),
            ('PURCHASE'::TEXT,p.purchase_tax_rule_id,pc.default_purchase_tax_rule_id)
    ) scope(tax_scope,product_rule_id,category_rule_id)
    JOIN company_tax_scopes feature
      ON feature.company_id = p.company_id
     AND feature.tax_scope = scope.tax_scope
    WHERE p.is_active
), checkout_routines AS (
    SELECT p.oid,pg_get_functiondef(p.oid) AS definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'create_sales_transaction',
          'private_create_sales_transaction_g1_legacy'
      )
), checks AS (
    SELECT
        'g2_phase26_dependency'::TEXT AS check_name,
        CASE WHEN ledger_rows = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('ledger_rows',ledger_rows) AS details
    FROM dependency

    UNION ALL

    SELECT
        'tax_scope_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_company_scopes',count(*),
            'enabled_sales_scopes',count(*) FILTER(
                WHERE tax_scope = 'SALES' AND is_enabled
            ),
            'enabled_purchase_scopes',count(*) FILTER(
                WHERE tax_scope = 'PURCHASE' AND is_enabled
            )
        )
    FROM company_tax_scopes

    UNION ALL

    SELECT
        'current_tax_rule_inventory',
        'INFO',
        jsonb_build_object(
            'current_rules',count(*),
            'sales_rules',count(*) FILTER(WHERE tax_scope = 'SALES'),
            'purchase_rules',count(*) FILTER(WHERE tax_scope = 'PURCHASE'),
            'per_document_rules',count(*) FILTER(
                WHERE calculation_scope = 'PER_DOCUMENT'
            ),
            'per_line_rules',count(*) FILTER(
                WHERE calculation_scope = 'PER_LINE'
            )
        )
    FROM current_rule_versions

    UNION ALL

    SELECT
        'ambiguous_current_tax_rule_version',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rule_count',count(*))
    FROM current_version_counts
    WHERE version_count > 1

    UNION ALL

    SELECT
        'enabled_assignment_without_current_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_scope_count',count(*))
    FROM product_scope_resolution resolved
    LEFT JOIN current_rule_versions rule
      ON rule.company_id = resolved.company_id
     AND rule.tax_rule_id = resolved.resolved_rule_id
     AND rule.tax_scope = resolved.tax_scope
    WHERE resolved.is_enabled
      AND resolved.resolved_rule_id IS NOT NULL
      AND rule.tax_rule_id IS NULL

    UNION ALL

    SELECT
        'enabled_product_without_tax_assignment',
        'INFO',
        jsonb_build_object('product_scope_count',count(*))
    FROM product_scope_resolution
    WHERE is_enabled AND resolved_rule_id IS NULL

    UNION ALL

    SELECT
        'product_tax_resolution_inventory',
        'INFO',
        jsonb_build_object(
            'active_product_scopes',count(*),
            'product_overrides',count(*) FILTER(
                WHERE product_rule_id IS NOT NULL
            ),
            'category_inherited',count(*) FILTER(
                WHERE product_rule_id IS NULL
                  AND category_rule_id IS NOT NULL
            ),
            'no_tax',count(*) FILTER(WHERE resolved_rule_id IS NULL)
        )
    FROM product_scope_resolution

    UNION ALL

    SELECT
        'invalid_current_rule_runtime_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rule_count',count(*))
    FROM current_rule_versions
    WHERE (tax_scope = 'SALES' AND (
              default_price_mode <> 'INCLUSIVE'
              OR account_function_key <> 'OUTPUT_TAX'
          ))
       OR (tax_scope = 'PURCHASE' AND (
              default_price_mode NOT IN ('INCLUSIVE','EXCLUSIVE')
              OR account_function_key <> 'INPUT_TAX'
          ))

    UNION ALL

    SELECT
        'invalid_current_tax_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rule_count',count(*))
    FROM current_rule_versions rule
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id = rule.company_id
     AND account.id = rule.account_id
    WHERE account.id IS NULL
       OR NOT account.is_active
       OR NOT account.is_postable

    UNION ALL

    SELECT
        'incomplete_sales_tax_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_details d
    WHERE (
        d.tax_rule_id IS NULL AND (
            d.tax_rule_version IS NOT NULL
            OR d.tax_code_snapshot IS NOT NULL
            OR d.tax_amount IS NOT NULL
            OR d.tax_account_id IS NOT NULL
        )
    ) OR (
        d.tax_rule_id IS NOT NULL AND (
            d.tax_rule_version IS NULL
            OR d.tax_code_snapshot IS NULL
            OR d.tax_name_snapshot IS NULL
            OR d.tax_scope_snapshot <> 'SALES'
            OR d.tax_rate_percent_snapshot IS NULL
            OR d.tax_price_mode_snapshot <> 'INCLUSIVE'
            OR d.tax_calculation_scope_snapshot IS NULL
            OR d.tax_base IS NULL
            OR d.tax_amount IS NULL
            OR d.tax_rounding IS NULL
            OR d.tax_account_id IS NULL
            OR d.tax_account_code_snapshot IS NULL
            OR d.tax_account_name_snapshot IS NULL
        )
    )

    UNION ALL

    SELECT
        'incomplete_purchase_tax_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.purchases_details d
    WHERE (
        d.tax_rule_id IS NULL AND (
            d.tax_rule_version IS NOT NULL
            OR d.tax_code_snapshot IS NOT NULL
            OR d.tax_amount IS NOT NULL
            OR d.tax_account_id IS NOT NULL
        )
    ) OR (
        d.tax_rule_id IS NOT NULL AND (
            d.tax_rule_version IS NULL
            OR d.tax_code_snapshot IS NULL
            OR d.tax_name_snapshot IS NULL
            OR d.tax_scope_snapshot <> 'PURCHASE'
            OR d.tax_rate_percent_snapshot IS NULL
            OR d.tax_price_mode_snapshot NOT IN ('INCLUSIVE','EXCLUSIVE')
            OR d.tax_calculation_scope_snapshot IS NULL
            OR d.tax_base IS NULL
            OR d.tax_amount IS NULL
            OR d.tax_rounding IS NULL
            OR d.tax_account_id IS NULL
            OR d.tax_account_code_snapshot IS NULL
            OR d.tax_account_name_snapshot IS NULL
        )
    )

    UNION ALL

    SELECT
        'transaction_tax_snapshot_inventory',
        'INFO',
        jsonb_build_object(
            'sales_detail_rows',(SELECT count(*) FROM public.sales_details),
            'sales_tax_rows',(
                SELECT count(*) FROM public.sales_details
                WHERE tax_rule_id IS NOT NULL
            ),
            'purchase_detail_rows',(
                SELECT count(*) FROM public.purchases_details
            ),
            'purchase_tax_rows',(
                SELECT count(*) FROM public.purchases_details
                WHERE tax_rule_id IS NOT NULL
            )
        )

    UNION ALL

    SELECT
        'legacy_checkout_tax_integration_state',
        'INFO',
        jsonb_build_object(
            'routine_rows',count(*),
            'routines_referencing_tax_snapshot',count(*) FILTER(
                WHERE definition ~* 'tax_(rule|amount|base|rounding)'
            )
        )
    FROM checkout_routines

    UNION ALL

    SELECT
        'direct_transaction_tax_write_privilege',
        'INFO',
        jsonb_build_object(
            'sales_details_update',has_table_privilege(
                'authenticated','public.sales_details','UPDATE'
            ),
            'purchase_details_update',has_table_privilege(
                'authenticated','public.purchases_details','UPDATE'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'PASS' THEN 3
        ELSE 4
    END,
    check_name;
