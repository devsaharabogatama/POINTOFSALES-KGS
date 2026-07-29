-- G4 phase 3 preflight: canonical Sale Draft/Post runtime readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and schema/routine state only.
-- - Does not create a Sale, reserve/deduct stock, post Finance, or enable PWA.
--
-- STATUS:
-- - BLOCKER: unsafe authority or invalid live data must be closed first.
-- - SETUP: canonical runtime object is intentionally not installed yet.
-- - PASS/INFO: safe prerequisite or inventory evidence.

WITH required_versions(version) AS (
    VALUES
        ('20260722100000'), -- reusable Customer Pricelist
        ('20260722120000'), -- Payment Method
        ('20260723070000'), -- Tax resolver/calculator
        ('20260729010000'), -- Bundle foundation / G3 exit
        ('20260729040000')  -- Cashier Session foundation
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
        ('updated_at'),
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
), expected_allocation_tables(table_name) AS (
    VALUES
        ('sale_fifo_allocations'),
        ('bundle_sale_allocations')
), expected_sale_routines(schema_name,routine_name) AS (
    VALUES
        ('private','resolve_pos_sale_price'),
        ('public','save_pos_sale_draft'),
        ('public','post_pos_sale')
), legacy_checkout_routines AS (
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
), active_store_commerce AS (
    SELECT
        s.company_id,
        s.id AS store_id,
        EXISTS (
            SELECT 1
            FROM public.pricelists pl
            WHERE pl.company_id = s.company_id
              AND pl.scope = 'GLOBAL'
              AND pl.is_default
              AND pl.is_active
              AND (pl.valid_from IS NULL OR pl.valid_from <= clock_timestamp())
              AND (pl.valid_until IS NULL OR pl.valid_until >= clock_timestamp())
              AND (
                  pl.applies_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.pricelist_store_assignments psa
                      WHERE psa.company_id = pl.company_id
                        AND psa.pricelist_id = pl.id
                        AND psa.store_id = s.id
                  )
              )
        ) AS has_default_pricelist,
        EXISTS (
            SELECT 1
            FROM public.payment_methods pm
            WHERE pm.company_id = s.company_id
              AND pm.is_default
              AND pm.is_active
              AND pm.effective_from <= clock_timestamp()
              AND (pm.effective_to IS NULL
                   OR pm.effective_to >= clock_timestamp())
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments pmsa
                      WHERE pmsa.company_id = pm.company_id
                        AND pmsa.payment_method_id = pm.id
                        AND pmsa.store_id = s.id
                  )
              )
        ) AS has_default_payment_method
    FROM public.stores s
    JOIN public.companies c ON c.id = s.company_id
    WHERE c.status = 'ACTIVE'
      AND s.status = 'ACTIVE'
), active_product_readiness AS (
    SELECT
        p.company_id,
        p.id AS product_id,
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
), assigned_sales_tax_rules AS (
    SELECT DISTINCT
        p.company_id,
        COALESCE(p.sales_tax_rule_id,pc.default_sales_tax_rule_id)
            AS tax_rule_id
    FROM public.products p
    JOIN public.product_categories pc
      ON pc.company_id = p.company_id
     AND pc.id = p.category_id
    WHERE p.is_active
      AND COALESCE(
          p.sales_tax_rule_id,
          pc.default_sales_tax_rule_id
      ) IS NOT NULL
), assigned_tax_resolution AS (
    SELECT
        a.company_id,
        a.tax_rule_id,
        count(trv.id) FILTER (
            WHERE trv.status = 'ACTIVE'
              AND trv.effective_from <= clock_timestamp()
              AND (trv.effective_to IS NULL
                   OR trv.effective_to > clock_timestamp())
        ) AS current_version_rows,
        bool_and(
            tr.id IS NOT NULL
            AND tr.is_active
            AND tr.tax_scope = 'SALES'
        ) AS valid_rule_identity,
        bool_and(
            coa.id IS NULL
            OR (coa.is_active AND coa.is_postable)
        ) FILTER (
            WHERE trv.status = 'ACTIVE'
              AND trv.effective_from <= clock_timestamp()
              AND (trv.effective_to IS NULL
                   OR trv.effective_to > clock_timestamp())
        ) AS valid_current_account
    FROM assigned_sales_tax_rules a
    LEFT JOIN public.tax_rules tr
      ON tr.company_id = a.company_id
     AND tr.id = a.tax_rule_id
    LEFT JOIN public.tax_rule_versions trv
      ON trv.company_id = a.company_id
     AND trv.tax_rule_id = a.tax_rule_id
    LEFT JOIN public.chart_of_accounts coa
      ON coa.company_id = trv.company_id
     AND coa.id = trv.account_id
    GROUP BY a.company_id,a.tax_rule_id
), movement_totals AS (
    SELECT
        company_id,
        product_id,
        warehouse_id,
        sum(qty_change) AS movement_qty
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
    GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
    SELECT
        company_id,
        product_id,
        warehouse_id,
        sum(qty_remaining) AS fifo_qty
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), stock_reconciliation AS (
    SELECT
        ps.company_id,
        ps.product_id,
        ps.warehouse_id,
        ps.stock_qty,
        COALESCE(mt.movement_qty,0) AS movement_qty,
        COALESCE(ft.fifo_qty,0) AS fifo_qty
    FROM public.product_stocks ps
    LEFT JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    LEFT JOIN fifo_totals ft
      ON ft.company_id = ps.company_id
     AND ft.product_id = ps.product_id
     AND ft.warehouse_id = ps.warehouse_id
), checks AS (
    SELECT
        'g4_phase3_dependencies'::text AS check_name,
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
        'cashier_session_runtime_readiness',
        CASE WHEN
            to_regprocedure(
                'public.open_cashier_session(uuid,uuid,numeric)'
            ) IS NOT NULL
            AND to_regprocedure(
                'public.close_cashier_session(uuid,bigint,numeric)'
            ) IS NOT NULL
            AND to_regclass(
                'public.cashier_session_stock_snapshots'
            ) IS NOT NULL
        THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'open_rpc_exists',to_regprocedure(
                'public.open_cashier_session(uuid,uuid,numeric)'
            ) IS NOT NULL,
            'close_rpc_exists',to_regprocedure(
                'public.close_cashier_session(uuid,bigint,numeric)'
            ) IS NOT NULL,
            'snapshot_table_exists',to_regclass(
                'public.cashier_session_stock_snapshots'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'invalid_open_cashier_session',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('session_count',count(*))
    FROM public.cashier_sessions cs
    LEFT JOIN public.companies c ON c.id = cs.company_id
    LEFT JOIN public.stores s
      ON s.company_id = cs.company_id AND s.id = cs.store_id
    LEFT JOIN public.pos_terminals pt
      ON pt.company_id = cs.company_id AND pt.id = cs.pos_id
    LEFT JOIN public.warehouses w
      ON w.company_id = cs.company_id AND w.id = cs.sales_warehouse_id
    WHERE cs.status = 'OPEN'::public.session_status
      AND (
          c.status IS DISTINCT FROM 'ACTIVE'
          OR s.status IS DISTINCT FROM 'ACTIVE'
          OR pt.status IS DISTINCT FROM 'ACTIVE'
          OR pt.store_id IS DISTINCT FROM cs.store_id
          OR NOT COALESCE(w.is_active,FALSE)
          OR NOT COALESCE(w.is_sale_source,FALSE)
          OR NOT EXISTS (
              SELECT 1
              FROM public.store_memberships sm
              WHERE sm.company_id = cs.company_id
                AND sm.store_id = cs.store_id
                AND sm.user_id = cs.cashier_id
                AND sm.status = 'ACTIVE'
                AND sm.role_code = 'CASHIER'
          )
      )

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
    FROM legacy_checkout_routines

    UNION ALL

    SELECT
        'legacy_checkout_client_authority',
        CASE WHEN count(*) FILTER (
            WHERE proname = 'private_create_sales_transaction_g1_legacy'
              AND (
                  prosrc ILIKE '%v_detail_rec.price%'
                  OR prosrc ILIKE '%v_detail_rec.cogs_unit%'
                  OR prosrc ILIKE '%p_grand_total%'
              )
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'client_authority_rows',count(*) FILTER (
                WHERE proname = 'private_create_sales_transaction_g1_legacy'
                  AND (
                      prosrc ILIKE '%v_detail_rec.price%'
                      OR prosrc ILIKE '%v_detail_rec.cogs_unit%'
                      OR prosrc ILIKE '%p_grand_total%'
                  )
            ),
            'fifo_rows',count(*) FILTER (
                WHERE prosrc ILIKE '%product_batches%'
            ),
            'movement_rows',count(*) FILTER (
                WHERE prosrc ILIKE '%stock_movements%'
            )
        )
    FROM legacy_checkout_routines

    UNION ALL

    SELECT
        'canonical_sale_runtime_schema',
        CASE WHEN count(*) FILTER (
            WHERE c.column_name IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_header_columns',COALESCE(
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
        'canonical_sale_detail_runtime_schema',
        CASE WHEN count(*) FILTER (
            WHERE c.column_name IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_detail_columns',COALESCE(
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
        'canonical_sale_allocation_schema',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || e.table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (
                        WHERE to_regclass(
                            'public.' || e.table_name
                        ) IS NULL
                    ),
                '[]'::jsonb
            )
        )
    FROM expected_allocation_tables e

    UNION ALL

    SELECT
        'canonical_sale_routine_state',
        CASE WHEN count(*) FILTER (
            WHERE p.proname IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_routines',COALESCE(
                jsonb_agg(
                    e.schema_name || '.' || e.routine_name
                    ORDER BY e.schema_name,e.routine_name
                ) FILTER (WHERE p.proname IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_sale_routines e
    LEFT JOIN pg_namespace n ON n.nspname = e.schema_name
    LEFT JOIN pg_proc p
      ON p.pronamespace = n.oid
     AND p.proname = e.routine_name

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
        'active_store_commerce_readiness',
        CASE WHEN count(*) FILTER (
            WHERE NOT has_default_pricelist
               OR NOT has_default_payment_method
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'active_stores',count(*),
            'without_default_pricelist',count(*) FILTER (
                WHERE NOT has_default_pricelist
            ),
            'without_default_payment_method',count(*) FILTER (
                WHERE NOT has_default_payment_method
            )
        )
    FROM active_store_commerce

    UNION ALL

    SELECT
        'invalid_customer_default_pricelist',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('customer_count',count(*))
    FROM public.customers cu
    LEFT JOIN public.pricelists pl
      ON pl.company_id = cu.company_id
     AND pl.id = cu.default_pricelist_id
    WHERE cu.is_active
      AND cu.default_pricelist_id IS NOT NULL
      AND (
          pl.id IS NULL
          OR NOT pl.is_active
          OR pl.scope <> 'CUSTOMER'
          OR (pl.valid_from IS NOT NULL
              AND pl.valid_from > clock_timestamp())
          OR (pl.valid_until IS NOT NULL
              AND pl.valid_until < clock_timestamp())
      )

    UNION ALL

    SELECT
        'invalid_active_pricelist_rule',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pricelist_rules pr
    LEFT JOIN public.pricelists pl
      ON pl.company_id = pr.company_id
     AND pl.id = pr.pricelist_id
    LEFT JOIN public.products p
      ON p.company_id = pr.company_id
     AND p.id = pr.product_id
    LEFT JOIN public.product_uoms pu
      ON pu.company_id = pr.company_id
     AND pu.id = pr.product_uom_id
     AND pu.product_id = pr.product_id
    WHERE pr.is_active
      AND (
          pl.id IS NULL
          OR p.id IS NULL
          OR pu.id IS NULL
          OR NOT pl.is_active
          OR NOT p.is_active
          OR NOT pu.is_active
          OR NOT pu.sales_allowed
          OR pu.sale_price IS NULL
          OR (
              pr.pricing_method = 'DISCOUNT_AMOUNT'
              AND pr.discount_amount_per_unit > pu.sale_price
          )
      )

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
            'stock_without_base_uom',count(*) FILTER (
                WHERE NOT is_bundle AND NOT has_base_uom
            ),
            'bundle_without_component',count(*) FILTER (
                WHERE is_bundle AND NOT has_bundle_component
            )
        )
    FROM active_product_readiness

    UNION ALL

    SELECT
        'assigned_sales_tax_runtime_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('rule_count',count(*))
    FROM assigned_tax_resolution
    WHERE current_version_rows <> 1
       OR NOT COALESCE(valid_rule_identity,FALSE)
       OR NOT COALESCE(valid_current_account,FALSE)

    UNION ALL

    SELECT
        'stock_balance_movement_fifo_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE stock_qty < 0
       OR stock_qty IS DISTINCT FROM movement_qty
       OR (
           stock_qty > 0
           AND stock_qty IS DISTINCT FROM fifo_qty
       )

    UNION ALL

    SELECT
        'movement_or_fifo_pair_without_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT mt.company_id,mt.product_id,mt.warehouse_id
        FROM movement_totals mt
        WHERE mt.movement_qty <> 0
          AND NOT EXISTS (
              SELECT 1
              FROM public.product_stocks ps
              WHERE ps.company_id = mt.company_id
                AND ps.product_id = mt.product_id
                AND ps.warehouse_id = mt.warehouse_id
          )
        UNION
        SELECT ft.company_id,ft.product_id,ft.warehouse_id
        FROM fifo_totals ft
        WHERE ft.fifo_qty <> 0
          AND NOT EXISTS (
              SELECT 1
              FROM public.product_stocks ps
              WHERE ps.company_id = ft.company_id
                AND ps.product_id = ft.product_id
                AND ps.warehouse_id = ft.warehouse_id
          )
    ) missing_balance

    UNION ALL

    SELECT
        'sale_finance_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND (
          NOT EXISTS (
              SELECT 1
              FROM public.transaction_categories tc
              WHERE tc.company_id = c.id
                AND tc.system_key = 'SALE_POSTED'
                AND tc.is_active
          )
          OR NOT EXISTS (
              SELECT 1
              FROM public.transaction_categories tc
              WHERE tc.company_id = c.id
                AND tc.system_key = 'SALE_PAYMENT'
                AND tc.is_active
          )
      )

    UNION ALL

    SELECT
        'invalid_existing_sale_history',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_headers sh
    WHERE sh.subtotal < 0
       OR sh.item_discount < 0
       OR sh.global_discount < 0
       OR sh.grand_total < 0
       OR sh.paid_amount < 0
       OR sh.sisa_piutang < 0
       OR NOT EXISTS (
           SELECT 1
           FROM public.cashier_sessions cs
           WHERE cs.company_id = sh.company_id
             AND cs.id = sh.session_id
       )

    UNION ALL

    SELECT
        'invalid_existing_sale_line_or_payment',
        CASE WHEN invalid_line_rows = 0 AND invalid_payment_rows = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'invalid_line_rows',invalid_line_rows,
            'invalid_payment_rows',invalid_payment_rows
        )
    FROM (
        SELECT
            (SELECT count(*) FROM public.sales_details WHERE qty <= 0)
                AS invalid_line_rows,
            (SELECT count(*) FROM public.sales_payments WHERE amount <= 0)
                AS invalid_payment_rows
    ) invalid_rows

    UNION ALL

    SELECT
        'generated_stock_sale_without_movement',
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
        'browser_direct_sale_write_boundary',
        CASE WHEN
            NOT has_table_privilege(
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
            AND NOT has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.product_batches',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
        THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
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
            ),
            'product_stocks_write',has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            ),
            'product_batches_write',has_table_privilege(
                'authenticated','public.product_batches',
                'INSERT,UPDATE,DELETE'
            ),
            'stock_movements_write',has_table_privilege(
                'authenticated','public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'atomic_sale_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'active_stores',(
                SELECT count(*) FROM public.stores WHERE status = 'ACTIVE'
            ),
            'open_sessions',(
                SELECT count(*) FROM public.cashier_sessions
                WHERE status = 'OPEN'::public.session_status
            ),
            'sales_headers',(SELECT count(*) FROM public.sales_headers),
            'sales_details',(SELECT count(*) FROM public.sales_details),
            'sales_payments',(SELECT count(*) FROM public.sales_payments),
            'positive_stock_pairs',(
                SELECT count(*) FROM public.product_stocks WHERE stock_qty > 0
            ),
            'positive_fifo_layers',(
                SELECT count(*) FROM public.product_batches
                WHERE qty_remaining > 0
            ),
            'active_bundles',(
                SELECT count(*) FROM public.products
                WHERE is_active AND is_bundle
            ),
            'assigned_sales_tax_rules',(
                SELECT count(*) FROM assigned_sales_tax_rules
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
