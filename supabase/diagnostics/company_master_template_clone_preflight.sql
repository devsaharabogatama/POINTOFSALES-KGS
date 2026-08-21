-- Company master-template clone preflight.
-- SELECT-only against persistent schema; temporary config/result only.
-- Run after the target Company has been created and before any operational use.

DROP TABLE IF EXISTS pg_temp.kgs_master_clone_config;
CREATE TEMP TABLE kgs_master_clone_config(
    source_company_id UUID,
    source_company_name TEXT,
    target_company_id UUID,
    target_company_name TEXT
);

INSERT INTO kgs_master_clone_config VALUES(
    NULL,  -- UUID source Company
    'KGS Company',
    NULL,  -- UUID new target Company
    NULL   -- exact target company_name
);

DO $validate$
DECLARE
    v_config pg_temp.kgs_master_clone_config%ROWTYPE;
    v_source_name TEXT;
    v_target_name TEXT;
BEGIN
    SELECT * INTO STRICT v_config FROM pg_temp.kgs_master_clone_config;
    IF v_config.source_company_id IS NULL OR v_config.target_company_id IS NULL
       OR NULLIF(btrim(v_config.source_company_name),'') IS NULL
       OR NULLIF(btrim(v_config.target_company_name),'') IS NULL THEN
        RAISE EXCEPTION 'CONFIG_REQUIRED: fill source/target UUID and exact name';
    END IF;
    IF v_config.source_company_id = v_config.target_company_id THEN
        RAISE EXCEPTION 'SOURCE_AND_TARGET_COMPANY_MUST_DIFFER';
    END IF;
    SELECT company_name INTO v_source_name FROM public.companies
    WHERE id = v_config.source_company_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SOURCE_COMPANY_NOT_FOUND'; END IF;
    SELECT company_name INTO v_target_name FROM public.companies
    WHERE id = v_config.target_company_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'TARGET_COMPANY_NOT_FOUND'; END IF;
    IF btrim(v_source_name) IS DISTINCT FROM
       btrim(v_config.source_company_name) THEN
        RAISE EXCEPTION 'SOURCE_COMPANY_NAME_MISMATCH: %',v_source_name;
    END IF;
    IF btrim(v_target_name) IS DISTINCT FROM
       btrim(v_config.target_company_name) THEN
        RAISE EXCEPTION 'TARGET_COMPANY_NAME_MISMATCH: %',v_target_name;
    END IF;
END
$validate$;

