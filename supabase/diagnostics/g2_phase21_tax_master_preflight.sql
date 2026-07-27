-- G2 phase 21 preflight: canonical Sales/Purchase Tax master readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, side-effect function, or grants.
-- - Returns aggregate counts/schema names only; no tax identity or business row.
-- - Does not enable entitlement, calculate tax, alter checkout, or post journal.

WITH required_versions(version) AS (
    VALUES ('20260722230000')
), required_features(feature_code) AS (
    VALUES ('tax_sales_enabled'),('tax_purchase_enabled')
), required_account_functions(function_key,account_type,normal_balance) AS (
    VALUES
        ('OUTPUT_TAX','LIABILITY','CREDIT'),
        ('INPUT_TAX','ASSET','DEBIT')
), expected_tax_tables(table_name) AS (
    VALUES ('tax_rules'),('tax_master_audit')
), expected_assignment_columns(table_name,column_name) AS (
    VALUES
        ('product_categories','default_sales_tax_rule_id'),
        ('product_categories','default_purchase_tax_rule_id'),
        ('products','sales_tax_rule_id'),
        ('products','purchase_tax_rule_id')
), expected_sales_snapshot_columns(column_name) AS (
    VALUES
        ('tax_rule_id'),('tax_rule_version'),('tax_code_snapshot'),
        ('tax_name_snapshot'),('tax_rate_percent_snapshot'),
        ('tax_price_mode_snapshot'),('tax_calculation_scope_snapshot'),
        ('tax_base'),('tax_amount'),('tax_rounding')
), expected_purchase_snapshot_columns(column_name) AS (
    VALUES
        ('tax_rule_id'),('tax_rule_version'),('tax_code_snapshot'),
        ('tax_name_snapshot'),('tax_rate_percent_snapshot'),
        ('tax_price_mode_snapshot'),('tax_calculation_scope_snapshot'),
        ('tax_is_recoverable_snapshot'),('tax_base'),('tax_amount'),
        ('tax_rounding')
), active_tax_entitlements AS (
    SELECT
        c.id AS company_id,
        f.feature_code
    FROM public.companies c
    CROSS JOIN required_features f
    JOIN public.company_features cf
      ON cf.company_id = c.id
     AND cf.feature_code = f.feature_code
     AND cf.is_enabled
    WHERE c.status = 'ACTIVE'
), checks AS (
    SELECT
        'g2_phase20_dependency'::TEXT AS check_name,
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
        'tax_feature_catalog',
        CASE WHEN count(pf.feature_code) = 2
                  AND count(pf.feature_code) FILTER (WHERE pf.is_active) = 2
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',2,
            'active_rows',count(pf.feature_code) FILTER (WHERE pf.is_active),
            'missing',COALESCE(
                jsonb_agg(r.feature_code ORDER BY r.feature_code)
                    FILTER (WHERE pf.feature_code IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_features r
    LEFT JOIN public.platform_features pf
      ON pf.feature_code = r.feature_code

    UNION ALL

    SELECT
        'active_company_tax_entitlement_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'sales_tax_enabled_companies',count(DISTINCT company_id)
                FILTER (WHERE feature_code = 'tax_sales_enabled'),
            'purchase_tax_enabled_companies',count(DISTINCT company_id)
                FILTER (WHERE feature_code = 'tax_purchase_enabled')
        )
    FROM active_tax_entitlements

    UNION ALL

    SELECT
        'enabled_tax_entitlement_without_compatible_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_feature_count',count(*))
    FROM active_tax_entitlements e
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.chart_of_accounts coa
        WHERE coa.company_id = e.company_id
          AND coa.system_function_key = CASE e.feature_code
              WHEN 'tax_sales_enabled' THEN 'OUTPUT_TAX'
              ELSE 'INPUT_TAX'
          END
          AND coa.is_active
          AND coa.is_postable
    )

    UNION ALL

    SELECT
        'tax_account_function_registry',
        CASE WHEN count(af.function_key) = 2
                  AND count(af.function_key) FILTER (WHERE af.is_active) = 2
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_rows',count(af.function_key) FILTER (WHERE af.is_active),
            'missing',COALESCE(
                jsonb_agg(r.function_key ORDER BY r.function_key)
                    FILTER (WHERE af.function_key IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_account_functions r
    LEFT JOIN public.account_functions af
      ON af.function_key = r.function_key
     AND r.account_type = ANY(af.compatible_account_types)

    UNION ALL

    SELECT
        'invalid_tax_system_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.chart_of_accounts coa
    JOIN required_account_functions r
      ON r.function_key = coa.system_function_key
    WHERE coa.account_type <> r.account_type
       OR coa.normal_balance <> r.normal_balance
       OR NOT coa.is_postable

    UNION ALL

    SELECT
        'duplicate_company_tax_system_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,system_function_key
        FROM public.chart_of_accounts
        WHERE system_function_key IN ('INPUT_TAX','OUTPUT_TAX')
          AND is_active
        GROUP BY company_id,system_function_key
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'canonical_tax_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE c.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_tax_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')

    UNION ALL

    SELECT
        'tax_assignment_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(
                    e.table_name || '.' || e.column_name
                    ORDER BY e.table_name,e.column_name
                ) FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_assignment_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'sales_tax_snapshot_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_sales_snapshot_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_details'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'purchase_tax_snapshot_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_purchase_snapshot_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'purchases_details'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'legacy_company_tax_identity_inventory',
        'INFO',
        jsonb_build_object(
            'companies',count(*),
            'companies_with_tax_id',count(*) FILTER (
                WHERE NULLIF(btrim(tax_id),'') IS NOT NULL
            )
        )
    FROM public.companies

    UNION ALL

    SELECT
        'tax_assignment_backfill_inventory',
        'INFO',
        jsonb_build_object(
            'product_categories',(SELECT count(*) FROM public.product_categories),
            'active_product_categories',(
                SELECT count(*) FROM public.product_categories WHERE is_active
            ),
            'products',(SELECT count(*) FROM public.products),
            'active_products',(SELECT count(*) FROM public.products WHERE is_active)
        )

    UNION ALL

    SELECT
        'negative_legacy_sales_total',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_headers
    WHERE subtotal < 0 OR grand_total < 0

    UNION ALL

    SELECT
        'negative_legacy_purchase_total',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM public.purchases_headers
    WHERE subtotal < 0 OR grand_total < 0

    UNION ALL

    SELECT
        'transaction_history_inventory',
        'INFO',
        jsonb_build_object(
            'sales_headers',(SELECT count(*) FROM public.sales_headers),
            'sales_details',(SELECT count(*) FROM public.sales_details),
            'purchase_headers',(SELECT count(*) FROM public.purchases_headers),
            'purchase_details',(SELECT count(*) FROM public.purchases_details)
        )

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
        WHEN 'BACKFILL' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;

