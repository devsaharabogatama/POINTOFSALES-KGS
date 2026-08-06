Okay clearly the fun project yeah project under pen projecting original project yeah plus come on seven yeah by your planting set oh yeah hello hello hello are in same yeah plus nanti process carrying process yeah ninety chat okay clear addition yeah limapi then
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes invoice/customer data.
-- - Sales Return mutation, refund posting, stock restoration, and UI remain closed.

WITH required_versions(version) AS (
    VALUES
        ('20260729010000'), -- Bundle foundation
        ('20260729040000'), -- Cashier Session foundation
        ('20260729070000'), -- Atomic Sale runtime
        ('20260729150000'), -- Payment-leg identity
        ('20260729210000')  -- Offline Sale sync/final acknowledgement
), expected_return_tables(table_name) AS (
    VALUES
        ('sales_return_documents'),
        ('sales_return_lines'),
        ('sales_return_fifo_restorations'),
        ('sales_return_refunds'),
        ('sales_return_audit')
), expected_return_routines(routine_name) AS (
    VALUES
        ('save_sales_return_draft'),
        ('post_sales_return'),
        ('cancel_sales_return_draft'),
        ('list_returnable_sales')
), return_routine_state AS (
    SELECT
        expected.routine_name,
        EXISTS (
            SELECT 1
            FROM pg_proc routine
            WHERE routine.pronamespace = 'public'::regnamespace
              AND routine.proname = expected.routine_name
        ) AS routine_exists
    FROM expected_return_routines expected
), posted_sales AS (
    SELECT sh.*
    FROM public.sales_headers sh
    WHERE sh.document_status = 'POSTED'
), posted_line_stock AS (
    SELECT
        requirement.company_id,
        requirement.sales_id,
        requirement.sales_detail_id,
        requirement.id AS requirement_id,
        requirement.quantity_base AS required_base_qty,
        COALESCE(sum(allocation.quantity_base),0) AS allocated_base_qty
    FROM public.sale_stock_requirements requirement
    JOIN posted_sales sale
      ON sale.company_id = requirement.company_id
     AND sale.id = requirement.sales_id
    LEFT JOIN public.sale_fifo_allocations allocation
      ON allocation.company_id = requirement.company_id
     AND allocation.stock_requirement_id = requirement.id
    GROUP BY
        requirement.company_id,requirement.sales_id,
        requirement.sales_detail_id,requirement.id,
        requirement.quantity_base
), posted_payment_totals AS (
    SELECT
        sale.company_id,
        sale.id AS sales_id,
        sale.grand_total_after_rounding,
        COALESCE(sum(payment.amount) FILTER (WHERE NOT payment.is_reversal),0)
            AS payment_total
    FROM posted_sales sale
    LEFT JOIN public.sales_payments payment
      ON payment.company_id = sale.company_id
     AND payment.sales_id = sale.id
    GROUP BY sale.company_id,sale.id,sale.grand_total_after_rounding
), posted_sale_stores AS (
    SELECT DISTINCT company_id,store_id
    FROM posted_sales
), checks AS (
    SELECT
        'g4_phase25_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = required.version

    UNION ALL

    SELECT
        'canonical_sales_return_schema_state',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || expected.table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_tables',count(*),
            'missing_tables',COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER (
                        WHERE to_regclass(
                            'public.' || expected.table_name
                        ) IS NULL
                    ),
                '[]'::JSONB
            )
        )
    FROM expected_return_tables expected

    UNION ALL

    SELECT
        'canonical_sales_return_routine_state',
        CASE WHEN count(*) FILTER (WHERE NOT routine_exists) = 0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_routines',count(*),
            'missing_routines',COALESCE(
                jsonb_agg(routine_name ORDER BY routine_name)
                    FILTER (WHERE NOT routine_exists),
                '[]'::JSONB
            )
        )
    FROM return_routine_state

    UNION ALL

    SELECT
        'incomplete_posted_sale_header_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_sales sale
    WHERE sale.posting_idempotency_key IS NULL
       OR sale.sales_warehouse_id IS NULL
       OR sale.posted_session_id IS NULL
       OR sale.posted_at IS NULL
       OR sale.posted_by IS NULL
       OR sale.receipt_snapshot IS NULL
       OR sale.grand_total_before_rounding < 0
       OR sale.grand_total_after_rounding < 0

    UNION ALL

    SELECT
        'posted_sale_without_line',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_sales sale
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.sales_details detail
        WHERE detail.company_id = sale.company_id
          AND detail.sales_id = sale.id
    )

    UNION ALL

    SELECT
        'incomplete_posted_sale_line_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM public.sales_details detail
    JOIN posted_sales sale
      ON sale.company_id = detail.company_id
     AND sale.id = detail.sales_id
    WHERE detail.qty <= 0
       OR detail.quantity_base <= 0
       OR detail.product_uom_id IS NULL
       OR detail.sale_uom_id IS NULL
       OR NULLIF(btrim(detail.sale_uom_name_snapshot),'') IS NULL
       OR NULLIF(btrim(detail.product_sku_snapshot),'') IS NULL
       OR NULLIF(btrim(detail.product_name_snapshot),'') IS NULL
       OR detail.base_unit_price IS NULL
       OR detail.resolved_unit_price IS NULL
       OR detail.unit_price_after_discount IS NULL
       OR detail.line_total IS NULL
       OR detail.fifo_cost_total < 0
       OR (
            detail.tax_rule_id IS NOT NULL
            AND (
                detail.tax_rule_version IS NULL
                OR detail.tax_code_snapshot IS NULL
                OR detail.tax_name_snapshot IS NULL
                OR detail.tax_base IS NULL
                OR detail.tax_amount IS NULL
            )
       )

    UNION ALL

    SELECT
        'incomplete_posted_payment_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('payment_count',count(*))
    FROM public.sales_payments payment
    JOIN posted_sales sale
      ON sale.company_id = payment.company_id
     AND sale.id = payment.sales_id
    WHERE NOT payment.is_reversal
      AND (
          payment.amount <= 0
          OR payment.client_payment_key IS NULL
          OR payment.payment_method_id IS NULL
          OR NULLIF(btrim(payment.payment_method_code_snapshot),'') IS NULL
          OR NULLIF(btrim(payment.payment_method_name_snapshot),'') IS NULL
          OR payment.payment_method_type_snapshot IS NULL
          OR payment.settlement_route_snapshot IS NULL
      )

    UNION ALL

    SELECT
        'posted_sale_payment_total',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_payment_totals
    WHERE payment_total <> grand_total_after_rounding

    UNION ALL

    SELECT
        'posted_sale_fifo_source_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('requirement_count',count(*))
    FROM posted_line_stock
    WHERE allocated_base_qty <> required_base_qty

    UNION ALL

    SELECT
        'posted_bundle_allocation_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM public.sales_details detail
    JOIN posted_sales sale
      ON sale.company_id = detail.company_id
     AND sale.id = detail.sales_id
    JOIN public.products product
      ON product.company_id = detail.company_id
     AND product.id = detail.product_id
    WHERE product.is_bundle
      AND NOT EXISTS (
          SELECT 1
          FROM public.bundle_sale_allocations allocation
          WHERE allocation.company_id = detail.company_id
            AND allocation.sales_detail_id = detail.id
      )

    UNION ALL

    SELECT
        'nonterminal_offline_sale_submission',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('submission_count',count(*))
    FROM public.pos_offline_sale_submissions submission
    WHERE submission.status IN (
        'QUEUED','SYNCING','PROCESSING','NEEDS_CONFIRMATION','FAILED'
    )

    UNION ALL

    SELECT
        'sales_return_finance_catalog',
        CASE WHEN
            EXISTS (
                SELECT 1 FROM public.system_events
                WHERE system_key = 'SALES_RETURN' AND is_active
            )
            AND EXISTS (
                SELECT 1 FROM public.account_functions
                WHERE function_key = 'SALES_RETURN_DISCOUNT' AND is_active
            )
            THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'system_event_rows',(
                SELECT count(*) FROM public.system_events
                WHERE system_key = 'SALES_RETURN' AND is_active
            ),
            'account_function_rows',(
                SELECT count(*) FROM public.account_functions
                WHERE function_key = 'SALES_RETURN_DISCOUNT' AND is_active
            )
        )

    UNION ALL

    SELECT
        'posted_sale_company_return_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT DISTINCT sale.company_id
        FROM posted_sales sale
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.transaction_categories category
            WHERE category.company_id = sale.company_id
              AND category.system_key = 'SALES_RETURN'
              AND category.is_active
        )
    ) missing_company

    UNION ALL

    SELECT
        'posted_sale_store_return_warehouse_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('store_count',count(*))
    FROM posted_sale_stores source
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.warehouses warehouse
        WHERE warehouse.company_id = source.company_id
          AND warehouse.store_id = source.store_id
          AND warehouse.is_active
          AND warehouse.warehouse_type = 'STORE'
    )
       OR NOT EXISTS (
        SELECT 1
        FROM public.warehouses warehouse
        WHERE warehouse.company_id = source.company_id
          AND warehouse.is_active
          AND warehouse.warehouse_type = 'DAMAGED'
    )

    UNION ALL

    SELECT
        'refund_method_inventory',
        'INFO',
        jsonb_build_object(
            'cash_methods',count(*) FILTER (WHERE method_type = 'CASH'),
            'transfer_methods',count(*) FILTER (WHERE method_type = 'TRANSFER'),
            'customer_balance_methods',count(*) FILTER (
                WHERE method_type = 'CUSTOMER_BALANCE'
            ),
            'companies',count(DISTINCT company_id)
        )
    FROM public.payment_methods
    WHERE is_active
      AND effective_from <= clock_timestamp()
      AND (effective_to IS NULL OR effective_to > clock_timestamp())

    UNION ALL

    SELECT
        'browser_direct_sales_return_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sales_details','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.product_batches','INSERT,UPDATE,DELETE'
            )
            THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object(
            'sales_headers_write',has_table_privilege(
                'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
            ),
            'sales_details_write',has_table_privilege(
                'authenticated','public.sales_details','INSERT,UPDATE,DELETE'
            ),
            'sales_payments_write',has_table_privilege(
                'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
            ),
            'stock_movements_write',has_table_privilege(
                'authenticated','public.stock_movements','INSERT,UPDATE,DELETE'
            ),
            'product_batches_write',has_table_privilege(
                'authenticated','public.product_batches','INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'sales_return_source_inventory',
        'INFO',
        jsonb_build_object(
            'posted_sales',(SELECT count(*) FROM posted_sales),
            'posted_lines',(
                SELECT count(*)
                FROM public.sales_details detail
                JOIN posted_sales sale
                  ON sale.company_id = detail.company_id
                 AND sale.id = detail.sales_id
            ),
            'posted_payment_legs',(
                SELECT count(*)
                FROM public.sales_payments payment
                JOIN posted_sales sale
                  ON sale.company_id = payment.company_id
                 AND sale.id = payment.sales_id
                WHERE NOT payment.is_reversal
            ),
            'stock_requirements',(SELECT count(*) FROM posted_line_stock),
            'fifo_allocations',(
                SELECT count(*)
                FROM public.sale_fifo_allocations allocation
                JOIN posted_sales sale
                  ON sale.company_id = allocation.company_id
                 AND sale.id = allocation.sales_id
            ),
            'bundle_allocations',(
                SELECT count(*)
                FROM public.bundle_sale_allocations allocation
                JOIN posted_sales sale
                  ON sale.company_id = allocation.company_id
                 AND sale.id = allocation.sales_id
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
