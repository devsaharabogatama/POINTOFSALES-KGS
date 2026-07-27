-- G2 phase 29 preflight: canonical master import/export framework readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP object, side-effect function, or grant.
-- - Returns aggregate counts/booleans only; no business names or identifiers.
-- - Opening Stock eligibility is inventoried only. This file never changes
--   stock, movement, FIFO, Product, or any master row.

WITH dependency AS (
    SELECT count(*) AS ledger_rows
    FROM private.kgs_schema_migrations
    WHERE version = '20260723070000'
), expected_import_tables(table_name) AS (
    VALUES
        ('master_import_jobs'),
        ('master_import_rows'),
        ('master_import_job_events')
), legacy_import_routines AS (
    SELECT
        signature,
        to_regprocedure(signature) AS oid
    FROM (VALUES
        ('public.import_products_for_company(uuid,jsonb)'::TEXT),
        ('public.private_import_products_for_company_g1_legacy(uuid,jsonb)'::TEXT)
    ) required(signature)
), legacy_import_definitions AS (
    SELECT
        signature,
        oid,
        CASE WHEN oid IS NULL THEN NULL ELSE pg_get_functiondef(oid) END
            AS definition
    FROM legacy_import_routines
), normalized_identity AS (
    SELECT
        'PRODUCT_CATEGORY_CODE'::TEXT AS identity_type,
        company_id,
        upper(regexp_replace(btrim(category_code),'\s+',' ','g')) AS identity
    FROM public.product_categories
    UNION ALL
    SELECT
        'PRODUCT_CATEGORY_NAME',company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
    FROM public.product_categories
    UNION ALL
    SELECT
        'UOM_CODE',company_id,
        upper(regexp_replace(btrim(code),'\s+',' ','g'))
    FROM public.uoms
    UNION ALL
    SELECT
        'UOM_NAME',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.uoms
    UNION ALL
    SELECT
        'WAREHOUSE_CODE',company_id,
        upper(regexp_replace(btrim(code),'\s+',' ','g'))
    FROM public.warehouses
    UNION ALL
    SELECT
        'WAREHOUSE_NAME',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.warehouses
    UNION ALL
    SELECT
        'SUPPLIER_CODE',company_id,
        upper(regexp_replace(btrim(supplier_code),'\s+',' ','g'))
    FROM public.suppliers
    UNION ALL
    SELECT
        'SUPPLIER_NAME',company_id,
        lower(regexp_replace(btrim(supplier_name),'\s+',' ','g'))
    FROM public.suppliers
    UNION ALL
    SELECT
        'PRODUCT_SKU',company_id,
        upper(regexp_replace(btrim(sku),'\s+',' ','g'))
    FROM public.products
    UNION ALL
    SELECT
        'PRODUCT_NAME',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.products
), duplicate_identity AS (
    SELECT identity_type,company_id,identity
    FROM normalized_identity
    GROUP BY identity_type,company_id,identity
    HAVING count(*) > 1
), product_uom_summary AS (
    SELECT
        p.id AS product_id,
        count(pu.id) AS uom_rows,
        count(pu.id) FILTER(
            WHERE pu.uom_id = p.uom_id AND pu.factor_to_base = 1
        ) AS valid_base_rows,
        count(pu.id) FILTER(
            WHERE pu.uom_id = p.weight_reference_uom_id
        ) AS weight_reference_rows
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
    GROUP BY p.id
), active_product_warehouse_pairs AS (
    SELECT p.company_id,p.id AS product_id,w.id AS warehouse_id
    FROM public.products p
    JOIN public.warehouses w
      ON w.company_id = p.company_id
     AND w.is_active
    WHERE p.is_active AND NOT p.is_bundle
), checks AS (
    SELECT
        'g2_phase28_dependency'::TEXT AS check_name,
        CASE WHEN ledger_rows = 1 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('ledger_rows',ledger_rows) AS details
    FROM dependency

    UNION ALL

    SELECT
        'canonical_import_schema_state',
        'INFO',
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(table_name ORDER BY table_name)
                    FILTER(WHERE to_regclass('public.' || table_name) IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_import_tables

    UNION ALL

    SELECT
        'brand_master_schema_state',
        'INFO',
        jsonb_build_object(
            'product_brands_exists',
            to_regclass('public.product_brands') IS NOT NULL
        )

    UNION ALL

    SELECT
        'legacy_import_routine_inventory',
        'INFO',
        jsonb_build_object(
            'routine_rows',count(*) FILTER(WHERE oid IS NOT NULL),
            'public_wrapper_exists',bool_or(
                signature = 'public.import_products_for_company(uuid,jsonb)'
                AND oid IS NOT NULL
            ),
            'private_legacy_exists',bool_or(
                signature = 'public.private_import_products_for_company_g1_legacy(uuid,jsonb)'
                AND oid IS NOT NULL
            )
        )
    FROM legacy_import_definitions

    UNION ALL

    SELECT
        'browser_legacy_import_execute',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('executable_routines',count(*))
    FROM legacy_import_routines
    WHERE oid IS NOT NULL
      AND (
          has_function_privilege('anon',oid,'EXECUTE')
          OR has_function_privilege('authenticated',oid,'EXECUTE')
      )

    UNION ALL

    SELECT
        'legacy_import_unsafe_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'routines_mixing_initial_stock_or_auto_master',count(*)
        )
    FROM legacy_import_definitions
    WHERE definition ~* '(initial_stock|stock_qty)'
       OR definition ~* 'insert\s+into\s+public\.(uoms|warehouses)'

    UNION ALL

    SELECT
        'duplicate_normalized_import_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'duplicate_groups',count(*),
            'identity_types',COALESCE(
                jsonb_agg(DISTINCT identity_type),
                '[]'::JSONB
            )
        )
    FROM duplicate_identity

    UNION ALL

    SELECT
        'products_missing_canonical_import_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.products
    WHERE category_id IS NULL
       OR uom_id IS NULL
       OR weight_reference_uom_id IS NULL

    UNION ALL

    SELECT
        'invalid_product_uom_group_for_import',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM product_uom_summary
    WHERE uom_rows = 0
       OR valid_base_rows <> 1
       OR weight_reference_rows <> 1

    UNION ALL

    SELECT
        'protected_product_history_inventory',
        'INFO',
        jsonb_build_object(
            'products_with_stock_movement',count(*) FILTER(
                WHERE EXISTS (
                    SELECT 1 FROM public.stock_movements sm
                    WHERE sm.company_id = p.company_id
                      AND sm.product_id = p.id
                )
            ),
            'products_with_sales_history',count(*) FILTER(
                WHERE EXISTS (
                    SELECT 1 FROM public.sales_details sd
                    WHERE sd.company_id = p.company_id
                      AND sd.product_id = p.id
                )
            ),
            'products_with_purchase_history',count(*) FILTER(
                WHERE EXISTS (
                    SELECT 1 FROM public.purchases_details pd
                    WHERE pd.company_id = p.company_id
                      AND pd.product_id = p.id
                )
            )
        )
    FROM public.products p

    UNION ALL

    SELECT
        'opening_stock_eligibility_inventory',
        'INFO',
        jsonb_build_object(
            'active_product_warehouse_pairs',count(*),
            'pairs_without_movement',count(*) FILTER(
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.stock_movements sm
                    WHERE sm.company_id = pair.company_id
                      AND sm.product_id = pair.product_id
                      AND sm.warehouse_id = pair.warehouse_id
                )
            ),
            'pairs_with_movement',count(*) FILTER(
                WHERE EXISTS (
                    SELECT 1 FROM public.stock_movements sm
                    WHERE sm.company_id = pair.company_id
                      AND sm.product_id = pair.product_id
                      AND sm.warehouse_id = pair.warehouse_id
                )
            )
        )
    FROM active_product_warehouse_pairs pair

    UNION ALL

    SELECT
        'master_import_inventory',
        'INFO',
        jsonb_build_object(
            'companies',(SELECT count(*) FROM public.companies),
            'categories',(SELECT count(*) FROM public.product_categories),
            'uoms',(SELECT count(*) FROM public.uoms),
            'warehouses',(SELECT count(*) FROM public.warehouses),
            'suppliers',(SELECT count(*) FROM public.suppliers),
            'products',(SELECT count(*) FROM public.products),
            'product_uoms',(SELECT count(*) FROM public.product_uoms),
            'product_suppliers',(SELECT count(*) FROM public.product_suppliers)
        )

    UNION ALL

    SELECT
        'direct_master_write_privilege',
        'INFO',
        jsonb_build_object(
            'products_insert',has_table_privilege(
                'authenticated','public.products','INSERT'
            ),
            'products_update',has_table_privilege(
                'authenticated','public.products','UPDATE'
            ),
            'product_uoms_insert',has_table_privilege(
                'authenticated','public.product_uoms','INSERT'
            ),
            'suppliers_insert',has_table_privilege(
                'authenticated','public.suppliers','INSERT'
            ),
            'warehouses_insert',has_table_privilege(
                'authenticated','public.warehouses','INSERT'
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
