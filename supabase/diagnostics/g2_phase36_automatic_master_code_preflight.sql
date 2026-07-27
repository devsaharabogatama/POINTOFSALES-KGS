-- G2 phase 36 preflight: automatic hidden master-code readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes business names/codes.
--
-- DECISION:
-- - UUID remains the canonical system identity.
-- - Product SKU, Customer code, COA account code, Tax code, barcode, and
--   Supplier-owned Product code remain business-facing.
-- - The eight master identities below receive immutable server-generated
--   technical codes for new rows; existing codes remain unchanged.

WITH required_versions(version) AS (
    VALUES ('20260723190000')
), target_columns(table_name,column_name,name_column,prefix) AS (
    VALUES
        ('product_categories','category_code','category_name','CAT'),
        ('uoms','code','name','UOM'),
        ('warehouses','code','name','WH'),
        ('suppliers','supplier_code','supplier_name','SUP'),
        ('customer_categories','category_code','category_name','CC'),
        ('pricelists','code','name','PL'),
        ('payment_methods','payment_method_code','payment_method_name','PAY'),
        ('transaction_categories','category_code','category_name','TC')
), normalized_master AS (
    SELECT 'PRODUCT_CATEGORY'::TEXT AS entity_type,company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g')) AS normalized_name,
        category_code AS technical_code,'CAT'::TEXT AS expected_prefix
    FROM public.product_categories
    UNION ALL
    SELECT 'UOM',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g')),code,'UOM'
    FROM public.uoms
    UNION ALL
    SELECT 'WAREHOUSE',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g')),code,'WH'
    FROM public.warehouses
    UNION ALL
    SELECT 'SUPPLIER',company_id,
        lower(regexp_replace(btrim(supplier_name),'\s+',' ','g')),
        supplier_code,'SUP'
    FROM public.suppliers
    UNION ALL
    SELECT 'CUSTOMER_CATEGORY',company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g')),
        category_code,'CC'
    FROM public.customer_categories
    UNION ALL
    SELECT 'PRICELIST',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g')),code,'PL'
    FROM public.pricelists
    UNION ALL
    SELECT 'PAYMENT_METHOD',company_id,
        lower(regexp_replace(btrim(payment_method_name),'\s+',' ','g')),
        payment_method_code,'PAY'
    FROM public.payment_methods
    UNION ALL
    SELECT 'TRANSACTION_CATEGORY',company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g')),
        category_code,'TC'
    FROM public.transaction_categories
), expected_unique_name_indexes(index_name) AS (
    VALUES
        ('uq_product_categories_company_normalized_name'),
        ('uq_uoms_company_normalized_name'),
        ('uq_warehouses_company_normalized_name'),
        ('uq_suppliers_company_normalized_name'),
        ('uq_customer_categories_company_normalized_name'),
        ('uq_pricelists_company_normalized_name'),
        ('uq_payment_methods_company_normalized_name'),
        ('uq_transaction_categories_company_normalized_name')
), checks AS (
    SELECT
        'g2_phase33_dependency'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL)=0
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
    LEFT JOIN private.kgs_schema_migrations m ON m.version=r.version

    UNION ALL

    SELECT
        'automatic_code_target_schema',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected_columns',count(*),
            'missing_columns',COALESCE(
                jsonb_agg(t.table_name||'.'||t.column_name ORDER BY t.table_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM target_columns t
    LEFT JOIN information_schema.columns c
      ON c.table_schema='public'
     AND c.table_name=t.table_name
     AND c.column_name=t.column_name

    UNION ALL

    SELECT
        'normalized_master_name_uniqueness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT entity_type,company_id,normalized_name
        FROM normalized_master
        GROUP BY entity_type,company_id,normalized_name
        HAVING count(*)>1
    ) duplicate_groups

    UNION ALL

    SELECT
        'blank_master_name_or_code',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM normalized_master
    WHERE normalized_name='' OR btrim(COALESCE(technical_code,''))=''

    UNION ALL

    SELECT
        'required_normalized_name_index',
        CASE WHEN count(*) FILTER (WHERE i.indexname IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected_indexes',count(*),
            'missing_indexes',COALESCE(
                jsonb_agg(e.index_name ORDER BY e.index_name)
                    FILTER (WHERE i.indexname IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_unique_name_indexes e
    LEFT JOIN pg_indexes i
      ON i.schemaname='public' AND i.indexname=e.index_name

    UNION ALL

    SELECT
        'existing_automatic_prefix_inventory',
        'INFO',
        jsonb_build_object(
            'target_rows',count(*),
            'already_matching_generated_format',count(*) FILTER (
                WHERE upper(technical_code) ~
                    ('^'||expected_prefix||'-[0-9]{6,}$')
            ),
            'legacy_codes_to_preserve',count(*) FILTER (
                WHERE upper(technical_code) !~
                    ('^'||expected_prefix||'-[0-9]{6,}$')
            )
        )
    FROM normalized_master

    UNION ALL

    SELECT
        'system_owned_target_inventory',
        'INFO',
        jsonb_build_object(
            'customer_categories',(
                SELECT count(*) FROM public.customer_categories
                WHERE is_system_category
            ),
            'transaction_categories',(
                SELECT count(*) FROM public.transaction_categories
                WHERE is_system_default
            ),
            'internal_payment_methods',(
                SELECT count(*) FROM public.payment_methods
                WHERE method_type IN ('CUSTOMER_BALANCE','KETUL_OFFSET')
            )
        )

    UNION ALL

    SELECT
        'dependent_code_snapshot_inventory',
        'INFO',
        jsonb_build_object(
            'sales_payment_code_snapshots',(
                SELECT count(*) FROM public.sales_payments
                WHERE payment_method_code_snapshot IS NOT NULL
            ),
            'journal_account_code_snapshots',(
                SELECT count(*) FROM public.journal_entries
                WHERE account_code_snapshot IS NOT NULL
            ),
            'product_legacy_uom_rows',(
                SELECT count(*) FROM public.products
                WHERE NULLIF(btrim(uom),'') IS NOT NULL
            )
        )

    UNION ALL

    SELECT
        'automatic_code_runtime_state',
        'INFO',
        jsonb_build_object(
            'counter_table_exists',
                to_regclass('private.master_code_counters') IS NOT NULL,
            'allocator_exists',EXISTS (
                SELECT 1
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid=p.pronamespace
                WHERE n.nspname='private'
                  AND p.proname='allocate_master_code'
            ),
            'automatic_code_triggers',(
                SELECT count(*)
                FROM pg_trigger tg
                JOIN pg_class c ON c.oid=tg.tgrelid
                JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='public'
                  AND tg.tgname LIKE 'g2_automatic_%_code'
                  AND NOT tg.tgisinternal
            )
        )

    UNION ALL

    SELECT
        'nonterminal_import_job_inventory',
        'INFO',
        jsonb_build_object(
            'job_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.master_import_jobs
    WHERE status NOT IN (
        'COMPLETED','COMPLETED_WITH_ERRORS','FAILED','CANCELED'
    )
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'BACKFILL' THEN 3
    WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
