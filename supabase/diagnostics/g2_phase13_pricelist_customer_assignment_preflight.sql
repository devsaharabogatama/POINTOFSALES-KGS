-- G2 phase 13 forward-fix preflight: reusable Customer Pricelist assignment.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Customer/Pricelist names or business rows.
-- - Does not alter checkout or activate the pricing resolver.

WITH required_versions(version) AS (
    VALUES ('20260722080000')
), customer_pricelist_summary AS (
    SELECT
        p.customer_id,
        count(*) FILTER (WHERE p.is_active) AS active_pricelists,
        count(*) FILTER (
            WHERE p.is_active AND p.is_default
        ) AS active_defaults
    FROM public.pricelists p
    WHERE p.scope = 'CUSTOMER'
    GROUP BY p.customer_id
), checks AS (
    SELECT
        'g2_phase13_default_guard_dependency'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected', count(*),
            'missing', COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'customer_pricelist_assignment_schema_state',
        'INFO',
        jsonb_build_object(
            'customers_default_pricelist_id_exists', EXISTS (
                SELECT 1
                FROM information_schema.columns c
                WHERE c.table_schema = 'public'
                  AND c.table_name = 'customers'
                  AND c.column_name = 'default_pricelist_id'
            ),
            'legacy_pricelist_customer_id_exists', EXISTS (
                SELECT 1
                FROM information_schema.columns c
                WHERE c.table_schema = 'public'
                  AND c.table_name = 'pricelists'
                  AND c.column_name = 'customer_id'
            )
        )

    UNION ALL

    SELECT
        'legacy_customer_pricelist_inventory',
        'INFO',
        jsonb_build_object(
            'customer_pricelists', count(*),
            'active_customer_pricelists', count(*) FILTER (WHERE is_active),
            'active_default_customer_pricelists', count(*) FILTER (
                WHERE is_active AND is_default
            ),
            'customers_referenced', count(DISTINCT customer_id)
        )
    FROM public.pricelists
    WHERE scope = 'CUSTOMER'

    UNION ALL

    SELECT
        'invalid_legacy_customer_pricelist_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM public.pricelists p
    LEFT JOIN public.customers c
      ON c.company_id = p.company_id
     AND c.id = p.customer_id
    WHERE p.scope = 'CUSTOMER'
      AND (
          c.id IS NULL
          OR c.is_system_customer
          OR NOT c.is_active
      )

    UNION ALL

    SELECT
        'customer_with_multiple_active_default_pricelists',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('customer_count', count(*))
    FROM customer_pricelist_summary
    WHERE active_defaults > 1

    UNION ALL

    SELECT
        'active_customer_pricelist_without_default',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('customer_count', count(*))
    FROM customer_pricelist_summary
    WHERE active_pricelists > 0
      AND active_defaults = 0

    UNION ALL

    SELECT
        'customer_default_pricelist_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'customers_to_assign', count(DISTINCT customer_id),
            'legacy_default_rows', count(*)
        )
    FROM public.pricelists
    WHERE scope = 'CUSTOMER'
      AND is_active
      AND is_default

    UNION ALL

    SELECT
        'customer_master_inventory',
        'INFO',
        jsonb_build_object(
            'customers', count(*),
            'active_regular_customers', count(*) FILTER (
                WHERE is_active AND NOT is_system_customer
            ),
            'system_walk_in_customers', count(*) FILTER (
                WHERE is_system_customer
            )
        )
    FROM public.customers

    UNION ALL

    SELECT
        'sales_pricing_snapshot_inventory',
        'INFO',
        jsonb_build_object(
            'sales_headers', (SELECT count(*) FROM public.sales_headers),
            'sales_details', (SELECT count(*) FROM public.sales_details),
            'details_with_pricelist', (
                SELECT count(*)
                FROM public.sales_details
                WHERE pricelist_id IS NOT NULL
            )
        )

    UNION ALL

    SELECT
        'direct_customer_pricelist_write_privilege',
        'INFO',
        jsonb_build_object(
            'customers_update', has_table_privilege(
                'authenticated','public.customers','UPDATE'
            ),
            'pricelists_update', has_table_privilege(
                'authenticated','public.pricelists','UPDATE'
            )
        )
)
SELECT check_name, status, details
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
