-- G4 phase 12 preflight: atomic Offline Sale submission and sync readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, side-effect function, or grants.
-- - Returns aggregate counts only; no Product, Customer, user, or payload rows.
-- - Missing Phase-12 runtime objects are expected SETUP.

WITH required_versions(version) AS (
    VALUES
        ('20260729070000'),
        ('20260729150000'),
        ('20260729180000')
), expected_foundation_tables(table_name) AS (
    VALUES
        ('pos_offline_allowance_policies'),
        ('pos_offline_stock_allowances'),
        ('pos_offline_stock_allowance_audit'),
        ('pos_offline_sale_submissions'),
        ('pos_offline_sale_submission_events')
), expected_sync_tables(table_name) AS (
    VALUES
        ('pos_offline_sale_allowance_consumptions'),
        ('pos_offline_sync_exceptions'),
        ('offline_payment_exceptions')
), expected_sync_columns(table_name,column_name) AS (
    VALUES
        ('sales_headers','source_channel'),
        ('sales_headers','offline_submission_id'),
        ('sales_headers','offline_transaction_at'),
        ('sales_headers','offline_price_variance_total'),
        ('sales_details','offline_snapshot_unit_price'),
        ('sales_details','offline_resolved_unit_price'),
        ('sales_details','offline_price_variance'),
        ('sales_payments','offline_verification_status'),
        ('sales_payments','offline_reference_snapshot')
), expected_sync_routines(routine_name) AS (
    VALUES
        ('submit_pos_offline_sale'),
        ('process_pos_offline_sale_submission'),
        ('get_pos_offline_submission_status')
), active_reservations AS (
    SELECT
        company_id,warehouse_id,product_id,
        sum(allocated_base_qty - consumed_base_qty) AS reserved_qty
    FROM public.pos_offline_stock_allowances
    WHERE status = 'ACTIVE'
    GROUP BY company_id,warehouse_id,product_id
), movement_totals AS (
    SELECT
        company_id,warehouse_id,product_id,
        sum(qty_change) AS movement_qty
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
    GROUP BY company_id,warehouse_id,product_id
), fifo_totals AS (
    SELECT
        company_id,warehouse_id,product_id,
        sum(qty_remaining) AS fifo_qty
    FROM public.product_batches
    GROUP BY company_id,warehouse_id,product_id
), stock_reconciliation AS (
    SELECT
        COALESCE(ps.company_id,mt.company_id,ft.company_id) AS company_id,
        COALESCE(ps.warehouse_id,mt.warehouse_id,ft.warehouse_id)
            AS warehouse_id,
        COALESCE(ps.product_id,mt.product_id,ft.product_id) AS product_id,
        ps.stock_qty,mt.movement_qty,ft.fifo_qty
    FROM public.product_stocks ps
    FULL JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.warehouse_id = ps.warehouse_id
     AND mt.product_id = ps.product_id
    FULL JOIN fifo_totals ft
      ON ft.company_id = COALESCE(ps.company_id,mt.company_id)
     AND ft.warehouse_id = COALESCE(ps.warehouse_id,mt.warehouse_id)
     AND ft.product_id = COALESCE(ps.product_id,mt.product_id)
), active_store_payment_readiness AS (
    SELECT
        s.company_id,s.id AS store_id,
        count(pm.id) FILTER (
            WHERE pm.method_type = 'CASH'
              AND pm.settlement_route = 'CASH_DRAWER'
        ) AS cash_methods,
        count(pm.id) FILTER (
            WHERE pm.method_type IN ('TRANSFER','QRIS','CARD','E_WALLET')
              AND pm.settlement_route IN ('DIRECT_BANK','CLEARING')
        ) AS electronic_methods
    FROM public.stores s
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
             FROM public.payment_method_store_assignments a
             WHERE a.company_id = pm.company_id
               AND a.payment_method_id = pm.id
               AND a.store_id = s.id
         )
     )
    WHERE s.status = 'ACTIVE'
    GROUP BY s.company_id,s.id
), checks AS (
    SELECT
        'g4_phase12_dependencies'::text AS check_name,
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
        'offline_allowance_foundation_state',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'table_rows',count(*) FILTER (
                WHERE to_regclass('public.' || table_name) IS NOT NULL
            ),
            'missing',COALESCE(
                jsonb_agg(table_name ORDER BY table_name) FILTER (
                    WHERE to_regclass('public.' || table_name) IS NULL
                ),
                '[]'::jsonb
            )
        )
    FROM expected_foundation_tables

    UNION ALL

    SELECT
        'offline_entitlement_remains_closed',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('enabled_companies',count(*))
    FROM public.company_features
    WHERE feature_code = 'offline_pos_enabled' AND is_enabled

    UNION ALL

    SELECT
        'nonterminal_offline_submission',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('submission_count',count(*))
    FROM public.pos_offline_sale_submissions
    WHERE status IN (
        'QUEUED','SYNCING','NEEDS_CONFIRMATION','FAILED'
    )

    UNION ALL

    SELECT
        'invalid_offline_submission_envelope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_sale_submissions s
    LEFT JOIN public.cashier_sessions cs
      ON cs.company_id = s.company_id
     AND cs.store_id = s.store_id
     AND cs.pos_id = s.terminal_id
     AND cs.id = s.cashier_session_id
    WHERE cs.id IS NULL
       OR cs.cashier_id IS DISTINCT FROM s.cashier_id
       OR cs.sales_warehouse_id IS DISTINCT FROM s.warehouse_id
       OR jsonb_typeof(s.payload_snapshot) <> 'object'
       OR s.payload_hash !~ '^[0-9a-f]{64}$'
       OR s.local_master_version <= 0

    UNION ALL

    SELECT
        'duplicate_active_session_product_allowance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,cashier_session_id,product_id
        FROM public.pos_offline_stock_allowances
        WHERE status = 'ACTIVE'
        GROUP BY company_id,cashier_session_id,product_id
        HAVING count(*) > 1
    ) duplicate_allowances

    UNION ALL

    SELECT
        'active_reservation_within_stock',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM active_reservations r
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = r.company_id
     AND ps.warehouse_id = r.warehouse_id
     AND ps.product_id = r.product_id
    WHERE ps.product_id IS NULL
       OR r.reserved_qty <= 0
       OR r.reserved_qty > ps.stock_qty

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
        'negative_stock_fifo_or_reservation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM stock_reconciliation s
    LEFT JOIN active_reservations r
      ON r.company_id = s.company_id
     AND r.warehouse_id = s.warehouse_id
     AND r.product_id = s.product_id
    WHERE COALESCE(s.stock_qty,0) < 0
       OR COALESCE(s.fifo_qty,0) < 0
       OR COALESCE(r.reserved_qty,0) < 0

    UNION ALL

    SELECT
        'offline_store_payment_readiness',
        CASE WHEN count(*) FILTER (
            WHERE cash_methods = 0
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_stores',count(*),
            'stores_without_cash',
                count(*) FILTER (WHERE cash_methods = 0),
            'stores_with_electronic_method',
                count(*) FILTER (WHERE electronic_methods > 0)
        )
    FROM active_store_payment_readiness

    UNION ALL

    SELECT
        'sale_post_finance_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.transaction_categories tc
          WHERE tc.company_id = c.id
            AND tc.system_key = 'SALE_POSTED'
            AND tc.is_active
      )

    UNION ALL

    SELECT
        'offline_payment_exception_finance_state',
        CASE WHEN
            EXISTS (
                SELECT 1 FROM public.account_functions
                WHERE function_key = 'OFFLINE_PAYMENT_RECEIVABLE'
                  AND is_active
            )
            AND EXISTS (
                SELECT 1 FROM public.system_events
                WHERE system_key = 'OFFLINE_PAYMENT_EXCEPTION'
                  AND is_active
            )
            THEN 'PASS' ELSE 'SETUP'
        END,
        jsonb_build_object(
            'account_function_exists',EXISTS (
                SELECT 1 FROM public.account_functions
                WHERE function_key = 'OFFLINE_PAYMENT_RECEIVABLE'
                  AND is_active
            ),
            'system_event_exists',EXISTS (
                SELECT 1 FROM public.system_events
                WHERE system_key = 'OFFLINE_PAYMENT_EXCEPTION'
                  AND is_active
            )
        )

    UNION ALL

    SELECT
        'canonical_offline_sync_table_state',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(table_name ORDER BY table_name) FILTER (
                    WHERE to_regclass('public.' || table_name) IS NULL
                ),
                '[]'::jsonb
            )
        )
    FROM expected_sync_tables

    UNION ALL

    SELECT
        'canonical_offline_sync_column_state',
        CASE WHEN count(*) FILTER (
            WHERE c.column_name IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(
                    e.table_name || '.' || e.column_name
                    ORDER BY e.table_name,e.column_name
                ) FILTER (WHERE c.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_sync_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'canonical_offline_sync_routine_state',
        CASE WHEN count(DISTINCT p.proname) =
                  (SELECT count(*) FROM expected_sync_routines)
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_routines',COALESCE(
                jsonb_agg(e.routine_name ORDER BY e.routine_name)
                    FILTER (WHERE p.proname IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_sync_routines e
    LEFT JOIN (
        SELECT DISTINCT p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('public','private')
    ) p ON p.proname = e.routine_name

    UNION ALL

    SELECT
        'required_online_sale_runtime',
        CASE WHEN
            to_regprocedure(
                'public.save_pos_sale_draft(jsonb)'
            ) IS NOT NULL
            AND to_regprocedure(
                'public.post_pos_sale(uuid,bigint,uuid)'
            ) IS NOT NULL
            THEN 'PASS' ELSE 'BLOCKER'
        END,
        jsonb_build_object(
            'save_draft_exists',to_regprocedure(
                'public.save_pos_sale_draft(jsonb)'
            ) IS NOT NULL,
            'post_sale_exists',to_regprocedure(
                'public.post_pos_sale(uuid,bigint,uuid)'
            ) IS NOT NULL
        )

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
        'browser_direct_offline_sync_write_boundary',
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
            'sales_write',has_table_privilege(
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
        'offline_sync_foundation_inventory',
        'INFO',
        jsonb_build_object(
            'company_policies',(SELECT count(*)
                FROM public.pos_offline_allowance_policies
                WHERE scope_type = 'COMPANY'),
            'enabled_terminal_policies',(SELECT count(*)
                FROM public.pos_offline_allowance_policies
                WHERE scope_type = 'TERMINAL' AND is_enabled),
            'active_allowances',(SELECT count(*)
                FROM public.pos_offline_stock_allowances
                WHERE status = 'ACTIVE'),
            'submissions',(SELECT count(*)
                FROM public.pos_offline_sale_submissions),
            'posted_sales',(SELECT count(*)
                FROM public.sales_headers
                WHERE document_status = 'POSTED')
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
