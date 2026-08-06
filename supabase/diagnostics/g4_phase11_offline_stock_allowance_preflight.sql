-- G4 phase 11 preflight: Offline Stock Allowance and sync readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Product, user, or business
--   transaction rows.
-- - Expected missing offline tables are SETUP, not a rollout failure.

WITH required_versions(version) AS (
    VALUES
        ('20260729070000'),
        ('20260729100000'),
        ('20260729120000'),
        ('20260729150000')
), expected_offline_tables(table_name) AS (
    VALUES
        ('pos_offline_allowance_policies'),
        ('pos_offline_stock_allowances'),
        ('pos_offline_stock_allowance_audit'),
        ('pos_offline_sale_submissions'),
        ('pos_offline_sale_submission_events')
), offline_schema_state AS (
    SELECT
        count(*) AS expected_tables,
        count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) AS missing_table_count,
        COALESCE(
            jsonb_agg(table_name ORDER BY table_name) FILTER (
                WHERE to_regclass('public.' || table_name) IS NULL
            ),
            '[]'::jsonb
        ) AS missing_tables
    FROM expected_offline_tables
), active_company_entitlements AS (
    SELECT
        c.id AS company_id,
        COALESCE(cf.is_enabled,FALSE) AS offline_enabled
    FROM public.companies c
    LEFT JOIN public.company_features cf
      ON cf.company_id = c.id
     AND cf.feature_code = 'offline_pos_enabled'
    WHERE c.status = 'ACTIVE'
), active_terminal_readiness AS (
    SELECT
        pt.company_id,
        pt.store_id,
        pt.id AS terminal_id,
        ace.offline_enabled,
        EXISTS (
            SELECT 1
            FROM public.warehouses w
            WHERE w.company_id = pt.company_id
              AND w.is_active
              AND w.is_sale_source
              AND (w.store_id IS NULL OR w.store_id = pt.store_id)
        ) AS has_sale_source_warehouse,
        EXISTS (
            SELECT 1
            FROM public.store_memberships sm
            WHERE sm.company_id = pt.company_id
              AND sm.store_id = pt.store_id
              AND sm.status = 'ACTIVE'
              AND sm.role_code IN ('CASHIER','STORE_MANAGER')
        ) AS has_pos_operator
    FROM public.pos_terminals pt
    JOIN public.stores s
      ON s.company_id = pt.company_id
     AND s.id = pt.store_id
    JOIN active_company_entitlements ace
      ON ace.company_id = pt.company_id
    WHERE pt.status = 'ACTIVE'
      AND s.status = 'ACTIVE'
), active_store_payment_readiness AS (
    SELECT
        s.company_id,
        s.id AS store_id,
        ace.offline_enabled,
        count(pm.id) FILTER (
            WHERE pm.method_type = 'CASH'
              AND pm.settlement_route = 'CASH_DRAWER'
        ) AS eligible_cash_methods,
        count(pm.id) FILTER (
            WHERE pm.method_type IN (
                'TRANSFER','QRIS','CARD','E_WALLET'
            )
              AND pm.settlement_route IN ('DIRECT_BANK','CLEARING')
        ) AS eligible_electronic_methods
    FROM public.stores s
    JOIN active_company_entitlements ace
      ON ace.company_id = s.company_id
    LEFT JOIN public.payment_methods pm
      ON pm.company_id = s.company_id
     AND pm.is_active
     AND pm.method_type NOT IN (
         'TEMPO','CUSTOMER_BALANCE','KETUL_OFFSET'
     )
     AND pm.effective_from <= clock_timestamp()
     AND (
         pm.effective_to IS NULL
         OR pm.effective_to >= clock_timestamp()
     )
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
    WHERE s.status = 'ACTIVE'
    GROUP BY s.company_id,s.id,ace.offline_enabled
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
        COALESCE(ps.company_id,mt.company_id,ft.company_id) AS company_id,
        COALESCE(ps.product_id,mt.product_id,ft.product_id) AS product_id,
        COALESCE(ps.warehouse_id,mt.warehouse_id,ft.warehouse_id)
            AS warehouse_id,
        ps.stock_qty,
        mt.movement_qty,
        ft.fifo_qty
    FROM public.product_stocks ps
    FULL JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    FULL JOIN fifo_totals ft
      ON ft.company_id = COALESCE(ps.company_id,mt.company_id)
     AND ft.product_id = COALESCE(ps.product_id,mt.product_id)
     AND ft.warehouse_id = COALESCE(ps.warehouse_id,mt.warehouse_id)
), checks AS (
    SELECT
        'g4_phase11_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version) FILTER (
                    WHERE m.version IS NULL
                ),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'offline_feature_catalog',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'catalog_rows',count(*),
            'active_rows',count(*) FILTER (WHERE is_active)
        )
    FROM public.platform_features
    WHERE feature_code = 'offline_pos_enabled'

    UNION ALL

    SELECT
        'canonical_offline_schema_state',
        CASE WHEN missing_table_count = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_tables',expected_tables,
            'missing_tables',missing_tables
        )
    FROM offline_schema_state

    UNION ALL

    SELECT
        'enabled_offline_entitlement_without_foundation',
        CASE
            WHEN count(*) FILTER (WHERE ace.offline_enabled) = 0 THEN 'PASS'
            WHEN oss.missing_table_count = 0 THEN 'PASS'
            ELSE 'BLOCKER'
        END,
        jsonb_build_object(
            'enabled_companies',
                count(*) FILTER (WHERE ace.offline_enabled),
            'missing_table_count',oss.missing_table_count
        )
    FROM active_company_entitlements ace
    CROSS JOIN offline_schema_state oss
    GROUP BY oss.missing_table_count

    UNION ALL

    SELECT
        'offline_entitlement_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',count(*),
            'enabled_companies',count(*) FILTER (WHERE offline_enabled),
            'disabled_companies',count(*) FILTER (WHERE NOT offline_enabled)
        )
    FROM active_company_entitlements

    UNION ALL

    SELECT
        'enabled_terminal_without_operational_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('terminal_count',count(*))
    FROM active_terminal_readiness
    WHERE offline_enabled
      AND (NOT has_sale_source_warehouse OR NOT has_pos_operator)

    UNION ALL

    SELECT
        'terminal_offline_readiness_inventory',
        'INFO',
        jsonb_build_object(
            'active_terminals',count(*),
            'terminals_with_sale_source_warehouse',
                count(*) FILTER (WHERE has_sale_source_warehouse),
            'terminals_with_pos_operator',
                count(*) FILTER (WHERE has_pos_operator)
        )
    FROM active_terminal_readiness

    UNION ALL

    SELECT
        'enabled_store_without_offline_cash_method',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('store_count',count(*))
    FROM active_store_payment_readiness
    WHERE offline_enabled AND eligible_cash_methods = 0

    UNION ALL

    SELECT
        'offline_payment_method_inventory',
        'INFO',
        jsonb_build_object(
            'active_stores',count(*),
            'stores_with_cash',
                count(*) FILTER (WHERE eligible_cash_methods > 0),
            'stores_with_electronic_method',
                count(*) FILTER (WHERE eligible_electronic_methods > 0)
        )
    FROM active_store_payment_readiness

    UNION ALL

    SELECT
        'invalid_open_cashier_session_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('session_count',count(*))
    FROM public.cashier_sessions cs
    LEFT JOIN public.pos_terminals pt
      ON pt.company_id = cs.company_id
     AND pt.store_id = cs.store_id
     AND pt.id = cs.pos_id
    LEFT JOIN public.warehouses w
      ON w.company_id = cs.company_id
     AND w.id = cs.sales_warehouse_id
    WHERE cs.status = 'OPEN'
      AND (
          pt.id IS NULL
          OR pt.status <> 'ACTIVE'
          OR w.id IS NULL
          OR NOT w.is_active
          OR NOT w.is_sale_source
          OR (w.store_id IS NOT NULL AND w.store_id <> cs.store_id)
      )

    UNION ALL

    SELECT
        'duplicate_open_cashier_session',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('cashier_count',count(*))
    FROM (
        SELECT cashier_id
        FROM public.cashier_sessions
        WHERE status = 'OPEN'
        GROUP BY cashier_id
        HAVING count(*) > 1
    ) duplicate_sessions

    UNION ALL

    SELECT
        'negative_stock_or_fifo',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM stock_reconciliation
    WHERE COALESCE(stock_qty,0) < 0 OR COALESCE(fifo_qty,0) < 0

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE stock_qty IS DISTINCT FROM movement_qty

    UNION ALL

    SELECT
        'stock_balance_fifo_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE COALESCE(stock_qty,0) > 0
      AND stock_qty IS DISTINCT FROM COALESCE(fifo_qty,0)

    UNION ALL

    SELECT
        'duplicate_sale_client_transaction_id',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,client_transaction_id
        FROM public.sales_headers
        GROUP BY company_id,client_transaction_id
        HAVING count(*) > 1
    ) duplicate_client_ids

    UNION ALL

    SELECT
        'duplicate_sale_posting_idempotency_key',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,posting_idempotency_key
        FROM public.sales_headers
        WHERE posting_idempotency_key IS NOT NULL
        GROUP BY company_id,posting_idempotency_key
        HAVING count(*) > 1
    ) duplicate_posting_keys

    UNION ALL

    SELECT
        'browser_direct_offline_final_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.product_batches',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            )
            THEN 'BLOCKER' ELSE 'PASS'
        END,
        jsonb_build_object(
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
            ),
            'sales_headers_write',has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            ),
            'sales_payments_write',has_table_privilege(
                'authenticated','public.sales_payments',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'offline_allowance_stock_inventory',
        'INFO',
        jsonb_build_object(
            'positive_stock_pairs',
                count(*) FILTER (WHERE COALESCE(stock_qty,0) > 0),
            'positive_fifo_pairs',
                count(*) FILTER (WHERE COALESCE(fifo_qty,0) > 0),
            'companies_with_positive_stock',
                count(DISTINCT company_id) FILTER (
                    WHERE COALESCE(stock_qty,0) > 0
                )
        )
    FROM stock_reconciliation
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
