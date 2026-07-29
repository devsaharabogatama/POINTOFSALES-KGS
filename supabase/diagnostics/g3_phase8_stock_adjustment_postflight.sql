-- G3 phase 8 postflight: canonical Stock Adjustment closure.
-- SELECT-only. Expected: every row PASS with violation_rows = 0.

WITH expected_tables(table_name) AS (
    VALUES
        ('stock_adjustment_reasons'),
        ('stock_adjustment_documents'),
        ('stock_adjustment_lines'),
        ('stock_adjustment_fifo_allocations'),
        ('stock_adjustment_audit')
), expected_routines(routine_name) AS (
    VALUES
        ('save_stock_adjustment_reason'),
        ('save_stock_adjustment_document'),
        ('post_stock_adjustment'),
        ('cancel_stock_adjustment'),
        ('private_stock_adjustment_operator_allowed')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        abs(count(*) - 1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260728210000'

    UNION ALL
    SELECT 'required_tables',
        count(*) FILTER(WHERE to_regclass('public.' || table_name) IS NULL),
        jsonb_build_object('table_rows',count(*))
    FROM expected_tables

    UNION ALL
    SELECT 'required_public_routines',
        count(*) FILTER(WHERE p.routine_name IS NULL),
        jsonb_build_object('routine_rows',count(p.routine_name))
    FROM expected_routines e
    LEFT JOIN (
        SELECT DISTINCT p.proname AS routine_name
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
    ) p ON p.routine_name = e.routine_name

    UNION ALL
    SELECT 'required_event_types',
        (2 - count(*))::BIGINT,
        jsonb_build_object('labels',COALESCE(
            jsonb_agg(e.enumlabel ORDER BY e.enumsortorder),'[]'::jsonb
        ))
    FROM pg_enum e
    JOIN pg_type t ON t.oid = e.enumtypid
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typname = 'event_type'
      AND e.enumlabel IN ('STOCK_GAIN','STOCK_LOSS')

    UNION ALL
    SELECT 'required_default_reason_coverage',
        count(*),
        jsonb_build_object('missing_rows',count(*))
    FROM (
        SELECT c.id
        FROM public.companies c
        CROSS JOIN (
            VALUES ('Barang Rusak'),('Barang Hilang'),('Salah Input'),
                   ('Selisih Stok'),('Kedaluwarsa'),('Koreksi Migrasi')
        ) e(reason_name)
        LEFT JOIN public.stock_adjustment_reasons r
          ON r.company_id = c.id
         AND lower(r.reason_name) = lower(e.reason_name)
         AND r.is_system_default
        WHERE r.id IS NULL
    ) missing

    UNION ALL
    SELECT 'duplicate_normalized_reason_name',
        count(*),jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,
            lower(regexp_replace(btrim(reason_name),'\s+',' ','g'))
        FROM public.stock_adjustment_reasons
        GROUP BY company_id,
            lower(regexp_replace(btrim(reason_name),'\s+',' ','g'))
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL
    SELECT 'invalid_reason_contract',
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.stock_adjustment_reasons
    WHERE btrim(reason_name) = ''
       OR direction_allowed NOT IN ('INCREASE','DECREASE','BOTH')
       OR finance_treatment NOT IN ('STOCK_GAIN','STOCK_LOSS','OTHER')
       OR master_version <= 0

    UNION ALL
    SELECT 'invalid_document_totals',
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.stock_adjustment_documents
    WHERE line_count < 0 OR total_gain_quantity_base < 0
       OR total_loss_quantity_base < 0 OR total_gain_value < 0
       OR total_loss_value < 0

    UNION ALL
    SELECT 'invalid_line_difference',
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.stock_adjustment_lines
    WHERE final_physical_quantity < 0
       OR calculated_difference = 0
       OR calculated_difference IS DISTINCT FROM
          final_physical_quantity - system_quantity_snapshot

    UNION ALL
    SELECT 'posted_line_without_movement',
        count(*),jsonb_build_object('line_count',count(*))
    FROM public.stock_adjustment_lines l
    JOIN public.stock_adjustment_documents d
      ON d.company_id = l.company_id AND d.id = l.document_id
    LEFT JOIN public.stock_movements m
      ON m.company_id = l.company_id AND m.source_line_id = l.id
     AND m.movement_type = 'ADJUSTMENT'::public.stock_movement_type
    WHERE d.status = 'POSTED' AND m.id IS NULL

    UNION ALL
    SELECT 'movement_without_posted_document',
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.stock_movements m
    LEFT JOIN public.stock_adjustment_documents d
      ON d.company_id = m.company_id AND d.id = m.reference_id
     AND m.reference_table = 'stock_adjustment_documents'
    WHERE m.movement_type = 'ADJUSTMENT'::public.stock_movement_type
      AND (d.id IS NULL OR d.status <> 'POSTED')

    UNION ALL
    SELECT 'fifo_allocation_value_mismatch',
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.stock_adjustment_fifo_allocations
    WHERE total_value IS DISTINCT FROM
          round(quantity_base * unit_cost_base,4)

    UNION ALL
    SELECT 'stock_balance_movement_mismatch',
        count(*),jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT COALESCE(ps.company_id,m.company_id) AS company_id
        FROM public.product_stocks ps
        FULL JOIN (
            SELECT company_id,product_id,warehouse_id,sum(qty_change) qty
            FROM public.stock_movements
            GROUP BY company_id,product_id,warehouse_id
        ) m
          ON m.company_id = ps.company_id
         AND m.product_id = ps.product_id
         AND m.warehouse_id = ps.warehouse_id
        WHERE ps.product_id IS NULL OR m.product_id IS NULL
           OR ps.stock_qty IS DISTINCT FROM m.qty
    ) invalid_pairs

    UNION ALL
    SELECT 'fifo_remaining_balance_mismatch',
        count(*),jsonb_build_object('pair_count',count(*))
    FROM (
        SELECT ps.company_id
        FROM public.product_stocks ps
        LEFT JOIN (
            SELECT company_id,product_id,warehouse_id,
                   sum(qty_remaining) qty
            FROM public.product_batches
            GROUP BY company_id,product_id,warehouse_id
        ) b
          ON b.company_id = ps.company_id
         AND b.product_id = ps.product_id
         AND b.warehouse_id = ps.warehouse_id
        WHERE ps.stock_qty > 0
          AND ps.stock_qty IS DISTINCT FROM COALESCE(b.qty,0)
    ) invalid_pairs

    UNION ALL
    SELECT 'browser_direct_write_boundary',
        (
            has_table_privilege(
                'authenticated','public.stock_adjustment_documents',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.stock_adjustment_lines',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.stock_adjustment_reasons',
                'INSERT,UPDATE,DELETE'
            )
        )::INT::BIGINT,
        jsonb_build_object('direct_write',(
            has_table_privilege(
                'authenticated','public.stock_adjustment_documents',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.stock_adjustment_lines',
                'INSERT,UPDATE,DELETE'
            )
        ))

    UNION ALL
    SELECT 'browser_rpc_boundary',
        (
            NOT has_function_privilege(
                'authenticated',
                'public.save_stock_adjustment_document(uuid,bigint,uuid,date,text,jsonb)',
                'EXECUTE'
            )
            OR NOT has_function_privilege(
                'authenticated',
                'public.post_stock_adjustment(uuid,bigint,uuid)',
                'EXECUTE'
            )
            OR has_function_privilege(
                'anon',
                'public.post_stock_adjustment(uuid,bigint,uuid)',
                'EXECUTE'
            )
        )::INT::BIGINT,
        '{}'::jsonb
)
SELECT check_name,
       CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
