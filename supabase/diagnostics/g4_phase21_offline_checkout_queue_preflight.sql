-- G4 phase 21 preflight: PWA Cart -> retained Offline queue readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, side-effect function, or grants.
-- - Returns aggregate counts only; no Product, Customer, user, or payload rows.
-- - SETUP means the disposable authenticated UAT scope is not active yet.

WITH required_versions(version) AS (
    VALUES
        ('20260729180000'),
        ('20260729210000'),
        ('20260730010000')
), expected_routines(signature) AS (
    VALUES
        ('public.issue_pos_offline_stock_allowance(uuid,uuid)'),
        ('public.release_pos_offline_stock_allowance(uuid,bigint,boolean,text)'),
        ('public.get_pos_offline_catalog_snapshot(uuid)'),
        ('public.submit_pos_offline_sale(jsonb)'),
        ('public.process_pos_offline_sale_submission(uuid)'),
        ('public.get_pos_offline_submission_status(uuid)')
), enabled_companies AS (
    SELECT c.id AS company_id
    FROM public.companies c
    JOIN public.company_features cf
      ON cf.company_id = c.id
     AND cf.feature_code = 'offline_pos_enabled'
     AND cf.is_enabled
    WHERE c.status = 'ACTIVE'
), enabled_terminals AS (
    SELECT
        p.company_id,
        p.store_id,
        p.terminal_id
    FROM public.pos_offline_allowance_policies p
    JOIN enabled_companies ec ON ec.company_id = p.company_id
    JOIN public.pos_offline_allowance_policies cp
      ON cp.company_id = p.company_id
     AND cp.scope_type = 'COMPANY'
     AND cp.is_enabled
     AND cp.allocation_percent > 0
    JOIN public.stores s
      ON s.company_id = p.company_id
     AND s.id = p.store_id
     AND s.status = 'ACTIVE'
    JOIN public.pos_terminals pt
      ON pt.company_id = p.company_id
     AND pt.store_id = p.store_id
     AND pt.id = p.terminal_id
     AND pt.status = 'ACTIVE'
    WHERE p.scope_type = 'TERMINAL'
      AND p.is_enabled
), ready_sessions AS (
    SELECT
        cs.company_id,
        cs.id AS cashier_session_id,
        cs.store_id,
        cs.pos_id AS terminal_id,
        cs.sales_warehouse_id AS warehouse_id,
        cs.cashier_id
    FROM public.cashier_sessions cs
    JOIN enabled_terminals et
      ON et.company_id = cs.company_id
     AND et.store_id = cs.store_id
     AND et.terminal_id = cs.pos_id
    JOIN public.warehouses w
      ON w.company_id = cs.company_id
     AND w.id = cs.sales_warehouse_id
     AND w.is_active
     AND w.is_sale_source
    WHERE cs.status = 'OPEN'::public.session_status
), active_allowances AS (
    SELECT
        a.company_id,
        a.id AS allowance_id,
        a.cashier_session_id,
        a.store_id,
        a.terminal_id,
        a.warehouse_id,
        a.cashier_id,
        a.product_id,
        a.base_uom_id,
        a.allocated_base_qty,
        a.consumed_base_qty,
        a.allocated_base_qty - a.consumed_base_qty AS remaining_base_qty
    FROM public.pos_offline_stock_allowances a
    WHERE a.status = 'ACTIVE'
), reserved_totals AS (
    SELECT
        company_id,
        warehouse_id,
        product_id,
        sum(remaining_base_qty) AS reserved_base_qty
    FROM active_allowances
    GROUP BY company_id,warehouse_id,product_id
), movement_totals AS (
    SELECT
        company_id,
        warehouse_id,
        product_id,
        sum(qty_change) AS movement_qty
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
    GROUP BY company_id,warehouse_id,product_id
), fifo_totals AS (
    SELECT
        company_id,
        warehouse_id,
        product_id,
        sum(qty_remaining) AS fifo_qty
    FROM public.product_batches
    GROUP BY company_id,warehouse_id,product_id
), stock_reconciliation AS (
    SELECT
        COALESCE(ps.company_id,mt.company_id,ft.company_id) AS company_id,
        COALESCE(ps.warehouse_id,mt.warehouse_id,ft.warehouse_id)
            AS warehouse_id,
        COALESCE(ps.product_id,mt.product_id,ft.product_id) AS product_id,
        ps.stock_qty,
        mt.movement_qty,
        ft.fifo_qty
    FROM public.product_stocks ps
    FULL JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.warehouse_id = ps.warehouse_id
     AND mt.product_id = ps.product_id
    FULL JOIN fifo_totals ft
      ON ft.company_id = COALESCE(ps.company_id,mt.company_id)
     AND ft.warehouse_id = COALESCE(ps.warehouse_id,mt.warehouse_id)
     AND ft.product_id = COALESCE(ps.product_id,mt.product_id)
), session_payment_readiness AS (
    SELECT
        rs.cashier_session_id,
        count(pm.id) AS eligible_methods,
        count(pm.id) FILTER (
            WHERE pm.method_type = 'CASH'
              AND pm.settlement_route = 'CASH_DRAWER'
        ) AS eligible_cash_methods
    FROM ready_sessions rs
    LEFT JOIN public.payment_methods pm
      ON pm.company_id = rs.company_id
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
               AND pmsa.store_id = rs.store_id
         )
     )
    GROUP BY rs.cashier_session_id
), checks AS (
    SELECT
        'g4_phase21_dependencies'::TEXT AS check_name,
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
        'required_offline_checkout_routines',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(signature) IS NULL
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(signature ORDER BY signature) FILTER (
                    WHERE to_regprocedure(signature) IS NULL
                ),
                '[]'::JSONB
            )
        )
    FROM expected_routines

    UNION ALL

    SELECT
        'browser_offline_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.get_pos_offline_catalog_snapshot(uuid)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.issue_pos_offline_stock_allowance(uuid,uuid)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.release_pos_offline_stock_allowance(uuid,bigint,boolean,text)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.submit_pos_offline_sale(jsonb)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.process_pos_offline_sale_submission(uuid)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.get_pos_offline_submission_status(uuid)',
                'EXECUTE'
            )
            THEN 'PASS' ELSE 'BLOCKER'
        END,
        jsonb_build_object('expected_authenticated_rpc_rows',6)

    UNION ALL

    SELECT
        'browser_direct_offline_final_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_stock_allowances',
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
            OR has_table_privilege(
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
            THEN 'BLOCKER' ELSE 'PASS'
        END,
        jsonb_build_object(
            'submission_write',has_table_privilege(
                'authenticated','public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            ),
            'allowance_write',has_table_privilege(
                'authenticated','public.pos_offline_stock_allowances',
                'INSERT,UPDATE,DELETE'
            ),
            'sale_write',has_table_privilege(
                'authenticated','public.sales_headers',
                'INSERT,UPDATE,DELETE'
            ),
            'stock_write',has_table_privilege(
                'authenticated','public.product_stocks',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'offline_checkout_uat_scope',
        CASE WHEN
            (SELECT count(*) FROM enabled_companies) > 0
            AND (SELECT count(*) FROM enabled_terminals) > 0
            AND (SELECT count(*) FROM ready_sessions) > 0
            AND (SELECT count(*) FROM active_allowances) > 0
            THEN 'PASS' ELSE 'SETUP'
        END,
        jsonb_build_object(
            'enabled_companies',(SELECT count(*) FROM enabled_companies),
            'enabled_terminals',(SELECT count(*) FROM enabled_terminals),
            'ready_open_sessions',(SELECT count(*) FROM ready_sessions),
            'active_allowances',(SELECT count(*) FROM active_allowances)
        )

    UNION ALL

    SELECT
        'invalid_active_allowance_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM active_allowances a
    LEFT JOIN ready_sessions rs
      ON rs.company_id = a.company_id
     AND rs.cashier_session_id = a.cashier_session_id
     AND rs.store_id = a.store_id
     AND rs.terminal_id = a.terminal_id
     AND rs.warehouse_id = a.warehouse_id
     AND rs.cashier_id = a.cashier_id
    LEFT JOIN public.products p
      ON p.company_id = a.company_id
     AND p.id = a.product_id
    LEFT JOIN public.uoms u
      ON u.company_id = a.company_id
     AND u.id = a.base_uom_id
    WHERE rs.cashier_session_id IS NULL
       OR p.id IS NULL
       OR NOT p.is_active
       OR p.is_bundle
       OR p.uom_id IS DISTINCT FROM a.base_uom_id
       OR u.id IS NULL
       OR NOT u.is_active
       OR a.allocated_base_qty <= 0
       OR a.consumed_base_qty < 0
       OR a.remaining_base_qty <= 0

    UNION ALL

    SELECT
        'active_allowance_without_sales_uom',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('product_count',count(*))
    FROM (
        SELECT DISTINCT a.company_id,a.product_id
        FROM active_allowances a
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.product_uoms pu
            JOIN public.uoms u
              ON u.company_id = pu.company_id
             AND u.id = pu.uom_id
             AND u.is_active
            WHERE pu.company_id = a.company_id
              AND pu.product_id = a.product_id
              AND pu.is_active
              AND pu.sales_allowed
              AND pu.sale_price IS NOT NULL
              AND pu.sale_price >= 0
        )
    ) invalid_products

    UNION ALL

    SELECT
        'active_reservation_within_stock',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM reserved_totals r
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = r.company_id
     AND ps.warehouse_id = r.warehouse_id
     AND ps.product_id = r.product_id
    WHERE ps.product_id IS NULL
       OR r.reserved_base_qty <= 0
       OR r.reserved_base_qty > ps.stock_qty

    UNION ALL

    SELECT
        'ready_session_payment_method',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('session_count',count(*))
    FROM session_payment_readiness
    WHERE eligible_methods = 0

    UNION ALL

    SELECT
        'nonterminal_offline_submission',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'submission_count',count(*),
            'queued',count(*) FILTER (WHERE status = 'QUEUED'),
            'syncing',count(*) FILTER (WHERE status = 'SYNCING'),
            'needs_confirmation',count(*) FILTER (
                WHERE status = 'NEEDS_CONFIRMATION'
            ),
            'failed',count(*) FILTER (WHERE status = 'FAILED')
        )
    FROM public.pos_offline_sale_submissions
    WHERE status IN (
        'QUEUED','SYNCING','NEEDS_CONFIRMATION','FAILED'
    )

    UNION ALL

    SELECT
        'duplicate_offline_submission_identity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,client_transaction_id
        FROM public.pos_offline_sale_submissions
        GROUP BY company_id,client_transaction_id
        HAVING count(*) > 1
        UNION ALL
        SELECT company_id,posting_idempotency_key
        FROM public.pos_offline_sale_submissions
        GROUP BY company_id,posting_idempotency_key
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'posted_offline_submission_final_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_sale_submissions s
    LEFT JOIN public.sales_headers sh
      ON sh.company_id = s.company_id
     AND sh.id = s.sales_id
     AND sh.offline_submission_id = s.id
     AND sh.source_channel = 'OFFLINE'
     AND sh.document_status = 'POSTED'
    WHERE s.status = 'POSTED'
      AND (
          sh.id IS NULL
          OR s.sales_id IS NULL
          OR s.acknowledgement IS NULL
          OR s.processed_at IS NULL
          OR s.error_code IS NOT NULL
      )

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
        'offline_session_close_guard',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    WHERE NOT t.tgisinternal
      AND t.tgname = 'g4_guard_offline_session_close'

    UNION ALL

    SELECT
        'offline_checkout_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(
                SELECT count(*) FROM public.companies
                WHERE status = 'ACTIVE'
            ),
            'enabled_companies',(SELECT count(*) FROM enabled_companies),
            'enabled_terminals',(SELECT count(*) FROM enabled_terminals),
            'ready_sessions',(SELECT count(*) FROM ready_sessions),
            'active_allowances',(SELECT count(*) FROM active_allowances),
            'cash_ready_sessions',(
                SELECT count(*) FROM session_payment_readiness
                WHERE eligible_cash_methods > 0
            ),
            'posted_offline_submissions',(
                SELECT count(*) FROM public.pos_offline_sale_submissions
                WHERE status = 'POSTED'
            ),
            'offline_payment_exceptions',(
                SELECT count(*) FROM public.offline_payment_exceptions
                WHERE exception_status IN (
                    'PENDING_VERIFICATION','FAILED'
                )
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
