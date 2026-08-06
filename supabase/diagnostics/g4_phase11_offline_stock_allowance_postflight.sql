-- G4 phase 11 postflight: Offline Stock Allowance foundation.
-- SAFETY: SELECT-only aggregate verification.

WITH expected_tables(table_name) AS (
    VALUES
        ('pos_offline_allowance_policies'),
        ('pos_offline_stock_allowances'),
        ('pos_offline_stock_allowance_audit'),
        ('pos_offline_sale_submissions'),
        ('pos_offline_sale_submission_events')
), expected_routines(routine_name) AS (
    VALUES
        ('save_pos_offline_allowance_policy'),
        ('issue_pos_offline_stock_allowance'),
        ('release_pos_offline_stock_allowance'),
        ('trg_g4_guard_offline_reserved_stock'),
        ('trg_g4_guard_offline_session_close'),
        ('trg_g4_reject_offline_history_mutation')
), active_reservations AS (
    SELECT
        company_id,warehouse_id,product_id,
        sum(allocated_base_qty - consumed_base_qty) AS reserved_qty
    FROM public.pos_offline_stock_allowances
    WHERE status = 'ACTIVE'
    GROUP BY company_id,warehouse_id,product_id
), checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729180000'

    UNION ALL

    SELECT
        'required_offline_tables',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ),
        jsonb_build_object(
            'table_rows',count(*) FILTER (
                WHERE to_regclass('public.' || table_name) IS NOT NULL
            )
        )
    FROM expected_tables

    UNION ALL

    SELECT
        'active_company_default_policy_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT c.id
        FROM public.companies c
        LEFT JOIN public.pos_offline_allowance_policies p
          ON p.company_id = c.id
         AND p.scope_type = 'COMPANY'
         AND p.is_enabled
         AND p.allocation_percent = 0.200000
        WHERE c.status = 'ACTIVE'
        GROUP BY c.id
        HAVING count(p.id) <> 1
    ) invalid_company_default

    UNION ALL

    SELECT
        'invalid_offline_policy_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_allowance_policies p
    WHERE p.allocation_percent IS NOT NULL
          AND (p.allocation_percent <= 0 OR p.allocation_percent > 1)
       OR p.scope_type = 'COMPANY'
          AND (p.store_id IS NOT NULL OR p.terminal_id IS NOT NULL)
       OR p.scope_type = 'STORE'
          AND (p.store_id IS NULL OR p.terminal_id IS NOT NULL)
       OR p.scope_type = 'TERMINAL'
          AND (p.store_id IS NULL OR p.terminal_id IS NULL
               OR p.allocation_percent IS NOT NULL)

    UNION ALL

    SELECT
        'active_allowance_reservation_within_stock',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
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
        'active_allowance_session_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.pos_offline_stock_allowances a
    LEFT JOIN public.cashier_sessions cs
      ON cs.company_id = a.company_id
     AND cs.store_id = a.store_id
     AND cs.pos_id = a.terminal_id
     AND cs.id = a.cashier_session_id
    WHERE a.status = 'ACTIVE'
      AND (
          cs.id IS NULL
          OR cs.status <> 'OPEN'::public.session_status
          OR cs.sales_warehouse_id IS DISTINCT FROM a.warehouse_id
          OR cs.cashier_id IS DISTINCT FROM a.cashier_id
      )

    UNION ALL

    SELECT
        'closed_session_with_unresolved_offline_state',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('session_count',count(*))
    FROM public.cashier_sessions cs
    WHERE cs.status = 'CLOSED'::public.session_status
      AND (
          EXISTS (
              SELECT 1 FROM public.pos_offline_stock_allowances a
              WHERE a.company_id = cs.company_id
                AND a.cashier_session_id = cs.id
                AND a.status = 'ACTIVE'
                AND a.allocated_base_qty > a.consumed_base_qty
          )
          OR EXISTS (
              SELECT 1 FROM public.pos_offline_sale_submissions s
              WHERE s.company_id = cs.company_id
                AND s.cashier_session_id = cs.id
                AND s.status IN (
                    'QUEUED','SYNCING','NEEDS_CONFIRMATION','FAILED'
                )
          )
      )

    UNION ALL

    SELECT
        'offline_entitlement_remains_closed',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('enabled_companies',count(*))
    FROM public.company_features
    WHERE feature_code = 'offline_pos_enabled' AND is_enabled

    UNION ALL

    SELECT
        'required_offline_routines',
        CASE WHEN count(DISTINCT e.routine_name) =
                  (SELECT count(*) FROM expected_routines)
             THEN 'PASS' ELSE 'FAIL' END,
        (SELECT count(*) FROM expected_routines)
            - count(DISTINCT e.routine_name),
        jsonb_build_object(
            'routine_rows',count(DISTINCT e.routine_name)
        )
    FROM expected_routines e
    JOIN pg_proc p ON p.proname = e.routine_name
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('public','private')

    UNION ALL

    SELECT
        'required_offline_triggers',
        CASE WHEN count(*) = 10 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 10),
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    WHERE NOT t.tgisinternal
      AND t.tgname IN (
          'g4_touch_pos_offline_allowance_policies',
          'g4_touch_pos_offline_stock_allowances',
          'g4_guard_offline_reserved_stock',
          'g4_guard_offline_reserved_stock_delete',
          'g4_guard_offline_session_close',
          'g4_guard_offline_policy_delete',
          'g4_guard_offline_allowance_delete',
          'g4_guard_offline_allowance_audit_immutable',
          'g4_guard_offline_submission_delete',
          'g4_guard_offline_submission_event_immutable'
      )

    UNION ALL

    SELECT
        'required_offline_rls',
        CASE WHEN count(*) = 5
               AND count(*) FILTER (WHERE c.relrowsecurity) = 5
             THEN 'PASS' ELSE 'FAIL' END,
        5 - count(*) FILTER (WHERE c.relrowsecurity),
        jsonb_build_object(
            'table_rows',count(*),
            'rls_rows',count(*) FILTER (WHERE c.relrowsecurity)
        )
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
          'pos_offline_allowance_policies',
          'pos_offline_stock_allowances',
          'pos_offline_stock_allowance_audit',
          'pos_offline_sale_submissions',
          'pos_offline_sale_submission_events'
      )

    UNION ALL

    SELECT
        'browser_offline_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.pos_offline_allowance_policies',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_stock_allowances',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_sale_submission_events',
                'INSERT,UPDATE,DELETE'
            )
            THEN 'FAIL' ELSE 'PASS'
        END,
        CASE WHEN
            has_table_privilege(
                'authenticated','public.pos_offline_allowance_policies',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_stock_allowances',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.pos_offline_sale_submission_events',
                'INSERT,UPDATE,DELETE'
            )
            THEN 1 ELSE 0
        END,
        jsonb_build_object(
            'policy_write',has_table_privilege(
                'authenticated','public.pos_offline_allowance_policies',
                'INSERT,UPDATE,DELETE'
            ),
            'allowance_write',has_table_privilege(
                'authenticated','public.pos_offline_stock_allowances',
                'INSERT,UPDATE,DELETE'
            ),
            'submission_write',has_table_privilege(
                'authenticated','public.pos_offline_sale_submissions',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'guarded_offline_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_pos_offline_allowance_policy(uuid,bigint,text,uuid,uuid,numeric,boolean)',
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
            AND to_regprocedure(
                'public.submit_pos_offline_sale(uuid,uuid,jsonb,text)'
            ) IS NULL
            THEN 'PASS' ELSE 'FAIL'
        END,
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_pos_offline_allowance_policy(uuid,bigint,text,uuid,uuid,numeric,boolean)',
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
            AND to_regprocedure(
                'public.submit_pos_offline_sale(uuid,uuid,jsonb,text)'
            ) IS NULL
            THEN 0 ELSE 1
        END,
        jsonb_build_object(
            'submission_ingest_open',
                to_regprocedure(
                    'public.submit_pos_offline_sale(uuid,uuid,jsonb,text)'
                ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'offline_foundation_inventory',
        'PASS',
        0,
        jsonb_build_object(
            'policies',(SELECT count(*)
                FROM public.pos_offline_allowance_policies),
            'active_allowances',(SELECT count(*)
                FROM public.pos_offline_stock_allowances
                WHERE status = 'ACTIVE'),
            'submissions',(SELECT count(*)
                FROM public.pos_offline_sale_submissions),
            'audit_rows',(SELECT count(*)
                FROM public.pos_offline_stock_allowance_audit)
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,
    check_name;
