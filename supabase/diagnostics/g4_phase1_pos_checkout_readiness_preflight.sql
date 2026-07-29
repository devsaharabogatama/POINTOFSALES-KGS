-- G4 phase 1 preflight: POS session and server-authoritative checkout readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and schema/routine state only.
-- - Does not open checkout, create a session, reserve/deduct stock, or sync PWA.

WITH required_versions(version) AS (
    VALUES
        ('20260722100000'), -- reusable Customer Pricelist
        ('20260722120000'), -- Payment Method
        ('20260723070000'), -- private Tax resolver/calculator
        ('20260729010000')  -- Bundle foundation / G3 core boundary
), expected_session_columns(column_name) AS (
    VALUES
        ('sales_warehouse_id'),
        ('opening_cash_actual'),
        ('closing_cash_actual'),
        ('opening_stock_snapshot_at'),
        ('closing_stock_snapshot_at'),
        ('master_version'),
        ('updated_at')
), expected_sales_header_columns(column_name) AS (
    VALUES
        ('document_status'),
        ('client_transaction_id'),
        ('posting_idempotency_key'),
        ('sales_warehouse_id'),
        ('grand_total_before_rounding'),
        ('rounding_direction'),
        ('rounding_increment'),
        ('rounding_adjustment'),
        ('grand_total_after_rounding'),
        ('receipt_snapshot'),
        ('master_version'),
        ('posted_at'),
        ('posted_by')
), expected_sales_detail_columns(column_name) AS (
    VALUES
        ('product_uom_id'),
        ('sale_uom_id'),
        ('sale_uom_name_snapshot'),
        ('uom_factor_to_base_snapshot'),
        ('quantity_base'),
        ('product_sku_snapshot'),
        ('product_name_snapshot'),
        ('fifo_cost_total')
), checkout_routines AS (
    SELECT
        p.oid,
        p.proname,
        p.prosrc,
        has_function_privilege('authenticated',p.oid,'EXECUTE')
            AS authenticated_execute
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'create_sales_transaction',
          'private_create_sales_transaction_g1_legacy'
      )
), store_readiness AS (
    SELECT
        s.company_id,
        s.id AS store_id,
        EXISTS (
            SELECT 1
            FROM public.pos_terminals pt
            WHERE pt.company_id = s.company_id
              AND pt.store_id = s.id
              AND pt.status = 'ACTIVE'
        ) AS has_active_terminal,
        EXISTS (
            SELECT 1
            FROM public.warehouses w
            WHERE w.company_id = s.company_id
              AND w.is_active
              AND w.is_sale_source
              AND (w.store_id = s.id OR w.store_id IS NULL)
        ) AS has_sale_source_warehouse,
        EXISTS (
            SELECT 1
            FROM public.payment_methods pm
            WHERE pm.company_id = s.company_id
              AND pm.is_active
              AND pm.effective_from <= clock_timestamp()
              AND (
                  pm.effective_to IS NULL
                  OR pm.effective_to >= clock_timestamp()
              )
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments psa
                      WHERE psa.company_id = pm.company_id
                        AND psa.payment_method_id = pm.id
                        AND psa.store_id = s.id
                  )
              )
        ) AS has_eligible_payment_method
    FROM public.stores s
    JOIN public.companies c ON c.id = s.company_id
    WHERE c.status = 'ACTIVE'
      AND s.status = 'ACTIVE'
), active_product_readiness AS (
    SELECT
        p.company_id,
        p.id,
        p.is_bundle,
        EXISTS (
            SELECT 1
            FROM public.product_uoms pu
            JOIN public.uoms u
              ON u.company_id = pu.company_id
             AND u.id = pu.uom_id
            WHERE pu.company_id = p.company_id
              AND pu.product_id = p.id
              AND pu.is_active
              AND pu.sales_allowed
              AND pu.sale_price IS NOT NULL
              AND pu.sale_price >= 0
              AND u.is_active
        ) AS has_sales_uom,
        EXISTS (
            SELECT 1
            FROM public.product_uoms pu
            JOIN public.uoms u
              ON u.company_id = pu.company_id
             AND u.id = pu.uom_id
            WHERE pu.company_id = p.company_id
              AND pu.product_id = p.id
              AND pu.uom_id = p.uom_id
              AND pu.factor_to_base = 1
              AND pu.is_active
              AND u.is_active
        ) AS has_base_uom,
        EXISTS (
            SELECT 1
            FROM public.product_bundle_items bi
            WHERE bi.company_id = p.company_id
              AND bi.bundle_id = p.id
        ) AS has_bundle_component
    FROM public.products p
    WHERE p.is_active
), checks AS (
    SELECT
        'g4_pos_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'legacy_checkout_browser_execution',
        CASE WHEN count(*) FILTER (
            WHERE proname = 'create_sales_transaction'
              AND authenticated_execute
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'public_wrapper_rows',count(*) FILTER (
                WHERE proname = 'create_sales_transaction'
            ),
            'authenticated_executable_rows',count(*) FILTER (
                WHERE proname = 'create_sales_transaction'
                  AND authenticated_execute
            )
        )
    FROM checkout_routines

    UNION ALL

    SELECT
        'legacy_checkout_server_authority_contract',
        CASE WHEN count(*) FILTER (
            WHERE proname = 'private_create_sales_transaction_g1_legacy'
              AND (
                  prosrc ILIKE '%v_detail_rec.price%'
                  OR prosrc ILIKE '%v_detail_rec.cogs_unit%'
                  OR prosrc ILIKE '%p_grand_total%'
              )
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'legacy_routine_rows',count(*) FILTER (
                WHERE proname = 'private_create_sales_transaction_g1_legacy'
            ),
            'client_value_authority_rows',count(*) FILTER (
                WHERE proname = 'private_create_sales_transaction_g1_legacy'
                  AND (
                      prosrc ILIKE '%v_detail_rec.price%'
                      OR prosrc ILIKE '%v_detail_rec.cogs_unit%'
                      OR prosrc ILIKE '%p_grand_total%'
                  )
            ),
            'routines_writing_stock_movement',count(*) FILTER (
                WHERE prosrc ILIKE '%stock_movements%'
            ),
            'routines_using_fifo',count(*) FILTER (
                WHERE prosrc ILIKE '%product_batches%'
            )
        )
    FROM checkout_routines

    UNION ALL

    SELECT
        'active_store_operational_readiness',
        CASE WHEN count(*) FILTER (
            WHERE NOT has_active_terminal
               OR NOT has_sale_source_warehouse
               OR NOT has_eligible_payment_method
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'active_stores',count(*),
            'stores_without_active_terminal',count(*) FILTER (
                WHERE NOT has_active_terminal
            ),
            'stores_without_sale_source_warehouse',count(*) FILTER (
                WHERE NOT has_sale_source_warehouse
            ),
            'stores_without_eligible_payment_method',count(*) FILTER (
                WHERE NOT has_eligible_payment_method
            )
        )
    FROM store_readiness

    UNION ALL

    SELECT
        'active_product_sales_readiness',
        CASE WHEN count(*) FILTER (
            WHERE NOT has_sales_uom
               OR (NOT is_bundle AND NOT has_base_uom)
               OR (is_bundle AND NOT has_bundle_component)
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_products',count(*),
            'without_sales_uom',count(*) FILTER (WHERE NOT has_sales_uom),
            'stock_products_without_base_uom',count(*) FILTER (
                WHERE NOT is_bundle AND NOT has_base_uom
            ),
            'bundles_without_component',count(*) FILTER (
                WHERE is_bundle AND NOT has_bundle_component
            )
        )
    FROM active_product_readiness

    UNION ALL

    SELECT
        'active_company_walk_in_customer_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.customers cu
          WHERE cu.company_id = c.id
            AND cu.is_active
            AND cu.is_system_customer
            AND upper(btrim(cu.code)) = 'WALK-IN'
      )

    UNION ALL

    SELECT
        'duplicate_open_cashier_session',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('cashier_count',count(*))
    FROM (
        SELECT company_id,cashier_id
        FROM public.cashier_sessions
        WHERE status = 'OPEN'::public.session_status
        GROUP BY company_id,cashier_id
        HAVING count(*) > 1
    ) duplicate_open

    UNION ALL

    SELECT
        'open_session_without_active_cashier_assignment',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('session_count',count(*))
    FROM public.cashier_sessions cs
    WHERE cs.status = 'OPEN'::public.session_status
      AND NOT EXISTS (
          SELECT 1
          FROM public.store_memberships sm
          WHERE sm.company_id = cs.company_id
            AND sm.store_id = cs.store_id
            AND sm.user_id = cs.cashier_id
            AND sm.status = 'ACTIVE'
            AND sm.role_code = 'CASHIER'
      )

    UNION ALL

    SELECT
        'cashier_session_runtime_schema',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_session_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'cashier_sessions'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'sales_header_runtime_schema',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_sales_header_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_headers'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'sales_detail_runtime_schema',
        'INFO',
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_sales_detail_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'sales_details'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'canonical_pos_runtime_state',
        'INFO',
        jsonb_build_object(
            'save_draft_rpc_exists',
                to_regprocedure('public.save_pos_sale_draft(jsonb)') IS NOT NULL,
            'post_sale_rpc_exists',
                to_regprocedure('public.post_pos_sale(uuid,bigint,uuid)')
                    IS NOT NULL,
            'open_session_rpc_exists',
                to_regprocedure('public.open_cashier_session(uuid,uuid,numeric)')
                    IS NOT NULL,
            'close_session_rpc_exists',
                to_regprocedure('public.close_cashier_session(uuid,bigint,numeric)')
                    IS NOT NULL,
            'sale_fifo_allocation_table_exists',
                to_regclass('public.sale_fifo_allocations') IS NOT NULL,
            'bundle_sale_allocation_table_exists',
                to_regclass('public.bundle_sale_allocations') IS NOT NULL
        )

    UNION ALL

    SELECT
        'required_private_resolver_state',
        CASE WHEN count(*) FILTER (
            WHERE p.proname IS NULL
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.routine_name ORDER BY r.routine_name)
                    FILTER (WHERE p.proname IS NULL),
                '[]'::jsonb
            )
        )
    FROM (
        VALUES
            ('resolve_product_tax_rule'),
            ('calculate_tax_group'),
            ('resolve_bundle_components')
    ) r(routine_name)
    LEFT JOIN pg_proc p
      ON p.proname = r.routine_name
     AND p.pronamespace = 'private'::regnamespace

    UNION ALL

    SELECT
        'server_price_resolver_state',
        CASE WHEN count(*) = 0 THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object('resolver_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname IN (
          'resolve_sale_unit_price',
          'resolve_pos_sale_price'
      )

    UNION ALL

    SELECT
        'invalid_existing_sales_value',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_headers
    WHERE subtotal < 0
       OR item_discount < 0
       OR global_discount < 0
       OR grand_total < 0
       OR paid_amount < 0
       OR sisa_piutang < 0

    UNION ALL

    SELECT
        'invalid_existing_sales_detail_quantity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_details
    WHERE qty <= 0

    UNION ALL

    SELECT
        'invalid_existing_sales_payment_amount',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments
    WHERE amount <= 0

    UNION ALL

    SELECT
        'generated_sale_without_stock_movement',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('detail_count',count(*))
    FROM public.sales_details sd
    JOIN public.sales_headers sh
      ON sh.company_id = sd.company_id
     AND sh.id = sd.sales_id
    JOIN public.products p
      ON p.company_id = sd.company_id
     AND p.id = sd.product_id
    WHERE sh.invoice_status = 'GENERATED'::public.invoice_status
      AND NOT p.is_bundle
      AND NOT EXISTS (
          SELECT 1
          FROM public.stock_movements sm
          WHERE sm.company_id = sd.company_id
            AND sm.product_id = sd.product_id
            AND sm.warehouse_id = sd.warehouse_id
            AND sm.reference_table = 'sales_headers'
            AND sm.reference_id = sd.sales_id
            AND sm.movement_type = 'SALE'::public.stock_movement_type
            AND sm.movement_status = 'POSTED'
      )

    UNION ALL

    SELECT
        'generated_sale_without_financial_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers sh
    WHERE sh.invoice_status = 'GENERATED'::public.invoice_status
      AND NOT EXISTS (
          SELECT 1
          FROM public.financial_events fe
          WHERE fe.company_id = sh.company_id
            AND fe.source_table = 'sales_headers'
            AND fe.source_id = sh.id
            AND fe.event_type = 'SALE_POSTED'::public.event_type
      )

    UNION ALL

    SELECT
        'browser_direct_sales_write_boundary',
        CASE WHEN
            NOT has_table_privilege(
                'authenticated','public.cashier_sessions',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.sales_details',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            )
        THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'cashier_sessions_write',has_table_privilege(
                'authenticated','public.cashier_sessions',
                'INSERT,UPDATE,DELETE'
            ),
            'sales_headers_write',has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            ),
            'sales_details_write',has_table_privilege(
                'authenticated','public.sales_details',
                'INSERT,UPDATE,DELETE'
            ),
            'sales_payments_write',has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'pos_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'active_stores',(
                SELECT count(*) FROM public.stores WHERE status = 'ACTIVE'
            ),
            'active_terminals',(
                SELECT count(*) FROM public.pos_terminals
                WHERE status = 'ACTIVE'
            ),
            'open_sessions',(
                SELECT count(*) FROM public.cashier_sessions
                WHERE status = 'OPEN'::public.session_status
            ),
            'sales_headers',(SELECT count(*) FROM public.sales_headers),
            'sales_details',(SELECT count(*) FROM public.sales_details),
            'sales_payments',(SELECT count(*) FROM public.sales_payments),
            'active_payment_methods',(
                SELECT count(*) FROM public.payment_methods WHERE is_active
            ),
            'active_pricelists',(
                SELECT count(*) FROM public.pricelists WHERE is_active
            ),
            'positive_stock_pairs',(
                SELECT count(*) FROM public.product_stocks WHERE stock_qty > 0
            ),
            'active_bundles',(
                SELECT count(*) FROM public.products
                WHERE is_active AND is_bundle
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
        WHEN 'SETUP' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
