-- G2 phase 42 preflight: grouped Product + Product-UOM import readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Product/master names.
-- - Product import never creates stock or another referenced master.

WITH required_versions(version) AS (
    VALUES ('20260727090000'),('20260727100000')
), active_company_reference_readiness AS (
    SELECT
        c.id AS company_id,
        EXISTS (
            SELECT 1
            FROM public.product_categories pc
            WHERE pc.company_id = c.id
              AND pc.is_active
        ) AS has_active_category,
        EXISTS (
            SELECT 1
            FROM public.uoms u
            WHERE u.company_id = c.id
              AND u.is_active
        ) AS has_active_uom
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
), product_group_summary AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        p.is_active,
        p.is_bundle,
        p.uom_id AS base_uom_id,
        p.weight_reference_uom_id,
        p.weight_per_uom_kg,
        count(pu.id) AS uom_rows,
        count(pu.id) FILTER (
            WHERE pu.uom_id = p.uom_id
              AND pu.factor_to_base = 1
              AND pu.is_active
        ) AS valid_base_rows,
        count(pu.id) FILTER (
            WHERE pu.uom_id = p.weight_reference_uom_id
              AND pu.is_active
        ) AS weight_reference_rows,
        max(pu.factor_to_base) FILTER (
            WHERE pu.is_active
        ) AS largest_active_factor,
        max(pu.factor_to_base) FILTER (
            WHERE pu.uom_id = p.weight_reference_uom_id
        ) AS weight_reference_factor,
        count(pu.id) FILTER (
            WHERE pu.is_active AND pu.sales_allowed
        ) AS active_sales_uoms,
        count(pu.id) FILTER (
            WHERE pu.is_active AND pu.purchase_allowed
        ) AS active_purchase_uoms
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
    GROUP BY
        p.company_id,p.id,p.is_active,p.is_bundle,p.uom_id,
        p.weight_reference_uom_id,p.weight_per_uom_kg
), product_history AS (
    SELECT
        p.company_id,
        p.id AS product_id,
        EXISTS (
            SELECT 1
            FROM public.stock_movements sm
            WHERE sm.company_id = p.company_id
              AND sm.product_id = p.id
        ) AS has_movement,
        EXISTS (
            SELECT 1
            FROM public.sales_details sd
            WHERE sd.company_id = p.company_id
              AND sd.product_id = p.id
        ) AS has_sales,
        EXISTS (
            SELECT 1
            FROM public.purchases_details pd
            WHERE pd.company_id = p.company_id
              AND pd.product_id = p.id
        ) AS has_purchase
    FROM public.products p
), ambiguous_references AS (
    SELECT company_id,'PRODUCT_CATEGORY'::TEXT AS reference_type
    FROM public.product_categories
    GROUP BY
        company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
    HAVING count(*) > 1

    UNION ALL

    SELECT company_id,'UOM'
    FROM public.uoms
    GROUP BY
        company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    HAVING count(*) > 1

    UNION ALL

    SELECT company_id,'TAX_RULE'
    FROM public.tax_rules
    GROUP BY
        company_id,
        lower(regexp_replace(btrim(tax_name),'\s+',' ','g'))
    HAVING count(*) > 1
), checks AS (
    SELECT
        'g2_phase40_dependency'::TEXT AS check_name,
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
        'grouped_product_import_schema_state',
        'INFO',
        jsonb_build_object(
            'product_job_type_supported',
                COALESCE((
                    SELECT bool_or(
                        position(
                            '''PRODUCT''' IN pg_get_constraintdef(con.oid)
                        ) > 0
                    )
                    FROM pg_constraint con
                    JOIN pg_class rel ON rel.oid = con.conrelid
                    JOIN pg_namespace n ON n.oid = rel.relnamespace
                    WHERE n.nspname = 'public'
                      AND rel.relname = 'master_import_jobs'
                      AND con.conname = 'master_import_jobs_type_check'
                ),FALSE),
            'product_audit_exists',
                to_regclass('public.product_master_audit') IS NOT NULL,
            'product_uoms_exists',
                to_regclass('public.product_uoms') IS NOT NULL
        )

    UNION ALL

    SELECT
        'guarded_product_group_rpc_state',
        CASE WHEN EXISTS (
            SELECT 1
            FROM pg_proc p
            WHERE p.oid = to_regprocedure(
                'public.save_product_with_uoms(uuid,bigint,text,text,uuid,uuid,uuid,numeric,boolean,text,boolean,jsonb,uuid,uuid)'
            )
              AND NOT has_function_privilege('anon',p.oid,'EXECUTE')
              AND has_function_privilege(
                  'authenticated',p.oid,'EXECUTE'
              )
        )
            THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'atomic_product_tax_rpc_exists',
                to_regprocedure(
                    'public.save_product_with_uoms(uuid,bigint,text,text,uuid,uuid,uuid,numeric,boolean,text,boolean,jsonb,uuid,uuid)'
                ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'active_company_reference_readiness',
        CASE WHEN count(*) FILTER (
            WHERE NOT has_active_category OR NOT has_active_uom
        ) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'active_companies',count(*),
            'companies_without_active_category',count(*) FILTER (
                WHERE NOT has_active_category
            ),
            'companies_without_active_uom',count(*) FILTER (
                WHERE NOT has_active_uom
            )
        )
    FROM active_company_reference_readiness

    UNION ALL

    SELECT
        'blank_product_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.products
    WHERE btrim(COALESCE(sku,'')) = ''
       OR btrim(COALESCE(name,'')) = ''

    UNION ALL

    SELECT
        'duplicate_normalized_product_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,'SKU'::TEXT AS identity_type
        FROM public.products
        GROUP BY
            company_id,
            upper(regexp_replace(btrim(sku),'\s+',' ','g'))
        HAVING count(*) > 1

        UNION ALL

        SELECT company_id,'NAME'
        FROM public.products
        GROUP BY
            company_id,
            lower(regexp_replace(btrim(name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'ambiguous_product_import_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'ambiguous_groups',count(*),
            'reference_types',COALESCE(
                jsonb_agg(DISTINCT reference_type),
                '[]'::JSONB
            )
        )
    FROM ambiguous_references

    UNION ALL

    SELECT
        'products_missing_canonical_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.products p
    LEFT JOIN public.product_categories pc
      ON pc.company_id = p.company_id
     AND pc.id = p.category_id
    LEFT JOIN public.uoms base_uom
      ON base_uom.company_id = p.company_id
     AND base_uom.id = p.uom_id
    LEFT JOIN public.uoms weight_uom
      ON weight_uom.company_id = p.company_id
     AND weight_uom.id = p.weight_reference_uom_id
    WHERE pc.id IS NULL
       OR base_uom.id IS NULL
       OR weight_uom.id IS NULL

    UNION ALL

    SELECT
        'invalid_product_uom_group_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM product_group_summary
    WHERE uom_rows < 1
       OR uom_rows > 20
       OR valid_base_rows <> 1
       OR weight_reference_rows <> 1
       OR weight_reference_factor IS DISTINCT FROM largest_active_factor
       OR weight_per_uom_kg <= 0
       OR (is_active AND active_sales_uoms = 0)
       OR (is_active AND NOT is_bundle AND active_purchase_uoms = 0)

    UNION ALL

    SELECT
        'invalid_product_uom_value',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_uoms pu
    LEFT JOIN public.uoms u
      ON u.company_id = pu.company_id
     AND u.id = pu.uom_id
    WHERE u.id IS NULL
       OR pu.factor_to_base < 1
       OR pu.purchase_price < 0
       OR pu.sale_price < 0
       OR (pu.purchase_allowed AND pu.purchase_price IS NULL)
       OR (pu.sales_allowed AND pu.sale_price IS NULL)
       OR (NOT pu.is_active AND (pu.purchase_allowed OR pu.sales_allowed))

    UNION ALL

    SELECT
        'duplicate_product_uom_or_barcode',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,product_id,uom_id::TEXT AS identity
        FROM public.product_uoms
        GROUP BY company_id,product_id,uom_id
        HAVING count(*) > 1

        UNION ALL

        SELECT
            company_id,
            NULL::UUID,
            upper(regexp_replace(btrim(barcode),'\s+','','g'))
        FROM public.product_uoms
        WHERE barcode IS NOT NULL
        GROUP BY
            company_id,
            upper(regexp_replace(btrim(barcode),'\s+','','g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'inactive_reference_used_by_active_product',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.products p
    JOIN public.product_categories pc
      ON pc.company_id = p.company_id
     AND pc.id = p.category_id
    JOIN public.uoms base_uom
      ON base_uom.company_id = p.company_id
     AND base_uom.id = p.uom_id
    JOIN public.uoms weight_uom
      ON weight_uom.company_id = p.company_id
     AND weight_uom.id = p.weight_reference_uom_id
    WHERE p.is_active
      AND (
          NOT pc.is_active
          OR NOT base_uom.is_active
          OR NOT weight_uom.is_active
      )

    UNION ALL

    SELECT
        'invalid_existing_product_tax_assignment',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.products p
    LEFT JOIN public.tax_rules sales_rule
      ON sales_rule.company_id = p.company_id
     AND sales_rule.id = p.sales_tax_rule_id
    LEFT JOIN public.tax_rules purchase_rule
      ON purchase_rule.company_id = p.company_id
     AND purchase_rule.id = p.purchase_tax_rule_id
    WHERE (
        p.sales_tax_rule_id IS NOT NULL
        AND (
            sales_rule.id IS NULL
            OR sales_rule.tax_scope <> 'SALES'
        )
    ) OR (
        p.purchase_tax_rule_id IS NOT NULL
        AND (
            purchase_rule.id IS NULL
            OR purchase_rule.tax_scope <> 'PURCHASE'
        )
    )

    UNION ALL

    SELECT
        'assigned_product_tax_without_current_version',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('assignment_count',count(*))
    FROM (
        SELECT p.company_id,p.id,'SALES'::TEXT AS tax_scope,
               p.sales_tax_rule_id AS tax_rule_id
        FROM public.products p
        WHERE p.sales_tax_rule_id IS NOT NULL

        UNION ALL

        SELECT p.company_id,p.id,'PURCHASE',p.purchase_tax_rule_id
        FROM public.products p
        WHERE p.purchase_tax_rule_id IS NOT NULL
    ) assigned
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.tax_rule_versions v
        WHERE v.company_id = assigned.company_id
          AND v.tax_rule_id = assigned.tax_rule_id
          AND v.status = 'ACTIVE'
          AND v.effective_from <= clock_timestamp()
          AND (
              v.effective_to IS NULL
              OR v.effective_to > clock_timestamp()
          )
    )

    UNION ALL

    SELECT
        'legacy_product_uom_conversion_rows',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_uom_conversions

    UNION ALL

    SELECT
        'nonterminal_import_jobs',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'job_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status NOT IN (
        'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
    )

    UNION ALL

    SELECT
        'product_history_protection_scope',
        'INFO',
        jsonb_build_object(
            'products_with_movement',count(*) FILTER (WHERE has_movement),
            'products_with_sales',count(*) FILTER (WHERE has_sales),
            'products_with_purchase',count(*) FILTER (WHERE has_purchase),
            'protected_products',count(*) FILTER (
                WHERE has_movement OR has_sales OR has_purchase
            )
        )
    FROM product_history

    UNION ALL

    SELECT
        'product_import_inventory',
        'INFO',
        jsonb_build_object(
            'products',count(*),
            'active_products',count(*) FILTER (WHERE is_active),
            'stock_products',count(*) FILTER (WHERE NOT is_bundle),
            'bundle_products_export_only',count(*) FILTER (WHERE is_bundle),
            'product_uom_rows',(
                SELECT count(*) FROM public.product_uoms
            ),
            'categories',(
                SELECT count(*) FROM public.product_categories
            ),
            'uoms',(
                SELECT count(*) FROM public.uoms
            ),
            'tax_rules',(
                SELECT count(*) FROM public.tax_rules
            )
        )
    FROM public.products

    UNION ALL

    SELECT
        'direct_product_group_write_privilege',
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
            'product_uoms_update',has_table_privilege(
                'authenticated','public.product_uoms','UPDATE'
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
