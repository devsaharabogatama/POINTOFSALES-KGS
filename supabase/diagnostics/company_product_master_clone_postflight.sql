-- Company Product master clone postflight. SELECT-only against persistent data.

DROP TABLE IF EXISTS pg_temp.kgs_product_clone_verify_config;
CREATE TEMP TABLE kgs_product_clone_verify_config(
    source_company_id UUID,
    source_company_name TEXT,
    target_company_id UUID,
    target_company_name TEXT
);
INSERT INTO kgs_product_clone_verify_config VALUES(
    NULL,'KGS Company',NULL,NULL
);

DO $validate$
DECLARE v pg_temp.kgs_product_clone_verify_config%ROWTYPE;
BEGIN
    SELECT * INTO STRICT v FROM pg_temp.kgs_product_clone_verify_config;
    IF v.source_company_id IS NULL OR v.target_company_id IS NULL THEN
        RAISE EXCEPTION 'CONFIG_REQUIRED';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.companies
                  WHERE id=v.source_company_id AND btrim(company_name)=btrim(v.source_company_name)) THEN
        RAISE EXCEPTION 'SOURCE_COMPANY_IDENTITY_MISMATCH';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.companies
                  WHERE id=v.target_company_id AND btrim(company_name)=btrim(v.target_company_name)) THEN
        RAISE EXCEPTION 'TARGET_COMPANY_IDENTITY_MISMATCH';
    END IF;
END
$validate$;

