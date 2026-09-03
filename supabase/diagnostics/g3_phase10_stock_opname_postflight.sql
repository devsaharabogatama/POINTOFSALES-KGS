-- G3 phase 10 postflight: canonical Stock Opname foundation.
-- SELECT-only. Expected result: every row PASS with violation_rows = 0.

WITH expected_columns(table_name,column_name) AS (
    VALUES
        ('stock_opnames','scope_type'),
        ('stock_opnames','count_started_at'),
        ('stock_opnames','movement_watermark_at'),
        ('stock_opnames','adjustment_document_id'),
        ('stock_opnames','posting_idempotency_key'),
        ('stock_opnames','master_version'),
        ('stock_opname_details','line_status'),
        ('stock_opname_details','base_uom_id'),
        ('stock_opname_details','system_qty_at_start'),
        ('stock_opname_details','expected_qty_at_count'),
        ('stock_opname_details','variance_at_count'),
        ('stock_opname_details','count_started_at'),
        ('stock_opname_details','counted_at'),
        ('stock_opname_details','counter_id'),
        ('stock_opname_details','superseded_by_line_id'),
        ('stock_opname_details','adjustment_line_id')
), expected_tables(table_name) AS (
    VALUES ('stock_opname_count_attempts'),('stock_opname_audit')
), expected_routines(routine_name) AS (
    VALUES
        ('private_stock_opname_counter_allowed'),
        ('save_stock_opname_session'),
        ('start_stock_opname'),
        ('record_stock_opname_count'),
        ('complete_stock_opname'),
        ('request_stock_opname_recount'),
        ('post_stock_opname'),
        ('cancel_stock_opname'),
        ('get_stock_opname_blind_session')
), movement_totals AS (
    SELECT company_id,product_id,warehouse_id,sum(qty_change) AS qty
    FROM public.stock_movements
    GROUP BY company_id,product_id,warehouse_id
), fifo_totals AS (
    SELECT company_id,product_id,warehouse_id,sum(qty_remaining) AS qty
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260728230000'

    UNION ALL

    SELECT
        'required_tables',
        count(*) FILTER(WHERE to_regclass('public.' || table_name) IS NULL),
        jsonb_build_object('table_rows',count(*))
    FROM expected_tables

    UNION ALL

    SELECT
        'required_columns',
        count(*) FILTER(WHERE c.column_name IS NULL),
        jsonb_build_object('column_rows',count(*))
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'required_enum_labels',
        count(*) FILTER(WHERE x.enumlabel IS NULL),
        jsonb_build_object('label_rows',count(*))
    FROM (
        VALUES ('COUNTING'),('COMPLETED'),('POSTED'),('CANCELED')
    ) e(label)
    LEFT JOIN (
        SELECT x.enumlabel
        FROM pg_enum x
        JOIN pg_type t ON t.oid = x.enumtypid
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'public' AND t.typname = 'opname_status'
    ) x ON x.enumlabel = e.label

    UNION ALL

    SELECT
        'required_routines',
        count(*) FILTER(WHERE p.proname IS NULL),
        jsonb_build_object('routine_rows',count(*))
    FROM expected_routines e
    LEFT JOIN (
        SELECT DISTINCT p.proname
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
    ) p ON p.proname = e.routine_name

    UNION ALL

    SELECT
        'browser_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'anon',
                'public.post_stock_opname(uuid,bigint,uuid)','EXECUTE'
            )
            OR NOT has_function_privilege(
                'authenticated',
                'public.save_stock_opname_session(uuid,bigint,uuid,text,uuid,jsonb,text)',
                'EXECUTE'
            )
            OR NOT has_function_privilege(
                'authenticated',
                'public.get_stock_opname_blind_session(uuid)','EXECUTE'
            )
        THEN 1 ELSE 0 END,
        jsonb_build_object(
            'anon_post',has_function_privilege(
                'anon',
                'public.post_stock_opname(uuid,bigint,uuid)','EXECUTE'
            ),
            'authenticated_save',has_function_privilege(
                'authenticated',
                'public.save_stock_opname_session(uuid,bigint,uuid,text,uuid,jsonb,text)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'direct_opname_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.stock_opnames','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_opname_details',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_opname_count_attempts',
                'INSERT,UPDATE,DELETE'
            )
        THEN 1 ELSE 0 END,
        jsonb_build_object('direct_write',FALSE)

    UNION ALL

    SELECT
        'invalid_canonical_opname_line_shape',count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.stock_opname_details
    WHERE line_status IN ('COUNTED','RECOUNT_REQUIRED','POSTED')
      AND (
          counted_at IS NULL OR counter_id IS NULL
          OR expected_qty_at_count IS NULL OR variance_at_count IS NULL
          OR variance_at_count IS DISTINCT FROM
              physical_qty - expected_qty_at_count
      )

    UNION ALL

    SELECT
        'unresolved_line_in_posted_opname',count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.stock_opnames o
    JOIN public.stock_opname_details d
      ON d.company_id = o.company_id AND d.opname_id = o.id
    WHERE o.status = 'POSTED'::public.opname_status
      AND d.line_status NOT IN ('POSTED','SKIPPED','SUPERSEDED')

    UNION ALL

    SELECT
        'invalid_posted_adjustment_link',count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.stock_opnames o
    LEFT JOIN public.stock_adjustment_documents a
      ON a.company_id = o.company_id
     AND a.id = o.adjustment_document_id
    WHERE o.status = 'POSTED'::public.opname_status
      AND o.adjustment_document_id IS NOT NULL
      AND (a.id IS NULL OR a.status <> 'POSTED')

    UNION ALL

    SELECT
        'duplicate_active_product_warehouse_line',count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT d.company_id,o.warehouse_id,d.product_id
        FROM public.stock_opname_details d
        JOIN public.stock_opnames o
          ON o.company_id = d.company_id AND o.id = d.opname_id
        WHERE d.line_status IN ('COUNTED','RECOUNT_REQUIRED')
          AND o.status NOT IN (
              'POSTED'::public.opname_status,
              'CANCELED'::public.opname_status
          )
        GROUP BY d.company_id,o.warehouse_id,d.product_id
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'stock_balance_movement_mismatch',count(*),
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT COALESCE(ps.company_id,m.company_id)
        FROM public.product_stocks ps
        FULL JOIN movement_totals m
          ON m.company_id = ps.company_id
         AND m.product_id = ps.product_id
         AND m.warehouse_id = ps.warehouse_id
        WHERE ps.product_id IS NULL OR m.product_id IS NULL
           OR ps.stock_qty IS DISTINCT FROM m.qty
    ) invalid_pairs

    UNION ALL

    SELECT
        'fifo_remaining_balance_mismatch',count(*),
        jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT ps.company_id
        FROM public.product_stocks ps
        LEFT JOIN fifo_totals f
          ON f.company_id = ps.company_id
         AND f.product_id = ps.product_id
         AND f.warehouse_id = ps.warehouse_id
        WHERE ps.stock_qty > 0
          AND ps.stock_qty IS DISTINCT FROM COALESCE(f.qty,0)
    ) invalid_pairs

    UNION ALL

    SELECT
        'rls_enabled',
        count(*) FILTER(WHERE NOT c.relrowsecurity),
        jsonb_build_object('table_rows',count(*))
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
          'stock_opnames','stock_opname_details',
          'stock_opname_count_attempts','stock_opname_audit'
      )
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
