-- G2 phase 35 preflight: fixed-contract Import/Export expansion readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no customer, supplier, bank, or contact data.
-- - Run the entire file in Supabase SQL Editor and export the final result.

WITH required_versions(version) AS (
    VALUES ('20260723190000')
), expected_tables(table_name) AS (
    VALUES
        ('product_categories'),('uoms'),('warehouses'),('products'),
        ('product_uoms'),('suppliers'),('product_suppliers'),
        ('customer_categories'),('customers'),('pricelists'),
        ('pricelist_store_assignments'),('pricelist_rules'),
        ('payment_methods'),('payment_method_store_assignments'),
        ('chart_of_accounts'),('transaction_categories'),
        ('transaction_account_rules'),
        ('company_account_function_fallbacks'),('tax_rules'),
        ('tax_rule_versions'),('master_import_jobs'),('master_import_rows')
), expected_routines(routine_name) AS (
    VALUES
        ('save_product_with_uoms'),('save_supplier'),
        ('save_product_supplier'),('save_customer_category'),
        ('save_customer_with_pricelist'),
        ('save_reusable_pricelist_with_rules'),('save_payment_method'),
        ('save_chart_of_account'),('save_transaction_category'),
        ('save_transaction_account_rule'),
        ('save_company_account_function_fallback'),('save_tax_rule')
), normalized_identity AS (
    SELECT 'PRODUCT_CATEGORY'::TEXT AS entity_type,company_id,
        upper(regexp_replace(btrim(category_code),'\s+',' ','g')) AS normalized_code,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g')) AS normalized_name
    FROM public.product_categories
    UNION ALL
    SELECT 'UOM',company_id,
        upper(regexp_replace(btrim(code),'\s+',' ','g')),
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.uoms
    UNION ALL
    SELECT 'WAREHOUSE',company_id,
        upper(regexp_replace(btrim(code),'\s+',' ','g')),
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.warehouses
    UNION ALL
    SELECT 'SUPPLIER',company_id,
        upper(regexp_replace(btrim(supplier_code),'\s+',' ','g')),
        lower(regexp_replace(btrim(supplier_name),'\s+',' ','g'))
    FROM public.suppliers
    UNION ALL
    SELECT 'PRODUCT',company_id,
        upper(regexp_replace(btrim(sku),'\s+',' ','g')) AS normalized_code,
        lower(regexp_replace(btrim(name),'\s+',' ','g')) AS normalized_name
    FROM public.products
    UNION ALL
    SELECT 'CUSTOMER_CATEGORY',company_id,
        upper(regexp_replace(btrim(category_code),'\s+',' ','g')),
        lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
    FROM public.customer_categories
    UNION ALL
    SELECT 'CUSTOMER',company_id,
        upper(regexp_replace(btrim(code),'\s+',' ','g')),
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.customers
    UNION ALL
    SELECT 'PRICELIST',company_id,
        upper(regexp_replace(btrim(code),'\s+',' ','g')),
        lower(regexp_replace(btrim(name),'\s+',' ','g'))
    FROM public.pricelists
    UNION ALL
    SELECT 'PAYMENT_METHOD',company_id,
        upper(regexp_replace(btrim(payment_method_code),'\s+',' ','g')),
        lower(regexp_replace(btrim(payment_method_name),'\s+',' ','g'))
    FROM public.payment_methods
    UNION ALL
    SELECT 'CHART_OF_ACCOUNT',company_id,
        upper(regexp_replace(btrim(account_code),'\s+',' ','g')),
        lower(regexp_replace(btrim(account_name),'\s+',' ','g'))
    FROM public.chart_of_accounts
    UNION ALL
    SELECT 'TRANSACTION_CATEGORY',company_id,
        upper(regexp_replace(btrim(category_code),'\s+',' ','g')),
        lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
    FROM public.transaction_categories
    UNION ALL
    SELECT 'TAX_RULE',company_id,
        upper(regexp_replace(btrim(tax_code),'\s+',' ','g')),
        lower(regexp_replace(btrim(tax_name),'\s+',' ','g'))
    FROM public.tax_rules
), product_uom_summary AS (
    SELECT p.company_id,p.id,
        count(pu.id) AS uom_rows,
        count(pu.id) FILTER (
            WHERE pu.uom_id=p.uom_id AND pu.factor_to_base=1
        ) AS valid_base_rows,
        count(pu.id) FILTER (
            WHERE pu.uom_id=p.weight_reference_uom_id
        ) AS weight_reference_rows,
        count(pu.id) FILTER (
            WHERE pu.is_active AND pu.sales_allowed
        ) AS sales_rows,
        count(pu.id) FILTER (
            WHERE pu.is_active AND pu.purchase_allowed
        ) AS purchase_rows
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id=p.company_id AND pu.product_id=p.id
    GROUP BY p.company_id,p.id
), checks AS (
    SELECT 'g2_phase33_dependency'::TEXT AS check_name,
        CASE WHEN count(*) FILTER(WHERE m.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(r.version ORDER BY r.version)
                FILTER(WHERE m.version IS NULL),'[]'::JSONB)
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version=r.version

    UNION ALL

    SELECT 'full_import_schema_state','INFO',jsonb_build_object(
        'expected_tables',count(*),
        'missing_tables',COALESCE(jsonb_agg(e.table_name ORDER BY e.table_name)
            FILTER(WHERE to_regclass('public.'||e.table_name) IS NULL),'[]'::JSONB)
    ) FROM expected_tables e

    UNION ALL

    SELECT 'canonical_guarded_rpc_state',
        CASE WHEN count(*) FILTER(WHERE p.proname IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected_routine_names',count(*),
            'missing_names',COALESCE(jsonb_agg(e.routine_name ORDER BY e.routine_name)
                FILTER(WHERE p.proname IS NULL),'[]'::JSONB)
        )
    FROM expected_routines e
    LEFT JOIN (
        SELECT p.proname
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public'
        GROUP BY p.proname
    ) p ON p.proname=e.routine_name

    UNION ALL

    SELECT 'duplicate_fixed_import_code',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT entity_type,company_id,normalized_code
        FROM normalized_identity
        GROUP BY entity_type,company_id,normalized_code
        HAVING count(*)>1
    ) duplicate_groups

    UNION ALL

    SELECT 'duplicate_fixed_import_name',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT entity_type,company_id,normalized_name
        FROM normalized_identity
        GROUP BY entity_type,company_id,normalized_name
        HAVING count(*)>1
    ) duplicate_groups

    UNION ALL

    SELECT 'ambiguous_reference_name_or_code',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('ambiguous_groups',count(*))
    FROM (
        SELECT company_id,reference_type,value
        FROM (
            SELECT company_id,'STORE_CODE'::TEXT AS reference_type,
                upper(regexp_replace(btrim(store_code),'\s+',' ','g')) AS value
            FROM public.stores
            UNION ALL
            SELECT company_id,'PRODUCT_CATEGORY_NAME',
                lower(regexp_replace(btrim(category_name),'\s+',' ','g'))
            FROM public.product_categories
            UNION ALL
            SELECT company_id,'UOM_NAME',
                lower(regexp_replace(btrim(name),'\s+',' ','g'))
            FROM public.uoms
            UNION ALL
            SELECT company_id,'SUPPLIER_NAME',
                lower(regexp_replace(btrim(supplier_name),'\s+',' ','g'))
            FROM public.suppliers
        ) reference_values
        GROUP BY company_id,reference_type,value
        HAVING count(*)>1
    ) ambiguous

    UNION ALL

    SELECT 'invalid_product_group_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM product_uom_summary s
    JOIN public.products p ON p.company_id=s.company_id AND p.id=s.id
    WHERE s.uom_rows=0 OR s.valid_base_rows<>1
       OR s.weight_reference_rows<>1 OR s.sales_rows=0
       OR (NOT p.is_bundle AND s.purchase_rows=0)
       OR p.category_id IS NULL OR p.uom_id IS NULL
       OR p.weight_reference_uom_id IS NULL OR p.weight_per_uom_kg<=0

    UNION ALL

    SELECT 'invalid_product_supplier_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_suppliers ps
    LEFT JOIN public.products p
      ON p.company_id=ps.company_id AND p.id=ps.product_id
    LEFT JOIN public.suppliers s
      ON s.company_id=ps.company_id AND s.id=ps.supplier_id
    LEFT JOIN public.product_uoms pu
      ON pu.company_id=ps.company_id AND pu.product_id=ps.product_id
     AND pu.uom_id=ps.purchase_uom_id
    WHERE p.id IS NULL OR s.id IS NULL OR pu.id IS NULL

    UNION ALL

    SELECT 'invalid_customer_import_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.customers c
    LEFT JOIN public.customer_categories cc
      ON cc.company_id=c.company_id AND cc.id=c.customer_category_id
    LEFT JOIN public.customers parent
      ON parent.company_id=c.company_id AND parent.id=c.parent_customer_id
    LEFT JOIN public.pricelists pl
      ON pl.company_id=c.company_id AND pl.id=c.default_pricelist_id
    WHERE cc.id IS NULL
       OR (c.parent_customer_id IS NOT NULL
           AND (parent.id IS NULL OR parent.parent_customer_id IS NOT NULL))
       OR (c.default_pricelist_id IS NOT NULL
           AND (pl.id IS NULL OR pl.scope<>'CUSTOMER'))

    UNION ALL

    SELECT 'invalid_pricelist_group_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT pr.id
        FROM public.pricelist_rules pr
        LEFT JOIN public.pricelists pl
          ON pl.company_id=pr.company_id AND pl.id=pr.pricelist_id
        LEFT JOIN public.products p
          ON p.company_id=pr.company_id AND p.id=pr.product_id
        LEFT JOIN public.product_uoms pu
          ON pu.company_id=pr.company_id AND pu.id=pr.product_uom_id
         AND pu.product_id=pr.product_id
        WHERE pl.id IS NULL OR p.id IS NULL OR pu.id IS NULL
        UNION ALL
        SELECT psa.id
        FROM public.pricelist_store_assignments psa
        LEFT JOIN public.pricelists pl
          ON pl.company_id=psa.company_id AND pl.id=psa.pricelist_id
        LEFT JOIN public.stores st
          ON st.company_id=psa.company_id AND st.id=psa.store_id
        WHERE pl.id IS NULL OR st.id IS NULL
    ) invalid_rows

    UNION ALL

    SELECT 'invalid_payment_store_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.payment_method_store_assignments pmsa
    LEFT JOIN public.payment_methods pm
      ON pm.company_id=pmsa.company_id AND pm.id=pmsa.payment_method_id
    LEFT JOIN public.stores st
      ON st.company_id=pmsa.company_id AND st.id=pmsa.store_id
    WHERE pm.id IS NULL OR st.id IS NULL

    UNION ALL

    SELECT 'invalid_finance_import_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT r.id FROM public.transaction_account_rules r
        LEFT JOIN public.transaction_categories tc
          ON tc.company_id=r.company_id AND tc.id=r.transaction_category_id
        LEFT JOIN public.chart_of_accounts coa
          ON coa.company_id=r.company_id AND coa.id=r.account_id
        WHERE tc.id IS NULL OR coa.id IS NULL
        UNION ALL
        SELECT f.id FROM public.company_account_function_fallbacks f
        LEFT JOIN public.chart_of_accounts coa
          ON coa.company_id=f.company_id AND coa.id=f.account_id
        WHERE coa.id IS NULL
    ) invalid_rows

    UNION ALL

    SELECT 'invalid_tax_import_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.tax_rule_versions v
    LEFT JOIN public.tax_rules r
      ON r.company_id=v.company_id AND r.id=v.tax_rule_id
    LEFT JOIN public.chart_of_accounts coa
      ON coa.company_id=v.company_id AND coa.id=v.account_id
    WHERE r.id IS NULL OR coa.id IS NULL

    UNION ALL

    SELECT 'nonterminal_import_job_inventory','INFO',jsonb_build_object(
        'job_count',count(*),
        'companies',count(DISTINCT company_id)
    ) FROM public.master_import_jobs
    WHERE status NOT IN ('COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED')

    UNION ALL

    SELECT 'full_import_master_inventory','INFO',jsonb_build_object(
        'products',(SELECT count(*) FROM public.products),
        'product_suppliers',(SELECT count(*) FROM public.product_suppliers),
        'customers',(SELECT count(*) FROM public.customers),
        'customer_categories',(SELECT count(*) FROM public.customer_categories),
        'pricelists',(SELECT count(*) FROM public.pricelists),
        'payment_methods',(SELECT count(*) FROM public.payment_methods),
        'chart_of_accounts',(SELECT count(*) FROM public.chart_of_accounts),
        'transaction_categories',(SELECT count(*) FROM public.transaction_categories),
        'tax_rules',(SELECT count(*) FROM public.tax_rules)
    )
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'BACKFILL' THEN 3
    WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
