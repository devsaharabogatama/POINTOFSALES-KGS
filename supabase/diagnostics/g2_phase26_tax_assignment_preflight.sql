-- G2 phase 26 preflight: Product Category/Product Tax assignment readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP object, side-effect function, or grant.
-- - Returns aggregate counts only; no business names or identifiers.

WITH dependency AS (
    SELECT count(*) AS ledger_rows
    FROM private.kgs_schema_migrations
    WHERE version = '20260723010000'
), active_companies AS (
    SELECT id AS company_id
    FROM public.companies
    WHERE status = 'ACTIVE'
), tax_scopes(tax_scope,feature_code) AS (
    VALUES
        ('SALES'::TEXT,'tax_sales_enabled'::TEXT),
        ('PURCHASE'::TEXT,'tax_purchase_enabled'::TEXT)
), company_tax_scopes AS (
    SELECT
        c.company_id,
        s.tax_scope,
        s.feature_code,
        COALESCE(cf.is_enabled,FALSE) AS is_enabled
    FROM active_companies c
    CROSS JOIN tax_scopes s
    LEFT JOIN public.company_features cf
      ON cf.company_id = c.company_id
     AND cf.feature_code = s.feature_code
), eligible_versions AS (
    SELECT
        v.company_id,
        v.tax_rule_id,
        count(*) AS eligible_versions
    FROM public.tax_rule_versions v
    WHERE v.status = 'ACTIVE'
      AND v.effective_from <= CURRENT_TIMESTAMP
      AND (v.effective_to IS NULL OR v.effective_to > CURRENT_TIMESTAMP)
    GROUP BY v.company_id,v.tax_rule_id
), active_rules AS (
    SELECT
        r.company_id,
        r.id,
        r.tax_scope,
        COALESCE(v.eligible_versions,0) AS eligible_versions
    FROM public.tax_rules r
    LEFT JOIN eligible_versions v
      ON v.company_id = r.company_id
     AND v.tax_rule_id = r.id
    WHERE r.is_active
), category_assignments AS (
    SELECT
        pc.company_id,
        pc.id AS category_id,
        assignment.tax_scope,
        assignment.tax_rule_id
    FROM public.product_categories pc
    CROSS JOIN LATERAL (
        VALUES
            ('SALES'::TEXT,pc.default_sales_tax_rule_id),
            ('PURCHASE'::TEXT,pc.default_purchase_tax_rule_id)
    ) assignment(tax_scope,tax_rule_id)
    WHERE assignment.tax_rule_id IS NOT NULL
), product_assignments AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        p.category_id,
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
        'g2_phase22_dependency'::TEXT AS check_name,
        CASE WHEN ledger_rows = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('ledger_rows',ledger_rows) AS details
    FROM dependency

    UNION ALL

    SELECT
        'tax_entitlement_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',count(DISTINCT company_id),
            'sales_enabled_companies',count(*) FILTER(
                WHERE tax_scope = 'SALES' AND is_enabled
            ),
            'purchase_enabled_companies',count(*) FILTER(
                WHERE tax_scope = 'PURCHASE' AND is_enabled
            )
        )
    FROM company_tax_scopes

    UNION ALL

    SELECT
        'tax_rule_inventory',
        'INFO',
        jsonb_build_object(
            'rules',(SELECT count(*) FROM public.tax_rules),
            'active_rules',count(*),
            'active_sales_rules',count(*) FILTER(WHERE tax_scope = 'SALES'),
            'active_purchase_rules',count(*) FILTER(WHERE tax_scope = 'PURCHASE'),
            'rules_with_current_version',count(*) FILTER(WHERE eligible_versions = 1)
        )
    FROM active_rules

    UNION ALL

    SELECT
        'active_rule_without_current_version',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('rule_count',count(*))
    FROM active_rules
    WHERE eligible_versions = 0

    UNION ALL

    SELECT
        'multiple_current_versions_per_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rule_count',count(*))
    FROM active_rules
    WHERE eligible_versions > 1

    UNION ALL

    SELECT
        'enabled_scope_without_eligible_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('company_scope_count',count(*))
    FROM company_tax_scopes scope
    WHERE scope.is_enabled
      AND NOT EXISTS (
          SELECT 1
          FROM active_rules r
          WHERE r.company_id = scope.company_id
            AND r.tax_scope = scope.tax_scope
            AND r.eligible_versions = 1
      )

    UNION ALL

    SELECT
        'tax_assignment_inventory',
        'INFO',
        jsonb_build_object(
            'categories',(SELECT count(*) FROM public.product_categories),
            'products',(SELECT count(*) FROM public.products),
            'category_assignment_rows',(SELECT count(*) FROM category_assignments),
            'product_override_rows',(SELECT count(*) FROM product_assignments)
        )

    UNION ALL

    SELECT
        'invalid_existing_category_tax_assignment',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM category_assignments a
    LEFT JOIN active_rules r
      ON r.company_id = a.company_id
     AND r.id = a.tax_rule_id
     AND r.tax_scope = a.tax_scope
     AND r.eligible_versions = 1
    WHERE r.id IS NULL

    UNION ALL

    SELECT
        'invalid_existing_product_tax_assignment',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM product_assignments a
    LEFT JOIN active_rules r
      ON r.company_id = a.company_id
     AND r.id = a.tax_rule_id
     AND r.tax_scope = a.tax_scope
     AND r.eligible_versions = 1
    WHERE r.id IS NULL

    UNION ALL

    SELECT
        'assignment_in_disabled_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT company_id,tax_scope FROM category_assignments
        UNION ALL
        SELECT company_id,tax_scope FROM product_assignments
    ) assignment
    JOIN company_tax_scopes scope
      ON scope.company_id = assignment.company_id
     AND scope.tax_scope = assignment.tax_scope
    WHERE NOT scope.is_enabled

    UNION ALL

    SELECT
        'redundant_product_tax_override',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM product_assignments p
    JOIN category_assignments c
      ON c.company_id = p.company_id
     AND c.category_id = p.category_id
     AND c.tax_scope = p.tax_scope
     AND c.tax_rule_id = p.tax_rule_id

    UNION ALL

    SELECT
        'direct_tax_master_write_privilege',
        'INFO',
        jsonb_build_object(
            'product_category_update',has_table_privilege(
                'authenticated','public.product_categories','UPDATE'
            ),
            'product_update',has_table_privilege(
                'authenticated','public.products','UPDATE'
            )
        )

    UNION ALL

    SELECT
        'guarded_tax_assignment_rpc_state',
        'INFO',
        jsonb_build_object(
            'category_assignment_rpc_exists',
                to_regprocedure(
                    'public.save_product_category_tax_assignment(uuid,bigint,uuid,uuid)'
                ) IS NOT NULL,
            'product_assignment_rpc_exists',
                to_regprocedure(
                    'public.save_product_tax_assignment(uuid,bigint,uuid,uuid)'
                ) IS NOT NULL
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
