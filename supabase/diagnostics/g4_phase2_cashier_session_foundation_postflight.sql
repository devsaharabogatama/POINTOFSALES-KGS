-- G4 phase 2 postflight: canonical Cashier Session foundation.
-- SAFETY: SELECT-only; no DDL, DML, TEMP object, or function side effect.

WITH expected_columns(column_name) AS (
    VALUES
        ('sales_warehouse_id'),
        ('opening_cash_actual'),
        ('closing_cash_actual'),
        ('opening_stock_snapshot_at'),
        ('closing_stock_snapshot_at'),
        ('master_version'),
        ('updated_at')
), expected_constraints(constraint_name) AS (
    VALUES
        ('cashier_sessions_opening_cash_nonnegative'),
        ('cashier_sessions_closing_cash_nonnegative'),
        ('cashier_sessions_master_version_positive'),
        ('cashier_sessions_open_warehouse_required'),
        ('fk_cashier_sessions_company_sales_warehouse')
), expected_indexes(index_name) AS (
    VALUES
        ('idx_cashier_sessions_company_sales_warehouse'),
        ('uq_cashier_sessions_one_open_per_cashier'),
        ('idx_cashier_session_stock_snapshot_session_stage'),
        ('idx_cashier_session_audit_session_created')
), expected_routines(routine_signature) AS (
    VALUES
        ('public.private_cashier_session_visible(uuid)'),
        ('private.calculate_cashier_session_expected_cash(uuid,uuid)'),
        ('public.open_cashier_session(uuid,uuid,numeric)'),
        ('public.close_cashier_session(uuid,bigint,numeric)')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729040000'

    UNION ALL

    SELECT
        'required_session_columns',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'column_rows',count(c.column_name),
            'missing',COALESCE(
                jsonb_agg(e.column_name ORDER BY e.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'cashier_sessions'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'required_session_tables',
        CASE WHEN count(*) FILTER (WHERE table_ref IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE table_ref IS NULL),
        jsonb_build_object('table_rows',count(table_ref))
    FROM (
        SELECT to_regclass('public.cashier_session_stock_snapshots') AS table_ref
        UNION ALL
        SELECT to_regclass('public.cashier_session_audit')
    ) tables

    UNION ALL

    SELECT
        'required_session_constraints',
        CASE WHEN count(*) FILTER (WHERE pc.conname IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE pc.conname IS NULL),
        jsonb_build_object('constraint_rows',count(pc.conname))
    FROM expected_constraints e
    LEFT JOIN pg_constraint pc
      ON pc.conname = e.constraint_name
     AND pc.conrelid = 'public.cashier_sessions'::regclass

    UNION ALL

    SELECT
        'required_session_indexes',
        CASE WHEN count(*) FILTER (WHERE pi.indexname IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE pi.indexname IS NULL),
        jsonb_build_object('index_rows',count(pi.indexname))
    FROM expected_indexes e
    LEFT JOIN pg_indexes pi
      ON pi.schemaname = 'public'
     AND pi.indexname = e.index_name

    UNION ALL

    SELECT
        'required_session_routines',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(e.routine_signature) IS NULL
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE to_regprocedure(e.routine_signature) IS NULL
        ),
        jsonb_build_object(
            'routine_rows',count(*) FILTER (
                WHERE to_regprocedure(e.routine_signature) IS NOT NULL
            )
        )
    FROM expected_routines e

    UNION ALL

    SELECT
        'session_browser_write_boundary',
        CASE WHEN NOT (
            has_table_privilege(
                'authenticated','public.cashier_sessions',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated',
                'public.cashier_session_stock_snapshots',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.cashier_session_audit',
                'INSERT,UPDATE,DELETE'
            )
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN (
            has_table_privilege(
                'authenticated','public.cashier_sessions',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated',
                'public.cashier_session_stock_snapshots',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.cashier_session_audit',
                'INSERT,UPDATE,DELETE'
            )
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'cashier_sessions_write',has_table_privilege(
                'authenticated','public.cashier_sessions',
                'INSERT,UPDATE,DELETE'
            ),
            'snapshots_write',has_table_privilege(
                'authenticated',
                'public.cashier_session_stock_snapshots',
                'INSERT,UPDATE,DELETE'
            ),
            'audit_write',has_table_privilege(
                'authenticated','public.cashier_session_audit',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'session_rpc_execute_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.close_cashier_session(uuid,bigint,numeric)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.close_cashier_session(uuid,bigint,numeric)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.close_cashier_session(uuid,bigint,numeric)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.close_cashier_session(uuid,bigint,numeric)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object(
            'authenticated_open',has_function_privilege(
                'authenticated',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            ),
            'authenticated_close',has_function_privilege(
                'authenticated',
                'public.close_cashier_session(uuid,bigint,numeric)',
                'EXECUTE'
            ),
            'anon_open',has_function_privilege(
                'anon',
                'public.open_cashier_session(uuid,uuid,numeric)',
                'EXECUTE'
            ),
            'anon_close',has_function_privilege(
                'anon',
                'public.close_cashier_session(uuid,bigint,numeric)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'duplicate_open_cashier_session',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('cashier_count',count(*))
    FROM (
        SELECT cashier_id
        FROM public.cashier_sessions
        WHERE status = 'OPEN'::public.session_status
        GROUP BY cashier_id
        HAVING count(*) > 1
    ) duplicate_open

    UNION ALL

    SELECT
        'open_session_runtime_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.cashier_sessions cs
    LEFT JOIN public.pos_terminals pt
      ON pt.company_id = cs.company_id
     AND pt.store_id = cs.store_id
     AND pt.id = cs.pos_id
    LEFT JOIN public.warehouses w
      ON w.company_id = cs.company_id
     AND w.id = cs.sales_warehouse_id
    WHERE cs.status = 'OPEN'::public.session_status
      AND (
          pt.id IS NULL
          OR pt.status <> 'ACTIVE'
          OR w.id IS NULL
          OR NOT w.is_active
          OR NOT w.is_sale_source
          OR (w.store_id IS NOT NULL AND w.store_id <> cs.store_id)
          OR cs.opening_stock_snapshot_at IS NULL
      )

    UNION ALL

    SELECT
        'closed_session_cash_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.cashier_sessions
    WHERE closing_cash_actual IS NOT NULL
      AND (
          status <> 'CLOSED'::public.session_status
          OR closed_at IS NULL
          OR expected_cash + difference <> closing_cash_actual
          OR actual_cash <> closing_cash_actual
      )

    UNION ALL

    SELECT
        'session_snapshot_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.cashier_session_stock_snapshots s
    JOIN public.cashier_sessions cs
      ON cs.company_id = s.company_id
     AND cs.id = s.cashier_session_id
    WHERE s.stock_qty_base < 0
       OR (
           s.snapshot_stage = 'OPENING'
           AND s.captured_at IS DISTINCT FROM cs.opening_stock_snapshot_at
       )
       OR (
           s.snapshot_stage = 'CLOSING'
           AND s.captured_at IS DISTINCT FROM cs.closing_stock_snapshot_at
       )

    UNION ALL

    SELECT
        'session_audit_rls',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 2 THEN 0 ELSE 1 END,
        jsonb_build_object('rls_tables',count(*))
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
          'cashier_session_stock_snapshots','cashier_session_audit'
      )
      AND c.relrowsecurity
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,
    check_name;
