-- G3 phase 12 preflight: canonical Bundle composition and stock expansion readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Product/business names.
--
-- BOUNDARY:
-- - Audits Bundle master/composition and stock-ledger readiness only.
-- - Does not enable POS checkout, sales posting, allocation, Return, or Import.

WITH required_versions(version) AS (
    VALUES ('20260721210000'), ('20260728230000')
), expected_component_columns(column_name) AS (
    VALUES
        ('company_id'), ('bundle_id'), ('item_id'),
        ('component_uom_id'), ('component_qty'), ('line_no'),
        ('master_version'), ('created_by'), ('updated_by'),
        ('created_at'), ('updated_at')
), bundle_inventory AS (
    SELECT
        p.company_id,
        p.id AS bundle_id,
        p.is_active,
        count(bi.id) AS component_rows
    FROM public.products p
    LEFT JOIN public.product_bundle_items bi
      ON bi.company_id = p.company_id
     AND bi.bundle_id = p.id
    WHERE p.is_bundle
    GROUP BY p.company_id, p.id, p.is_active
), component_integrity AS (
    SELECT
        bi.id,
        bi.company_id,
        bi.bundle_id,
        bi.item_id,
        bi.qty,
        bundle.id AS bundle_found,
        bundle.is_bundle AS header_is_bundle,
        item.id AS item_found,
        item.is_bundle AS item_is_bundle,
        item.is_active AS item_is_active,
        item.uom_id AS item_base_uom_id
    FROM public.product_bundle_items bi
    LEFT JOIN public.products bundle
      ON bundle.company_id = bi.company_id
     AND bundle.id = bi.bundle_id
    LEFT JOIN public.products item
      ON item.company_id = bi.company_id
     AND item.id = bi.item_id
), checks AS (
    SELECT
        'g3_bundle_dependencies'::text AS check_name,
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
        'bundle_inventory',
        'INFO',
        jsonb_build_object(
            'bundle_products', count(*),
            'active_bundle_products', count(*) FILTER (WHERE is_active),
            'bundles_with_components', count(*) FILTER (
                WHERE component_rows > 0
            ),
            'component_rows', COALESCE(sum(component_rows), 0)
        )
    FROM bundle_inventory

    UNION ALL

    SELECT
        'active_bundle_without_component',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('bundle_count', count(*))
    FROM bundle_inventory
    WHERE is_active AND component_rows = 0

    UNION ALL

    SELECT
        'invalid_bundle_component_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM component_integrity
    WHERE bundle_found IS NULL
       OR item_found IS NULL
       OR header_is_bundle IS DISTINCT FROM TRUE
       OR item_is_active IS DISTINCT FROM TRUE

    UNION ALL

    SELECT
        'nested_or_self_bundle_component',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM component_integrity
    WHERE bundle_id = item_id
       OR item_is_bundle IS TRUE

    UNION ALL

    SELECT
        'invalid_bundle_component_quantity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM component_integrity
    WHERE qty IS NULL OR qty <= 0

    UNION ALL

    SELECT
        'duplicate_bundle_component',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups', count(*))
    FROM (
        SELECT company_id, bundle_id, item_id
        FROM public.product_bundle_items
        GROUP BY company_id, bundle_id, item_id
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'component_without_canonical_base_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('component_count', count(*))
    FROM (
        SELECT DISTINCT c.company_id, c.item_id
        FROM component_integrity c
        LEFT JOIN public.product_uoms pu
          ON pu.company_id = c.company_id
         AND pu.product_id = c.item_id
         AND pu.uom_id = c.item_base_uom_id
         AND pu.factor_to_base = 1
         AND pu.is_active
        WHERE c.item_found IS NOT NULL
          AND (
              c.item_base_uom_id IS NULL
              OR pu.id IS NULL
          )
    ) invalid_components

    UNION ALL

    SELECT
        'active_bundle_without_sales_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('bundle_count', count(*))
    FROM bundle_inventory b
    WHERE b.is_active
      AND NOT EXISTS (
          SELECT 1
          FROM public.product_uoms pu
          WHERE pu.company_id = b.company_id
            AND pu.product_id = b.bundle_id
            AND pu.is_active
            AND pu.sales_allowed
      )

    UNION ALL

    SELECT
        'bundle_with_purchase_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM public.product_uoms pu
    JOIN public.products p
      ON p.company_id = pu.company_id
     AND p.id = pu.product_id
    WHERE p.is_bundle
      AND pu.is_active
      AND pu.purchase_allowed

    UNION ALL

    SELECT
        'bundle_with_physical_stock_or_fifo',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'stock_rows', count(*) FILTER (WHERE source_type = 'STOCK'),
            'movement_rows', count(*) FILTER (WHERE source_type = 'MOVEMENT'),
            'fifo_rows', count(*) FILTER (WHERE source_type = 'FIFO')
        )
    FROM (
        SELECT 'STOCK'::text AS source_type
        FROM public.product_stocks ps
        JOIN public.products p
          ON p.company_id = ps.company_id
         AND p.id = ps.product_id
        WHERE p.is_bundle

        UNION ALL

        SELECT 'MOVEMENT'
        FROM public.stock_movements sm
        JOIN public.products p
          ON p.company_id = sm.company_id
         AND p.id = sm.product_id
        WHERE p.is_bundle

        UNION ALL

        SELECT 'FIFO'
        FROM public.product_batches fb
        JOIN public.products p
          ON p.company_id = fb.company_id
         AND p.id = fb.product_id
        WHERE p.is_bundle
    ) physical_rows

    UNION ALL

    SELECT
        'legacy_component_uom_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'component_rows_to_assign_base_uom', count(*)
        )
    FROM public.product_bundle_items

    UNION ALL

    SELECT
        'canonical_bundle_schema_state',
        'INFO',
        jsonb_build_object(
            'component_table_exists',
                to_regclass('public.product_bundle_items') IS NOT NULL,
            'bundle_audit_table_exists',
                to_regclass('public.product_bundle_master_audit') IS NOT NULL,
            'missing_component_columns', COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_component_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'product_bundle_items'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'guarded_bundle_rpc_state',
        'INFO',
        jsonb_build_object(
            'save_product_rpc_exists',
                to_regprocedure(
                    'public.save_product_with_uoms(uuid,bigint,text,text,uuid,uuid,uuid,numeric,boolean,text,boolean,jsonb)'
                ) IS NOT NULL,
            'save_bundle_rpc_exists',
                to_regprocedure(
                    'public.save_bundle_with_components(uuid,bigint,text,text,uuid,uuid,numeric,text,text,boolean,jsonb)'
                ) IS NOT NULL,
            'availability_rpc_exists',
                to_regprocedure(
                    'public.get_bundle_availability(uuid,uuid)'
                ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'direct_bundle_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert', has_table_privilege(
                'authenticated','public.product_bundle_items','INSERT'
            ),
            'authenticated_update', has_table_privilege(
                'authenticated','public.product_bundle_items','UPDATE'
            ),
            'authenticated_delete', has_table_privilege(
                'authenticated','public.product_bundle_items','DELETE'
            )
        )

    UNION ALL

    SELECT
        'bundle_warehouse_capacity_scope',
        'INFO',
        jsonb_build_object(
            'active_bundles', (
                SELECT count(*) FROM bundle_inventory WHERE is_active
            ),
            'active_sale_source_warehouses', count(*),
            'companies', count(DISTINCT company_id)
        )
    FROM public.warehouses
    WHERE is_active AND is_sale_source

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'job_count', count(*),
            'companies', count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status IN ('UPLOADED','MAPPED','VALIDATED')
)
SELECT check_name, status, details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'BACKFILL' THEN 2
        WHEN 'REVIEW' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
