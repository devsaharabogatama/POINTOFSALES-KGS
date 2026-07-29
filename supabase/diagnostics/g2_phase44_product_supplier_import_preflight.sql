-- G2 phase 44 preflight: Product-Supplier fixed import readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Supplier names, Product names, bank,
--   contact, price, or business-code values are exposed.
-- - Run the entire file in Supabase SQL Editor and export the final result.

WITH required_versions(version) AS (
    VALUES ('20260727130000'),('20260727140000')
), normalized_active_references AS (
    SELECT
        'PRODUCT_SKU'::TEXT AS reference_type,
        p.company_id,
        upper(regexp_replace(btrim(p.sku),'\s+',' ','g')) AS value
    FROM public.products p
    WHERE p.is_active

    UNION ALL

    SELECT
        'SUPPLIER_NAME',
        s.company_id,
        lower(regexp_replace(btrim(s.supplier_name),'\s+',' ','g'))
    FROM public.suppliers s
    WHERE s.is_active

    UNION ALL

    SELECT
        'UOM_NAME',
        u.company_id,
        lower(regexp_replace(btrim(u.name),'\s+',' ','g'))
    FROM public.uoms u
    WHERE u.is_active
), active_stock_product_readiness AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        count(pu.id) FILTER (
            WHERE pu.is_active
              AND pu.purchase_allowed
              AND u.id IS NOT NULL
              AND u.is_active
        ) AS active_purchase_uoms
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
    LEFT JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
    WHERE p.is_active
      AND NOT p.is_bundle
    GROUP BY p.company_id,p.id
), checks AS (
    SELECT
        'g2_phase42_dependency'::TEXT AS check_name,
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
        'guarded_product_supplier_rpc',
        CASE WHEN to_regprocedure(
            'public.save_product_supplier(uuid,bigint,uuid,uuid,uuid,text,numeric,boolean,boolean)'
        ) IS NOT NULL THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'rpc_exists',
            to_regprocedure(
                'public.save_product_supplier(uuid,bigint,uuid,uuid,uuid,text,numeric,boolean,boolean)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'ambiguous_active_import_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'duplicate_groups',count(*),
            'reference_types',COALESCE(
                jsonb_agg(DISTINCT reference_type),
                '[]'::JSONB
            )
        )
    FROM (
        SELECT reference_type,company_id,value
        FROM normalized_active_references
        GROUP BY reference_type,company_id,value
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'active_stock_product_without_purchase_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM active_stock_product_readiness
    WHERE active_purchase_uoms = 0

    UNION ALL

    SELECT
        'invalid_existing_product_supplier_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_suppliers ps
    LEFT JOIN public.products p
      ON p.company_id = ps.company_id
     AND p.id = ps.product_id
    LEFT JOIN public.suppliers s
      ON s.company_id = ps.company_id
     AND s.id = ps.supplier_id
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = ps.company_id
     AND pu.product_id = ps.product_id
     AND pu.uom_id = ps.purchase_uom_id
    WHERE p.id IS NULL OR s.id IS NULL OR pu.id IS NULL

    UNION ALL

    SELECT
        'active_product_supplier_invalid_operational_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_suppliers ps
    JOIN public.products p
      ON p.company_id = ps.company_id
     AND p.id = ps.product_id
    JOIN public.suppliers s
      ON s.company_id = ps.company_id
     AND s.id = ps.supplier_id
    JOIN public.product_uoms pu
      ON pu.company_id = ps.company_id
     AND pu.product_id = ps.product_id
     AND pu.uom_id = ps.purchase_uom_id
    JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
    WHERE ps.is_active
      AND (
          NOT p.is_active
          OR p.is_bundle
          OR NOT s.is_active
          OR NOT pu.is_active
          OR NOT pu.purchase_allowed
          OR NOT u.is_active
      )

    UNION ALL

    SELECT
        'multiple_active_preferred_supplier',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM (
        SELECT company_id,product_id
        FROM public.product_suppliers
        WHERE is_active AND is_preferred_supplier
        GROUP BY company_id,product_id
        HAVING count(*) > 1
    ) duplicate_preferred

    UNION ALL

    SELECT
        'invalid_product_supplier_value',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_suppliers
    WHERE master_version <= 0
       OR reference_purchase_price < 0
       OR last_purchase_price < 0
       OR (is_preferred_supplier AND NOT is_active)
       OR (
           last_purchase_price IS NOT NULL
           AND last_price_updated_at IS NULL
       )
       OR (
           supplier_product_code IS NOT NULL
           AND btrim(supplier_product_code) = ''
       )

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'job_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status IN ('UPLOADED','MAPPED','VALIDATED')

    UNION ALL

    SELECT
        'product_supplier_import_job_schema_state',
        'INFO',
        jsonb_build_object(
            'job_type_constraint_accepts_product_supplier',
            EXISTS (
                SELECT 1
                FROM pg_constraint con
                JOIN pg_class rel ON rel.oid = con.conrelid
                JOIN pg_namespace n ON n.oid = rel.relnamespace
                WHERE n.nspname = 'public'
                  AND rel.relname = 'master_import_jobs'
                  AND con.contype = 'c'
                  AND pg_get_constraintdef(con.oid)
                      LIKE '%PRODUCT_SUPPLIER%'
            )
        )

    UNION ALL

    SELECT
        'product_supplier_inventory',
        'INFO',
        jsonb_build_object(
            'relations',count(*),
            'active_relations',count(*) FILTER (WHERE is_active),
            'preferred_relations',count(*) FILTER (
                WHERE is_active AND is_preferred_supplier
            ),
            'products',count(DISTINCT product_id),
            'suppliers',count(DISTINCT supplier_id),
            'relations_with_supplier_product_code',count(*) FILTER (
                WHERE NULLIF(btrim(supplier_product_code),'') IS NOT NULL
            ),
            'relations_with_reference_price',count(*) FILTER (
                WHERE reference_purchase_price IS NOT NULL
            ),
            'relations_with_last_purchase_price',count(*) FILTER (
                WHERE last_purchase_price IS NOT NULL
            )
        )
    FROM public.product_suppliers

    UNION ALL

    SELECT
        'product_supplier_reference_inventory',
        'INFO',
        jsonb_build_object(
            'active_stock_products',(
                SELECT count(*) FROM public.products
                WHERE is_active AND NOT is_bundle
            ),
            'active_suppliers',(
                SELECT count(*) FROM public.suppliers WHERE is_active
            ),
            'active_purchase_product_uoms',(
                SELECT count(*) FROM public.product_uoms
                WHERE is_active AND purchase_allowed
            )
        )

    UNION ALL

    SELECT
        'direct_product_supplier_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert',has_table_privilege(
                'authenticated','public.product_suppliers','INSERT'
            ),
            'authenticated_update',has_table_privilege(
                'authenticated','public.product_suppliers','UPDATE'
            ),
            'authenticated_delete',has_table_privilege(
                'authenticated','public.product_suppliers','DELETE'
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
