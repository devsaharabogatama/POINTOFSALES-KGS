-- G5 phase 1 preflight: Stock Request -> Supplier Order -> Goods Receipt
-- purchasing foundation readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Supplier/Product/business names.

WITH required_versions(version) AS (
    VALUES
        ('20260721230000'), -- Supplier + Product-Supplier
        ('20260729010000'), -- G3 inventory/Bundle chain closure
        ('20260805234500')  -- G4 negative-stock/Offline responsibility closure
), expected_request_order_tables(table_name) AS (
    VALUES
        ('stock_request_documents'),
        ('stock_request_lines'),
        ('supplier_order_documents'),
        ('supplier_order_lines'),
        ('supplier_order_request_allocations')
), expected_request_order_routines(routine_name) AS (
    VALUES
        ('save_stock_request'),
        ('submit_stock_request'),
        ('save_supplier_order'),
        ('confirm_supplier_order')
), normalized_legacy_purchase AS (
    SELECT
        ph.id,
        ph.company_id,
        ph.store_id,
        ph.warehouse_id,
        ph.purchase_no,
        ph.supplier_name,
        ph.subtotal,
        ph.grand_total,
        ph.paid_amount,
        lower(regexp_replace(btrim(ph.supplier_name), '\s+', ' ', 'g'))
            AS normalized_supplier_name
    FROM public.purchases_headers ph
), product_purchase_readiness AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        count(pu.id) FILTER (
            WHERE pu.is_active
              AND pu.purchase_allowed
              AND u.is_active
        ) AS active_purchase_uoms,
        count(ps.id) FILTER (
            WHERE ps.is_active AND supplier.is_active
        ) AS active_supplier_relations
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
    LEFT JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
    LEFT JOIN public.product_suppliers ps
      ON ps.company_id = p.company_id
     AND ps.product_id = p.id
    LEFT JOIN public.suppliers supplier
      ON supplier.company_id = ps.company_id
     AND supplier.id = ps.supplier_id
    WHERE p.is_active AND NOT p.is_bundle
    GROUP BY p.company_id, p.id
), company_purchase_readiness AS (
    SELECT
        company.id AS company_id,
        EXISTS (
            SELECT 1 FROM public.stores store
            WHERE store.company_id = company.id
              AND store.status = 'ACTIVE'
        ) AS has_active_store,
        EXISTS (
            SELECT 1 FROM public.warehouses warehouse
            WHERE warehouse.company_id = company.id
              AND warehouse.is_active
        ) AS has_active_warehouse,
        EXISTS (
            SELECT 1 FROM public.suppliers supplier
            WHERE supplier.company_id = company.id
              AND supplier.is_active
        ) AS has_active_supplier,
        EXISTS (
            SELECT 1 FROM public.transaction_categories category
            WHERE category.company_id = company.id
              AND category.system_key = 'GOODS_RECEIPT'
              AND category.is_active
        ) AS has_goods_receipt_category
    FROM public.companies company
    WHERE company.status = 'ACTIVE'
), legacy_routines AS (
    SELECT
        p.oid,
        p.proname,
        has_function_privilege('authenticated', p.oid, 'EXECUTE')
            AS authenticated_execute,
        lower(pg_get_functiondef(p.oid)) AS definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'confirm_purchase_order'
), checks AS (
    SELECT
        'g5_phase1_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected', count(*),
            'missing', COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = required.version

    UNION ALL

    SELECT
        'canonical_request_order_schema_state',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || expected.table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_tables', COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER (
                        WHERE to_regclass(
                            'public.' || expected.table_name
                        ) IS NULL
                    ),
                '[]'::jsonb
            ),
            'expected_tables', count(*)
        )
    FROM expected_request_order_tables expected

    UNION ALL

    SELECT
        'canonical_request_order_routine_state',
        CASE WHEN count(*) FILTER (WHERE routine.proname IS NULL) = 0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_routines', COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER (WHERE routine.proname IS NULL),
                '[]'::jsonb
            ),
            'expected_routines', count(*)
        )
    FROM expected_request_order_routines expected
    LEFT JOIN (
        SELECT DISTINCT p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
    ) routine ON routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'legacy_purchase_inventory',
        'INFO',
        jsonb_build_object(
            'purchase_documents', count(*),
            'companies', count(DISTINCT company_id),
            'supplier_name_groups', count(DISTINCT (
                company_id, normalized_supplier_name
            )),
            'purchase_lines', (SELECT count(*) FROM public.purchases_details),
            'paid_documents', count(*) FILTER (WHERE paid_amount > 0)
        )
    FROM normalized_legacy_purchase

    UNION ALL

    SELECT
        'blank_legacy_purchase_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM normalized_legacy_purchase
    WHERE btrim(purchase_no) = '' OR normalized_supplier_name = ''

    UNION ALL

    SELECT
        'invalid_legacy_purchase_value',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count', count(*))
    FROM (
        SELECT id
        FROM normalized_legacy_purchase
        WHERE subtotal < 0 OR grand_total < 0 OR paid_amount < 0
           OR paid_amount > grand_total
        UNION ALL
        SELECT detail.id
        FROM public.purchases_details detail
        WHERE detail.qty <= 0
           OR detail.purchase_price < 0
           OR detail.subtotal < 0
    ) invalid_value

    UNION ALL

    SELECT
        'legacy_purchase_line_subtotal_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count', count(*))
    FROM public.purchases_details detail
    WHERE abs(detail.subtotal - (detail.qty * detail.purchase_price)) > 0.0001

    UNION ALL

    SELECT
        'legacy_purchase_header_total_mismatch',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('document_count', count(*))
    FROM normalized_legacy_purchase purchase
    LEFT JOIN (
        SELECT purchase_id, sum(subtotal) AS line_subtotal
        FROM public.purchases_details
        GROUP BY purchase_id
    ) detail ON detail.purchase_id = purchase.id
    WHERE abs(purchase.subtotal - COALESCE(detail.line_subtotal, 0)) > 0.0001
       OR purchase.grand_total < purchase.subtotal

    UNION ALL

    SELECT
        'legacy_purchase_tenant_reference_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_or_cross_tenant_rows', count(*))
    FROM (
        SELECT purchase.id
        FROM normalized_legacy_purchase purchase
        LEFT JOIN public.companies company
          ON company.id = purchase.company_id
        LEFT JOIN public.stores store
          ON store.id = purchase.store_id
         AND store.company_id = purchase.company_id
        LEFT JOIN public.warehouses warehouse
          ON warehouse.id = purchase.warehouse_id
         AND warehouse.company_id = purchase.company_id
        WHERE company.id IS NULL OR store.id IS NULL OR warehouse.id IS NULL
        UNION ALL
        SELECT detail.id
        FROM public.purchases_details detail
        LEFT JOIN public.purchases_headers purchase
          ON purchase.id = detail.purchase_id
         AND purchase.company_id = detail.company_id
        LEFT JOIN public.products product
          ON product.id = detail.product_id
         AND product.company_id = detail.company_id
        WHERE purchase.id IS NULL OR product.id IS NULL
    ) invalid_reference

    UNION ALL

    SELECT
        'legacy_supplier_canonical_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('supplier_groups_to_map', count(*))
    FROM (
        SELECT purchase.company_id, purchase.normalized_supplier_name
        FROM normalized_legacy_purchase purchase
        LEFT JOIN public.suppliers supplier
          ON supplier.company_id = purchase.company_id
         AND lower(regexp_replace(
             btrim(supplier.supplier_name), '\s+', ' ', 'g'
         )) = purchase.normalized_supplier_name
        WHERE supplier.id IS NULL
        GROUP BY purchase.company_id, purchase.normalized_supplier_name
    ) unmapped_supplier

    UNION ALL

    SELECT
        'legacy_purchase_fifo_or_movement_history',
        CASE WHEN (
            (SELECT count(*) FROM public.product_batches
             WHERE purchase_detail_id IS NOT NULL) = 0
            AND
            (SELECT count(*) FROM public.stock_movements
             WHERE reference_table = 'purchases_details') = 0
        ) THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'fifo_batches', (
                SELECT count(*) FROM public.product_batches
                WHERE purchase_detail_id IS NOT NULL
            ),
            'movement_rows', (
                SELECT count(*) FROM public.stock_movements
                WHERE reference_table = 'purchases_details'
            )
        )

    UNION ALL

    SELECT
        'active_stock_product_without_purchase_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count', count(*))
    FROM product_purchase_readiness
    WHERE active_purchase_uoms = 0

    UNION ALL

    SELECT
        'active_stock_product_without_supplier_relation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('product_count', count(*))
    FROM product_purchase_readiness
    WHERE active_purchase_uoms > 0 AND active_supplier_relations = 0

    UNION ALL

    SELECT
        'active_company_purchase_operational_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'company_count', count(*),
            'without_store', count(*) FILTER (WHERE NOT has_active_store),
            'without_warehouse', count(*) FILTER (WHERE NOT has_active_warehouse),
            'without_supplier', count(*) FILTER (WHERE NOT has_active_supplier)
        )
    FROM company_purchase_readiness
    WHERE NOT has_active_store
       OR NOT has_active_warehouse
       OR NOT has_active_supplier

    UNION ALL

    SELECT
        'active_company_goods_receipt_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count', count(*))
    FROM company_purchase_readiness
    WHERE NOT has_goods_receipt_category

    UNION ALL

    SELECT
        'open_negative_stock_replenishment_scope',
        'INFO',
        jsonb_build_object(
            'allocation_rows', count(*),
            'products', count(DISTINCT stock_product_id),
            'warehouses', count(DISTINCT warehouse_id),
            'remaining_base_qty', COALESCE(sum(
                shortage_base_qty - replenished_base_qty
            ), 0)
        )
    FROM public.negative_stock_sale_allocations
    WHERE reconciled_at IS NULL

    UNION ALL

    SELECT
        'legacy_confirm_purchase_browser_execution',
        CASE WHEN count(*) FILTER (WHERE authenticated_execute) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'routine_rows', count(*),
            'authenticated_executable_rows', count(*) FILTER (
                WHERE authenticated_execute
            )
        )
    FROM legacy_routines

    UNION ALL

    SELECT
        'legacy_confirm_purchase_unsafe_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'routine_rows', count(*),
            'direct_stock_writer_rows', count(*) FILTER (
                WHERE definition LIKE '%insert into product_stocks%'
                   OR definition LIKE '%insert into public.product_stocks%'
            ),
            'direct_fifo_writer_rows', count(*) FILTER (
                WHERE definition LIKE '%insert into product_batches%'
                   OR definition LIKE '%insert into public.product_batches%'
            )
        )
    FROM legacy_routines

    UNION ALL

    SELECT
        'browser_direct_purchase_stock_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated', 'public.purchases_headers',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated', 'public.purchases_details',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated', 'public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated', 'public.product_batches',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated', 'public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
        THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object(
            'purchase_header_write', has_table_privilege(
                'authenticated', 'public.purchases_headers',
                'INSERT,UPDATE,DELETE'
            ),
            'purchase_line_write', has_table_privilege(
                'authenticated', 'public.purchases_details',
                'INSERT,UPDATE,DELETE'
            ),
            'stock_write', has_table_privilege(
                'authenticated', 'public.product_stocks',
                'INSERT,UPDATE,DELETE'
            ),
            'fifo_write', has_table_privilege(
                'authenticated', 'public.product_batches',
                'INSERT,UPDATE,DELETE'
            ),
            'movement_write', has_table_privilege(
                'authenticated', 'public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'purchase_master_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies', (
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'active_stores', (
                SELECT count(*) FROM public.stores WHERE status = 'ACTIVE'
            ),
            'active_warehouses', (
                SELECT count(*) FROM public.warehouses WHERE is_active
            ),
            'active_suppliers', (
                SELECT count(*) FROM public.suppliers WHERE is_active
            ),
            'active_stock_products', (
                SELECT count(*) FROM public.products
                WHERE is_active AND NOT is_bundle
            ),
            'active_purchase_product_uoms', (
                SELECT count(*) FROM public.product_uoms
                WHERE is_active AND purchase_allowed
            ),
            'active_product_supplier_relations', (
                SELECT count(*) FROM public.product_suppliers WHERE is_active
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
        WHEN 'SETUP' THEN 5
        ELSE 6
    END,
    check_name;
