-- G4 phase 24 preflight: controlled Offline disconnect/reconnect stress.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, side-effect function, or grants.
-- - Returns aggregate counts only; no payload, Customer, Product, or user data.
-- - SETUP means a disposable Session/allowance fixture must be prepared first.

WITH required_versions(version) AS (
    VALUES
        ('20260729180000'),
        ('20260729210000'),
        ('20260730010000')
), expected_routines(signature) AS (
    VALUES
        ('public.submit_pos_offline_sale(jsonb)'),
        ('public.process_pos_offline_sale_submission(uuid)'),
        ('public.get_pos_offline_submission_status(uuid)'),
        ('public.get_pos_offline_catalog_snapshot(uuid)')
), enabled_companies AS (
    SELECT company.id AS company_id
    FROM public.companies company
    JOIN public.company_features feature
      ON feature.company_id = company.id
     AND feature.feature_code = 'offline_pos_enabled'
     AND feature.is_enabled
    JOIN public.pos_offline_allowance_policies policy
      ON policy.company_id = company.id
     AND policy.scope_type = 'COMPANY'
     AND policy.is_enabled
     AND policy.allocation_percent > 0
    WHERE company.status = 'ACTIVE'
), enabled_terminals AS (
    SELECT
        policy.company_id,
        policy.store_id,
        policy.terminal_id
    FROM public.pos_offline_allowance_policies policy
    JOIN enabled_companies company
      ON company.company_id = policy.company_id
    JOIN public.pos_terminals terminal
      ON terminal.company_id = policy.company_id
     AND terminal.store_id = policy.store_id
     AND terminal.id = policy.terminal_id
     AND terminal.status = 'ACTIVE'
    JOIN public.stores store
      ON store.company_id = policy.company_id
     AND store.id = policy.store_id
     AND store.status = 'ACTIVE'
    WHERE policy.scope_type = 'TERMINAL'
      AND policy.is_enabled
), ready_sessions AS (
    SELECT
        session.company_id,
        session.store_id,
        session.pos_id AS terminal_id,
        session.sales_warehouse_id AS warehouse_id,
        session.id AS cashier_session_id
    FROM public.cashier_sessions session
    JOIN enabled_terminals terminal
      ON terminal.company_id = session.company_id
     AND terminal.store_id = session.store_id
     AND terminal.terminal_id = session.pos_id
    JOIN public.warehouses warehouse
      ON warehouse.company_id = session.company_id
     AND warehouse.id = session.sales_warehouse_id
     AND warehouse.is_active
     AND warehouse.is_sale_source
    WHERE session.status = 'OPEN'::public.session_status
), cash_ready_sessions AS (
    SELECT DISTINCT session.cashier_session_id
    FROM ready_sessions session
    JOIN public.payment_methods method
     ON method.company_id = session.company_id
     AND method.is_active
     AND method.method_type = 'CASH'
     AND method.settlement_route = 'CASH_DRAWER'
     AND method.effective_from <= clock_timestamp()
     AND (
         method.effective_to IS NULL
         OR method.effective_to >= clock_timestamp()
     )
     AND (
         method.available_all_stores
         OR EXISTS (
             SELECT 1
             FROM public.payment_method_store_assignments assignment
             WHERE assignment.company_id = method.company_id
               AND assignment.payment_method_id = method.id
               AND assignment.store_id = session.store_id
         )
     )
), allowance_ready_sessions AS (
    SELECT DISTINCT session.cashier_session_id
    FROM ready_sessions session
    JOIN public.pos_offline_stock_allowances allowance
      ON allowance.company_id = session.company_id
     AND allowance.store_id = session.store_id
     AND allowance.terminal_id = session.terminal_id
     AND allowance.warehouse_id = session.warehouse_id
     AND allowance.cashier_session_id = session.cashier_session_id
     AND allowance.status = 'ACTIVE'
     AND allowance.allocated_base_qty > allowance.consumed_base_qty
    JOIN public.products product
      ON product.company_id = allowance.company_id
     AND product.id = allowance.product_id
     AND product.is_active
     AND NOT product.is_bundle
    JOIN public.product_uoms product_uom
      ON product_uom.company_id = product.company_id
     AND product_uom.product_id = product.id
     AND product_uom.is_active
     AND product_uom.sales_allowed
     AND product_uom.sale_price IS NOT NULL
     AND product_uom.factor_to_base <=
            allowance.allocated_base_qty - allowance.consumed_base_qty
), stress_ready_sessions AS (
    SELECT session.cashier_session_id
    FROM ready_sessions session
    JOIN cash_ready_sessions cash
      ON cash.cashier_session_id = session.cashier_session_id
    JOIN allowance_ready_sessions allowance
      ON allowance.cashier_session_id = session.cashier_session_id
), movement_totals AS (
    SELECT company_id,warehouse_id,product_id,sum(qty_change) AS quantity
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
    GROUP BY company_id,warehouse_id,product_id
), fifo_totals AS (
    SELECT company_id,warehouse_id,product_id,sum(qty_remaining) AS quantity
    FROM public.product_batches
    GROUP BY company_id,warehouse_id,product_id
), stock_reconciliation AS (
    SELECT
        COALESCE(stock.company_id,movement.company_id,fifo.company_id)
            AS company_id,
        COALESCE(stock.warehouse_id,movement.warehouse_id,fifo.warehouse_id)
            AS warehouse_id,
        COALESCE(stock.product_id,movement.product_id,fifo.product_id)
            AS product_id,
        stock.stock_qty,
        movement.quantity AS movement_qty,
        fifo.quantity AS fifo_qty
    FROM public.product_stocks stock
    FULL JOIN movement_totals movement
      ON movement.company_id = stock.company_id
     AND movement.warehouse_id = stock.warehouse_id
     AND movement.product_id = stock.product_id
    FULL JOIN fifo_totals fifo
      ON fifo.company_id = COALESCE(stock.company_id,movement.company_id)
     AND fifo.warehouse_id =
            COALESCE(stock.warehouse_id,movement.warehouse_id)
     AND fifo.product_id = COALESCE(stock.product_id,movement.product_id)
), checks AS (
    SELECT
        'g4_phase24_dependencies'::TEXT AS check_name,
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
        'required_offline_stress_routines',
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
        'browser_offline_stress_boundary',
        CASE WHEN count(*) FILTER (
                    WHERE to_regprocedure(signature) IS NOT NULL
                      AND has_function_privilege(
                          'authenticated',signature,'EXECUTE'
                      )
                  ) = count(*)
                  AND count(*) FILTER (
                      WHERE to_regprocedure(signature) IS NOT NULL
                        AND has_function_privilege(
                            'anon',signature,'EXECUTE'
                        )
                  ) = 0
                  AND NOT has_table_privilege(
                      'authenticated',
                      'public.pos_offline_sale_submissions',
                      'INSERT,UPDATE,DELETE'
                  )
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authenticated_rpc_rows',count(*) FILTER (
                WHERE to_regprocedure(signature) IS NOT NULL
                  AND has_function_privilege(
                      'authenticated',signature,'EXECUTE'
                  )
            ),
            'anon_rpc_rows',count(*) FILTER (
                WHERE to_regprocedure(signature) IS NOT NULL
                  AND has_function_privilege('anon',signature,'EXECUTE')
            ),
            'direct_submission_write',has_table_privilege(
                'authenticated',
                'public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            )
        )
    FROM expected_routines

    UNION ALL

    SELECT
        'nonterminal_submission_baseline',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'row_count',count(*),
            'queued',count(*) FILTER (WHERE status = 'QUEUED'),
            'syncing',count(*) FILTER (WHERE status = 'SYNCING'),
            'needs_confirmation',count(*) FILTER (
                WHERE status = 'NEEDS_CONFIRMATION'
            ),
            'failed',count(*) FILTER (WHERE status = 'FAILED')
        )
    FROM public.pos_offline_sale_submissions
    WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION','FAILED')

    UNION ALL

    SELECT
        'stale_syncing_submission',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_sale_submissions
    WHERE status = 'SYNCING'
      AND updated_at < clock_timestamp() - interval '1 minute'

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
    ) duplicate_rows

    UNION ALL

    SELECT
        'nonposted_submission_with_final_effect',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('submission_count',count(*))
    FROM public.pos_offline_sale_submissions submission
    WHERE submission.status <> 'POSTED'
      AND (
          submission.sales_id IS NOT NULL
          OR EXISTS (
              SELECT 1
              FROM public.pos_offline_sale_allowance_consumptions consumption
              WHERE consumption.company_id = submission.company_id
                AND consumption.submission_id = submission.id
          )
      )

    UNION ALL

    SELECT
        'posted_submission_final_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_sale_submissions submission
    LEFT JOIN public.sales_headers sale
      ON sale.company_id = submission.company_id
     AND sale.id = submission.sales_id
     AND sale.offline_submission_id = submission.id
    WHERE submission.status = 'POSTED'
      AND (
          submission.acknowledgement IS NULL
          OR submission.processed_at IS NULL
          OR submission.error_code IS NOT NULL
          OR sale.id IS NULL
          OR sale.document_status <> 'POSTED'
          OR sale.source_channel <> 'OFFLINE'
      )

    UNION ALL

    SELECT
        'offline_allowance_consumption_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('allowance_count',count(*))
    FROM (
        SELECT
            allowance.company_id,
            allowance.id,
            allowance.consumed_base_qty,
            COALESCE(sum(consumption.consumed_base_qty),0) AS ledger_qty
        FROM public.pos_offline_stock_allowances allowance
        LEFT JOIN public.pos_offline_sale_allowance_consumptions consumption
          ON consumption.company_id = allowance.company_id
         AND consumption.allowance_id = allowance.id
        GROUP BY allowance.company_id,allowance.id,
                 allowance.consumed_base_qty
        HAVING allowance.consumed_base_qty IS DISTINCT FROM
               COALESCE(sum(consumption.consumed_base_qty),0)
    ) mismatch

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE COALESCE(stock_qty,0) IS DISTINCT FROM COALESCE(movement_qty,0)

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
        'disconnect_stress_fixture_readiness',
        CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'ready_sessions',count(*),
            'open_enabled_sessions',(SELECT count(*) FROM ready_sessions),
            'cash_ready_sessions',(
                SELECT count(*) FROM cash_ready_sessions
            ),
            'allowance_ready_sessions',(
                SELECT count(*) FROM allowance_ready_sessions
            )
        )
    FROM stress_ready_sessions

    UNION ALL

    SELECT
        'offline_stress_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'submissions',count(*),
            'posted',count(*) FILTER (WHERE status = 'POSTED'),
            'invalidated',count(*) FILTER (WHERE status = 'INVALIDATED'),
            'max_processing_attempts',COALESCE(max(processing_attempts),0),
            'replayed_submissions',count(*) FILTER (
                WHERE processing_attempts > 1
            )
        )
    FROM public.pos_offline_sale_submissions

    UNION ALL

    SELECT
        'client_disconnect_matrix',
        'INFO',
        jsonb_build_object(
            'stages',jsonb_build_array(
                'before submit',
                'during submit',
                'during process',
                'during status check',
                'after POSTED before catalog refresh'
            ),
            'client_timeouts_seconds',jsonb_build_object(
                'status',10,'submit',15,'process',25
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'PASS' THEN 2
        WHEN 'SETUP' THEN 3
        ELSE 4
    END,
    check_name;
