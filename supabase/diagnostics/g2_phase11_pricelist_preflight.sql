-- G2 phase 11 preflight: canonical Sales Pricelist readiness.
-- SAFETY: SELECT-only; aggregate counts/schema metadata only.

WITH expected_tables(table_name) AS (
    VALUES ('pricelists'),('pricelist_store_assignments'),('pricelist_rules')
), expected_sales_detail_columns(column_name) AS (
    VALUES
        ('base_unit_price'),('pricelist_id'),('pricelist_rule_id'),
        ('resolved_unit_price'),('line_discount_type'),
        ('line_discount_input'),('line_discount_amount'),
        ('allocated_order_discount_amount'),('unit_price_after_discount'),
        ('line_total'),('pricing_resolved_at')
), product_sales_readiness AS (
    SELECT p.id,p.company_id,
           count(pu.id) FILTER (
               WHERE pu.is_active AND pu.sales_allowed
                 AND pu.sale_price IS NOT NULL AND pu.sale_price >= 0
           ) AS valid_sales_uoms
    FROM public.products p
    LEFT JOIN public.product_uoms pu
      ON pu.company_id=p.company_id AND pu.product_id=p.id
    WHERE p.is_active
    GROUP BY p.id,p.company_id
), checks AS (
    SELECT 'g2_phase10_dependency'::TEXT check_name,
           CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
           jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations WHERE version='20260722040000'

    UNION ALL
    SELECT 'canonical_pricelist_schema_state','INFO',jsonb_build_object(
        'missing_tables',COALESCE(
            jsonb_agg(e.table_name ORDER BY e.table_name)
                FILTER (WHERE c.oid IS NULL),'[]'::jsonb
        ))
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname='public'
    LEFT JOIN pg_class c ON c.relnamespace=n.oid AND c.relname=e.table_name
                         AND c.relkind IN ('r','p')

    UNION ALL
    SELECT 'sales_detail_pricing_snapshot_state','INFO',jsonb_build_object(
        'missing_columns',COALESCE(
            jsonb_agg(e.column_name ORDER BY e.column_name)
                FILTER (WHERE c.column_name IS NULL),'[]'::jsonb
        ))
    FROM expected_sales_detail_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema='public' AND c.table_name='sales_details'
     AND c.column_name=e.column_name

    UNION ALL
    SELECT 'active_products_without_valid_sales_uom',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('product_count',count(*))
    FROM product_sales_readiness WHERE valid_sales_uoms=0

    UNION ALL
    SELECT 'active_sales_uom_inventory','INFO',jsonb_build_object(
        'rows',count(*),'products',count(DISTINCT product_id),
        'companies',count(DISTINCT company_id)
    ) FROM public.product_uoms
    WHERE is_active AND sales_allowed AND sale_price IS NOT NULL

    UNION ALL
    SELECT 'customer_inventory','INFO',jsonb_build_object(
        'customers',count(*),
        'active_regular_customers',count(*) FILTER (
            WHERE is_active AND NOT is_system_customer
        ),
        'customer_groups',count(DISTINCT COALESCE(parent_customer_id,id))
            FILTER (WHERE NOT is_system_customer),
        'system_walk_in',count(*) FILTER (WHERE is_system_customer)
    ) FROM public.customers

    UNION ALL
    SELECT 'active_customer_invalid_category',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
           jsonb_build_object('row_count',count(*))
    FROM public.customers c
    LEFT JOIN public.customer_categories cc
      ON cc.company_id=c.company_id AND cc.id=c.customer_category_id
    WHERE c.is_active AND (cc.id IS NULL OR NOT cc.is_active)

    UNION ALL
    SELECT 'sales_history_inventory','INFO',jsonb_build_object(
        'sales_headers',(SELECT count(*) FROM public.sales_headers),
        'sales_details',(SELECT count(*) FROM public.sales_details),
        'companies_with_sales',(
            SELECT count(DISTINCT company_id) FROM public.sales_headers
        )
    )

    UNION ALL
    SELECT 'legacy_sales_detail_price_invariant',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
           jsonb_build_object('invalid_rows',count(*))
    FROM public.sales_details
    WHERE qty <= 0 OR price < 0 OR subtotal < 0

    UNION ALL
    SELECT 'active_company_pricelist_backfill_scope','BACKFILL',
           jsonb_build_object(
               'active_companies',count(*),
               'global_defaults_to_provision',count(*)
           )
    FROM public.companies WHERE status='ACTIVE'

    UNION ALL
    SELECT 'direct_sales_detail_write_privilege','INFO',jsonb_build_object(
        'authenticated_insert',has_table_privilege(
            'authenticated','public.sales_details','INSERT'
        ),
        'authenticated_update',has_table_privilege(
            'authenticated','public.sales_details','UPDATE'
        ),
        'authenticated_delete',has_table_privilege(
            'authenticated','public.sales_details','DELETE'
        )
    )
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'BACKFILL' THEN 3
    WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