WITH config AS (
    SELECT * FROM pg_temp.kgs_master_clone_config
), checks AS (
    SELECT
        'target_operational_history'::TEXT AS check_name,
        CASE WHEN scope.row_count=0 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'rowCount',scope.row_count,
            'sales',scope.sales,
            'financialEvents',scope.financial_events,
            'canonicalJournals',scope.finance_journals,
            'stockMovements',scope.stock_movements,
            'purchaseOrders',scope.purchase_orders
        ) AS details
    FROM config
    CROSS JOIN LATERAL (
        SELECT
            (SELECT count(*) FROM public.sales_headers
             WHERE company_id=config.target_company_id) AS sales,
            (SELECT count(*) FROM public.financial_events
             WHERE company_id=config.target_company_id) AS financial_events,
            (SELECT count(*) FROM public.finance_journals
             WHERE company_id=config.target_company_id) AS finance_journals,
            (SELECT count(*) FROM public.stock_movements
             WHERE company_id=config.target_company_id) AS stock_movements,
            (SELECT count(*) FROM public.supplier_order_documents
             WHERE company_id=config.target_company_id) AS purchase_orders
    ) item
    CROSS JOIN LATERAL (
        SELECT item.sales + item.financial_events + item.finance_journals
             + item.stock_movements + item.purchase_orders AS row_count,
             item.*
    ) scope

    UNION ALL

    SELECT
        'target_product_master_state',
        CASE WHEN product_count=0 AND product_uom_count=0
                  AND bundle_item_count=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'products',product_count,'productUoms',product_uom_count,
            'bundleItems',bundle_item_count,'categories',category_count,
            'uoms',uom_count
        )
    FROM config
    CROSS JOIN LATERAL (
        SELECT
            (SELECT count(*) FROM public.products
             WHERE company_id=config.target_company_id) AS product_count,
            (SELECT count(*) FROM public.product_uoms
             WHERE company_id=config.target_company_id) AS product_uom_count,
            (SELECT count(*) FROM public.product_bundle_items
             WHERE company_id=config.target_company_id) AS bundle_item_count,
            (SELECT count(*) FROM public.product_categories
             WHERE company_id=config.target_company_id) AS category_count,
            (SELECT count(*) FROM public.uoms
             WHERE company_id=config.target_company_id) AS uom_count
    ) scope

    UNION ALL

    SELECT
        'target_tax_and_pricelist_baseline',
        CASE WHEN tax_version_count=0 AND pricelist_rule_count=0
             THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'taxRules',tax_rule_count,'taxRuleVersions',tax_version_count,
            'pricelists',pricelist_count,'pricelistRules',pricelist_rule_count
        )
    FROM config
    CROSS JOIN LATERAL (
        SELECT
            (SELECT count(*) FROM public.tax_rules
             WHERE company_id=config.target_company_id) AS tax_rule_count,
            (SELECT count(*) FROM public.tax_rule_versions
             WHERE company_id=config.target_company_id) AS tax_version_count,
            (SELECT count(*) FROM public.pricelists
             WHERE company_id=config.target_company_id) AS pricelist_count,
            (SELECT count(*) FROM public.pricelist_rules
             WHERE company_id=config.target_company_id) AS pricelist_rule_count
    ) scope

    UNION ALL

    SELECT
        'source_product_dependency_integrity',
        CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('violationRows',violation_rows)
    FROM config
    CROSS JOIN LATERAL (
        SELECT count(*) AS violation_rows
        FROM public.products product
        WHERE product.company_id=config.source_company_id
          AND (
            product.category_id IS NULL
            OR product.uom_id IS NULL
            OR product.weight_reference_uom_id IS NULL
            OR NOT EXISTS(
                SELECT 1 FROM public.product_categories category
                WHERE category.company_id=product.company_id
                  AND category.id=product.category_id)
            OR NOT EXISTS(
                SELECT 1 FROM public.uoms uom
                WHERE uom.company_id=product.company_id
                  AND uom.id=product.uom_id)
            OR NOT EXISTS(
                SELECT 1 FROM public.uoms uom
                WHERE uom.company_id=product.company_id
                  AND uom.id=product.weight_reference_uom_id)
            OR NOT EXISTS(
                SELECT 1 FROM public.product_uoms product_uom
                WHERE product_uom.company_id=product.company_id
                  AND product_uom.product_id=product.id
                  AND product_uom.uom_id=product.uom_id
                  AND product_uom.factor_to_base=1)
          )
    ) scope

    UNION ALL

    SELECT
        'source_bundle_dependency_integrity',
        CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('violationRows',violation_rows)
    FROM config
    CROSS JOIN LATERAL (
        SELECT count(*) AS violation_rows
        FROM public.product_bundle_items item
        WHERE item.company_id=config.source_company_id
          AND (
            NOT EXISTS(SELECT 1 FROM public.products bundle
                       WHERE bundle.company_id=item.company_id
                         AND bundle.id=item.bundle_id AND bundle.is_bundle)
            OR NOT EXISTS(SELECT 1 FROM public.products component
                          WHERE component.company_id=item.company_id
                            AND component.id=item.item_id
                            AND NOT component.is_bundle)
            OR NOT EXISTS(SELECT 1 FROM public.product_uoms product_uom
                          WHERE product_uom.company_id=item.company_id
                            AND product_uom.product_id=item.item_id
                            AND product_uom.uom_id=item.component_uom_id)
          )
    ) scope

    UNION ALL

    SELECT
        'source_tax_account_target_mapping',
        CASE WHEN unresolved_rows=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('unresolvedRows',unresolved_rows)
    FROM config
    CROSS JOIN LATERAL (
        SELECT count(*) AS unresolved_rows
        FROM public.tax_rule_versions version
        JOIN public.chart_of_accounts source_account
          ON source_account.company_id=version.company_id
         AND source_account.id=version.account_id
        WHERE version.company_id=config.source_company_id
          AND version.status='ACTIVE'
          AND version.effective_from<=clock_timestamp()
          AND (version.effective_to IS NULL
               OR version.effective_to>clock_timestamp())
          AND NOT EXISTS(
              SELECT 1 FROM public.chart_of_accounts target_account
              WHERE target_account.company_id=config.target_company_id
                AND (
                  (source_account.is_system_account
                   AND target_account.is_system_account
                   AND target_account.system_function_key=
                       source_account.system_function_key)
                  OR upper(regexp_replace(btrim(target_account.account_code),
                                          '\s+',' ','g'))=
                     upper(regexp_replace(btrim(source_account.account_code),
                                          '\s+',' ','g'))
                )
          )
    ) scope

    UNION ALL

    SELECT
        'source_store_scoped_global_pricelist',
        CASE WHEN row_count=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'rowCount',row_count,
            'reason','Store assignments cannot cross Company identity'
        )
    FROM config
    CROSS JOIN LATERAL (
        SELECT count(*) AS row_count FROM public.pricelists pricelist
        WHERE pricelist.company_id=config.source_company_id
          AND pricelist.scope='GLOBAL'
          AND NOT pricelist.applies_all_stores
    ) scope

    UNION ALL

    SELECT
        'master_identity_conflicts',
        CASE WHEN category_conflicts + uom_conflicts > 0
             THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object(
            'categoryConflicts',category_conflicts,
            'uomConflicts',uom_conflicts
        )
    FROM config
    CROSS JOIN LATERAL (
        SELECT
          (SELECT count(*)
           FROM public.product_categories source_row
           JOIN public.product_categories target_row
             ON target_row.company_id=config.target_company_id
            AND lower(regexp_replace(btrim(target_row.category_name),
                                     '\s+',' ','g'))=
                lower(regexp_replace(btrim(source_row.category_name),
                                     '\s+',' ','g'))
            AND upper(btrim(target_row.category_code))<>
                upper(btrim(source_row.category_code))
           WHERE source_row.company_id=config.source_company_id)
             AS category_conflicts,
          (SELECT count(*)
           FROM public.uoms source_row
           JOIN public.uoms target_row
             ON target_row.company_id=config.target_company_id
            AND lower(regexp_replace(btrim(target_row.name),'\s+',' ','g'))=
                lower(regexp_replace(btrim(source_row.name),'\s+',' ','g'))
            AND upper(btrim(target_row.code))<>upper(btrim(source_row.code))
           WHERE source_row.company_id=config.source_company_id)
             AS uom_conflicts
    ) scope

    UNION ALL

    SELECT
        'source_clone_inventory','INFO',jsonb_build_object(
            'categories',(SELECT count(*) FROM public.product_categories
                          WHERE company_id=config.source_company_id),
            'uoms',(SELECT count(*) FROM public.uoms
                    WHERE company_id=config.source_company_id),
            'products',(SELECT count(*) FROM public.products
                        WHERE company_id=config.source_company_id),
            'productUoms',(SELECT count(*) FROM public.product_uoms
                           WHERE company_id=config.source_company_id),
            'bundles',(SELECT count(*) FROM public.products
                       WHERE company_id=config.source_company_id AND is_bundle),
            'bundleItems',(SELECT count(*) FROM public.product_bundle_items
                           WHERE company_id=config.source_company_id),
            'activeTaxVersions',(
                SELECT count(*) FROM public.tax_rule_versions
                WHERE company_id=config.source_company_id AND status='ACTIVE'
                  AND effective_from<=clock_timestamp()
                  AND (effective_to IS NULL OR effective_to>clock_timestamp())),
            'globalPricelists',(SELECT count(*) FROM public.pricelists
                                WHERE company_id=config.source_company_id
                                  AND scope='GLOBAL'),
            'globalPricelistRules',(
                SELECT count(*) FROM public.pricelist_rules rule
                JOIN public.pricelists pricelist
                  ON pricelist.company_id=rule.company_id
                 AND pricelist.id=rule.pricelist_id
                WHERE rule.company_id=config.source_company_id
                  AND pricelist.scope='GLOBAL'),
            'sharedImageUrls',(SELECT count(*) FROM public.products
                               WHERE company_id=config.source_company_id
                                 AND image_url IS NOT NULL),
            'excludedCustomerPricelists',(
                SELECT count(*) FROM public.pricelists
                WHERE company_id=config.source_company_id
                  AND scope='CUSTOMER'),
            'excludedProductSupplierLinks',(
                SELECT count(*) FROM public.product_suppliers
                WHERE company_id=config.source_company_id)
        )
    FROM config

    UNION ALL

    SELECT
        'clone_boundary','INFO',jsonb_build_object(
            'included',jsonb_build_array(
                'Product Category','UOM','Tax Rule and current version',
                'Product','Product-UOM price/barcode/weight','Bundle composition',
                'Global Pricelist and rules'),
            'excluded',jsonb_build_array(
                'Stock/FIFO/Opening Balance','transactions and journals',
                'Customer and Customer Pricelist','Supplier and Product-Supplier',
                'Store/Warehouse/Terminal','user and access','feature entitlement'),
            'imagePolicy','Copy HTTPS image_url reference; binary object is not duplicated'
        )
    FROM config
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1
    WHEN 'REVIEW' THEN 2
    WHEN 'PASS' THEN 3
    ELSE 4
END,check_name;
