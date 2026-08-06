-- G4 phase 23 preflight: Offline cold-start restore and conflict recovery.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, side-effect function, or grants.
-- - Returns aggregate counts only; no payload, Customer, Product, or user data.
-- - SETUP identifies the PWA-only retained bootstrap contract not opened yet.

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
), routine_contract AS (
    SELECT
        proc.proname,
        pg_get_functiondef(proc.oid) AS definition
    FROM pg_proc proc
    JOIN pg_namespace ns ON ns.oid = proc.pronamespace
    WHERE ns.nspname = 'public'
      AND proc.proname IN (
          'submit_pos_offline_sale',
          'process_pos_offline_sale_submission',
          'get_pos_offline_submission_status'
      )
), enabled_companies AS (
    SELECT c.id AS company_id
    FROM public.companies c
    JOIN public.company_features feature
      ON feature.company_id = c.id
     AND feature.feature_code = 'offline_pos_enabled'
     AND feature.is_enabled
    WHERE c.status = 'ACTIVE'
), enabled_terminals AS (
    SELECT
        policy.company_id,
        policy.store_id,
        policy.terminal_id
    FROM public.pos_offline_allowance_policies policy
    JOIN enabled_companies company
      ON company.company_id = policy.company_id
    JOIN public.pos_offline_allowance_policies company_policy
      ON company_policy.company_id = policy.company_id
     AND company_policy.scope_type = 'COMPANY'
     AND company_policy.is_enabled
     AND company_policy.allocation_percent > 0
    WHERE policy.scope_type = 'TERMINAL'
      AND policy.is_enabled
), ready_sessions AS (
    SELECT
        session.company_id,
        session.id AS cashier_session_id
    FROM public.cashier_sessions session
    JOIN enabled_terminals terminal
      ON terminal.company_id = session.company_id
     AND terminal.store_id = session.store_id
     AND terminal.terminal_id = session.pos_id
    WHERE session.status = 'OPEN'::public.session_status
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
        COALESCE(stock.company_id,movement.company_id,fifo.company_id)
            AS company_id,
        COALESCE(stock.warehouse_id,movement.warehouse_id,fifo.warehouse_id)
            AS warehouse_id,
        COALESCE(stock.product_id,movement.product_id,fifo.product_id)
            AS product_id,
        stock.stock_qty,
        movement.movement_qty,
        fifo.fifo_qty
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
        'g4_phase23_dependencies'::TEXT AS check_name,
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
        'required_offline_recovery_routines',
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
        'browser_offline_recovery_rpc_boundary',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(signature) IS NOT NULL
              AND has_function_privilege(
                  'authenticated',signature,'EXECUTE'
              )
        ) = count(*) THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected_authenticated_rpc_rows',count(*),
            'authenticated_executable_rows',count(*) FILTER (
                WHERE to_regprocedure(signature) IS NOT NULL
                  AND has_function_privilege(
                      'authenticated',signature,'EXECUTE'
                  )
            ),
            'anon_executable_rows',count(*) FILTER (
                WHERE to_regprocedure(signature) IS NOT NULL
                  AND has_function_privilege('anon',signature,'EXECUTE')
            )
        )
    FROM expected_routines

    UNION ALL

    SELECT
        'browser_direct_offline_recovery_write_boundary',
        CASE WHEN NOT has_table_privilege(
                    'authenticated',
                    'public.pos_offline_sale_submissions',
                    'INSERT,UPDATE,DELETE'
                 )
                  AND NOT has_table_privilege(
                    'authenticated',
                    'public.pos_offline_sale_submission_events',
                    'INSERT,UPDATE,DELETE'
                 )
                  AND NOT has_table_privilege(
                    'authenticated',
                    'public.pos_offline_sale_allowance_consumptions',
                    'INSERT,UPDATE,DELETE'
                 )
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'submission_write',has_table_privilege(
                'authenticated',
                'public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            ),
            'event_write',has_table_privilege(
                'authenticated',
                'public.pos_offline_sale_submission_events',
                'INSERT,UPDATE,DELETE'
            ),
            'consumption_write',has_table_privilege(
                'authenticated',
                'public.pos_offline_sale_allowance_consumptions',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'offline_submission_identity_constraints',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('constraint_rows',count(*),'expected',3)
    FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid =
            'public.pos_offline_sale_submissions'::regclass
      AND constraint_row.conname IN (
          'pos_offline_submission_client_unique',
          'pos_offline_submission_posting_key_unique',
          'pos_offline_submission_payload_check'
      )

    UNION ALL

    SELECT
        'offline_submission_lifecycle_guard',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid =
            'public.pos_offline_sale_submissions'::regclass
      AND trigger_row.tgname = 'g4_guard_offline_submission_lifecycle'
      AND NOT trigger_row.tgisinternal

    UNION ALL

    SELECT
        'offline_submit_idempotency_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('routine_rows',count(*))
    FROM routine_contract
    WHERE proname = 'submit_pos_offline_sale'
      AND definition LIKE '%OFFLINE_SUBMISSION_IDEMPOTENCY_CONFLICT%'
      AND definition LIKE '%idempotentReplay%'
      AND definition LIKE '%payload_hash%'
      AND definition LIKE '%posting_idempotency_key%'

    UNION ALL

    SELECT
        'offline_process_retry_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('routine_rows',count(*))
    FROM routine_contract
    WHERE proname = 'process_pos_offline_sale_submission'
      AND definition LIKE '%FOR UPDATE%'
      AND definition LIKE '%processing_attempts%'
      AND definition LIKE '%NEEDS_CONFIRMATION%'
      AND definition LIKE '%idempotentReplay%'
      AND definition LIKE '%retryable%'

    UNION ALL

    SELECT
        'offline_status_recovery_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('routine_rows',count(*))
    FROM routine_contract
    WHERE proname = 'get_pos_offline_submission_status'
      AND definition LIKE '%client_transaction_id%'
      AND definition LIKE '%acknowledgement%'
      AND definition LIKE '%processing_attempts%'
      AND definition LIKE '%retryable%'

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
        'offline_submission_hash_consistency',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_sale_submissions
    WHERE payload_hash IS DISTINCT FROM server_payload_hash
       OR payload_hash !~ '^[0-9a-f]{64}$'
       OR server_payload_hash !~ '^[0-9a-f]{64}$'

    UNION ALL

    SELECT
        'stale_syncing_offline_submission',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_sale_submissions
    WHERE status = 'SYNCING'
      AND updated_at < clock_timestamp() - interval '5 minutes'

    UNION ALL

    SELECT
        'failed_offline_submission_with_final_effect',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('submission_count',count(*))
    FROM public.pos_offline_sale_submissions submission
    WHERE submission.status IN (
        'FAILED','NEEDS_CONFIRMATION','INVALIDATED'
    )
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
        'posted_offline_submission_recovery_coverage',
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
        'offline_recovery_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'submissions',count(*),
            'posted',count(*) FILTER (WHERE status = 'POSTED'),
            'queued',count(*) FILTER (WHERE status = 'QUEUED'),
            'syncing',count(*) FILTER (WHERE status = 'SYNCING'),
            'needs_confirmation',count(*) FILTER (
                WHERE status = 'NEEDS_CONFIRMATION'
            ),
            'failed',count(*) FILTER (WHERE status = 'FAILED'),
            'invalidated',count(*) FILTER (WHERE status = 'INVALIDATED'),
            'max_processing_attempts',COALESCE(max(processing_attempts),0)
        )
    FROM public.pos_offline_sale_submissions

    UNION ALL

    SELECT
        'offline_recovery_uat_scope',
        CASE WHEN (SELECT count(*) FROM enabled_companies) > 0
                   AND (SELECT count(*) FROM enabled_terminals) > 0
                   AND (SELECT count(*) FROM ready_sessions) > 0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'enabled_companies',(SELECT count(*) FROM enabled_companies),
            'enabled_terminals',(SELECT count(*) FROM enabled_terminals),
            'ready_open_sessions',(SELECT count(*) FROM ready_sessions)
        )

    UNION ALL

    SELECT
        'pwa_cold_start_retained_contract',
        'SETUP',
        jsonb_build_object(
            'required_client_capabilities',jsonb_build_array(
                'retained operational scope',
                'cached auth identity match',
                'offline catalog restore',
                'retained queue restore',
                'status-first reconnect recovery'
            ),
            'reason',
                'Client cold-start contract is intentionally unopened before this preflight'
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