WITH config AS(SELECT * FROM pg_temp.kgs_product_clone_verify_config), checks AS(
    SELECT 'master_row_counts'::TEXT AS check_name,
      CASE WHEN source_categories=target_categories AND source_uoms=target_uoms
             AND source_products=target_products AND source_product_uoms=target_product_uoms
             AND source_bundle_items=target_bundle_items
           THEN 'PASS' ELSE 'FAIL' END AS status,
      jsonb_build_object('sourceCategories',source_categories,'targetCategories',target_categories,
        'sourceUoms',source_uoms,'targetUoms',target_uoms,
        'sourceProducts',source_products,'targetProducts',target_products,
        'sourceProductUoms',source_product_uoms,'targetProductUoms',target_product_uoms,
        'sourceBundleItems',source_bundle_items,'targetBundleItems',target_bundle_items) AS details
    FROM config CROSS JOIN LATERAL(SELECT
      (SELECT count(*) FROM public.product_categories WHERE company_id=config.source_company_id) source_categories,
      (SELECT count(*) FROM public.product_categories WHERE company_id=config.target_company_id) target_categories,
      (SELECT count(*) FROM public.uoms WHERE company_id=config.source_company_id) source_uoms,
      (SELECT count(*) FROM public.uoms WHERE company_id=config.target_company_id) target_uoms,
      (SELECT count(*) FROM public.products WHERE company_id=config.source_company_id) source_products,
      (SELECT count(*) FROM public.products WHERE company_id=config.target_company_id) target_products,
      (SELECT count(*) FROM public.product_uoms WHERE company_id=config.source_company_id) source_product_uoms,
      (SELECT count(*) FROM public.product_uoms WHERE company_id=config.target_company_id) target_product_uoms,
      (SELECT count(*) FROM public.product_bundle_items WHERE company_id=config.source_company_id) source_bundle_items,
      (SELECT count(*) FROM public.product_bundle_items WHERE company_id=config.target_company_id) target_bundle_items
    ) count_state

    UNION ALL
    SELECT 'category_semantic_parity',CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END,
      jsonb_build_object('violationRows',violation_rows)
    FROM config CROSS JOIN LATERAL(
      SELECT count(*) violation_rows FROM public.product_categories source_row
      LEFT JOIN public.product_categories target_row
        ON target_row.company_id=config.target_company_id
       AND upper(regexp_replace(btrim(target_row.category_code),'\s+',' ','g'))=
           upper(regexp_replace(btrim(source_row.category_code),'\s+',' ','g'))
      WHERE source_row.company_id=config.source_company_id AND (
        target_row.id IS NULL OR target_row.category_name IS DISTINCT FROM source_row.category_name
        OR target_row.is_active IS DISTINCT FROM source_row.is_active)
    ) state

    UNION ALL
    SELECT 'uom_semantic_parity',CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END,
      jsonb_build_object('violationRows',violation_rows)
    FROM config CROSS JOIN LATERAL(
      SELECT count(*) violation_rows FROM public.uoms source_row
      LEFT JOIN public.uoms target_row
        ON target_row.company_id=config.target_company_id
       AND upper(regexp_replace(btrim(target_row.code),'\s+',' ','g'))=
           upper(regexp_replace(btrim(source_row.code),'\s+',' ','g'))
      WHERE source_row.company_id=config.source_company_id AND (
        target_row.id IS NULL OR target_row.name IS DISTINCT FROM source_row.name
        OR target_row.uom_type IS DISTINCT FROM source_row.uom_type
        OR target_row.allow_decimal IS DISTINCT FROM source_row.allow_decimal
        OR target_row.decimal_precision IS DISTINCT FROM source_row.decimal_precision
        OR target_row.is_active IS DISTINCT FROM source_row.is_active)
    ) state

    UNION ALL
    SELECT 'product_semantic_parity',CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END,
      jsonb_build_object('violationRows',violation_rows)
    FROM config CROSS JOIN LATERAL(
      SELECT count(*) violation_rows
      FROM public.products source_product
      JOIN public.product_categories source_category
        ON source_category.company_id=config.source_company_id AND source_category.id=source_product.category_id
      JOIN public.uoms source_base
        ON source_base.company_id=config.source_company_id AND source_base.id=source_product.uom_id
      JOIN public.uoms source_weight
        ON source_weight.company_id=config.source_company_id AND source_weight.id=source_product.weight_reference_uom_id
      LEFT JOIN public.products target_product
        ON target_product.company_id=config.target_company_id
       AND upper(regexp_replace(btrim(target_product.sku),'\s+',' ','g'))=
           upper(regexp_replace(btrim(source_product.sku),'\s+',' ','g'))
      LEFT JOIN public.product_categories target_category
        ON target_category.company_id=config.target_company_id AND target_category.id=target_product.category_id
      LEFT JOIN public.uoms target_base
        ON target_base.company_id=config.target_company_id AND target_base.id=target_product.uom_id
      LEFT JOIN public.uoms target_weight
        ON target_weight.company_id=config.target_company_id AND target_weight.id=target_product.weight_reference_uom_id
      WHERE source_product.company_id=config.source_company_id AND (
        target_product.id IS NULL OR target_product.name IS DISTINCT FROM source_product.name
        OR target_product.weight_per_uom_kg IS DISTINCT FROM source_product.weight_per_uom_kg
        OR target_product.is_bundle IS DISTINCT FROM source_product.is_bundle
        OR target_product.is_active IS DISTINCT FROM source_product.is_active
        OR target_product.image_url IS DISTINCT FROM source_product.image_url
        OR target_category.category_code IS DISTINCT FROM source_category.category_code
        OR target_base.code IS DISTINCT FROM source_base.code
        OR target_weight.code IS DISTINCT FROM source_weight.code)
    ) state

    UNION ALL
    SELECT 'product_uom_semantic_parity',CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END,
      jsonb_build_object('violationRows',violation_rows)
    FROM config CROSS JOIN LATERAL(
      SELECT count(*) violation_rows
      FROM public.product_uoms source_row
      JOIN public.products source_product
        ON source_product.company_id=config.source_company_id AND source_product.id=source_row.product_id
      JOIN public.uoms source_uom
        ON source_uom.company_id=config.source_company_id AND source_uom.id=source_row.uom_id
      LEFT JOIN public.products target_product
        ON target_product.company_id=config.target_company_id
       AND upper(regexp_replace(btrim(target_product.sku),'\s+',' ','g'))=
           upper(regexp_replace(btrim(source_product.sku),'\s+',' ','g'))
      LEFT JOIN public.uoms target_uom
        ON target_uom.company_id=config.target_company_id
       AND upper(regexp_replace(btrim(target_uom.code),'\s+',' ','g'))=
           upper(regexp_replace(btrim(source_uom.code),'\s+',' ','g'))
      LEFT JOIN public.product_uoms target_row
        ON target_row.company_id=config.target_company_id
       AND target_row.product_id=target_product.id AND target_row.uom_id=target_uom.id
      WHERE source_row.company_id=config.source_company_id AND (
        target_row.id IS NULL OR target_row.factor_to_base IS DISTINCT FROM source_row.factor_to_base
        OR target_row.purchase_allowed IS DISTINCT FROM source_row.purchase_allowed
        OR target_row.sales_allowed IS DISTINCT FROM source_row.sales_allowed
        OR target_row.purchase_price IS DISTINCT FROM source_row.purchase_price
        OR target_row.sale_price IS DISTINCT FROM source_row.sale_price
        OR target_row.barcode IS DISTINCT FROM source_row.barcode
        OR target_row.is_active IS DISTINCT FROM source_row.is_active)
    ) state

    UNION ALL
    SELECT 'zero_operational_effect',CASE WHEN row_count=0 THEN 'PASS' ELSE 'FAIL' END,
      jsonb_build_object('rowCount',row_count)
    FROM config CROSS JOIN LATERAL(SELECT
      (SELECT count(*) FROM public.product_stocks WHERE company_id=config.target_company_id)+
      (SELECT count(*) FROM public.product_batches WHERE company_id=config.target_company_id)+
      (SELECT count(*) FROM public.stock_movements WHERE company_id=config.target_company_id)+
      (SELECT count(*) FROM public.sales_headers WHERE company_id=config.target_company_id)+
      (SELECT count(*) FROM public.financial_events WHERE company_id=config.target_company_id) row_count
    ) state

    UNION ALL
    SELECT 'clone_audit_coverage',CASE WHEN product_audits>=product_count
           AND category_audits>=category_count AND uom_audits>=uom_count
           THEN 'PASS' ELSE 'FAIL' END,
      jsonb_build_object('products',product_count,'productAudits',product_audits,
        'categories',category_count,'categoryAudits',category_audits,
        'uoms',uom_count,'uomAudits',uom_audits)
    FROM config CROSS JOIN LATERAL(SELECT
      (SELECT count(*) FROM public.products WHERE company_id=config.target_company_id) product_count,
      (SELECT count(*) FROM public.product_master_audit WHERE company_id=config.target_company_id) product_audits,
      (SELECT count(*) FROM public.product_categories WHERE company_id=config.target_company_id) category_count,
      (SELECT count(*) FROM public.inventory_master_write_audit
       WHERE company_id=config.target_company_id AND master_type='PRODUCT_CATEGORY' AND action='CREATE') category_audits,
      (SELECT count(*) FROM public.uoms WHERE company_id=config.target_company_id) uom_count,
      (SELECT count(*) FROM public.inventory_master_write_audit
       WHERE company_id=config.target_company_id AND master_type='UOM' AND action='CREATE') uom_audits
    ) state
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
