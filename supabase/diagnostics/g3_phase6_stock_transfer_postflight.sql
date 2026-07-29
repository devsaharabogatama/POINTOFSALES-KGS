-- G3 phase 6 postflight: canonical Stock Transfer foundation.
-- Expected result: every row PASS with violation_rows = 0.

WITH required_tables(table_name) AS (
    VALUES
        ('stock_transfer_documents'),
        ('stock_transfer_lines'),
        ('stock_transfer_fifo_allocations'),
        ('stock_transfer_audit')
), required_routines(signature) AS (
    VALUES
        ('public.private_stock_transfer_operator_allowed(uuid)'),
        ('public.save_stock_transfer_document(uuid,bigint,uuid,uuid,date,text,jsonb)'),
        ('public.post_stock_transfer(uuid,bigint,uuid)'),
        ('public.cancel_stock_transfer(uuid,bigint)')
), required_batch_columns(column_name) AS (
    VALUES ('stock_transfer_line_id'),('source_batch_id')
), transfer_groups AS (
    SELECT
        company_id,reference_id,source_line_id,product_id,
        count(*) FILTER (
            WHERE movement_type =
                'TRANSFER_OUT'::public.stock_movement_type
        ) AS out_rows,
        count(*) FILTER (
            WHERE movement_type =
                'TRANSFER_IN'::public.stock_movement_type
        ) AS in_rows,
        count(DISTINCT warehouse_id) AS warehouse_count,
        sum(qty_change) AS net_qty
    FROM public.stock_movements
    WHERE reference_table = 'stock_transfer_documents'
      AND movement_type IN (
          'TRANSFER_IN'::public.stock_movement_type,
          'TRANSFER_OUT'::public.stock_movement_type
      )
    GROUP BY company_id,reference_id,source_line_id,product_id
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
        'migration_ledger'::text AS check_name,
        count(*) FILTER (WHERE version = '20260728180000') <> 1
            AS violated,
        jsonb_build_object(
            'ledger_rows',count(*) FILTER (
                WHERE version = '20260728180000'
            )
        ) AS details
    FROM private.kgs_schema_migrations

    UNION ALL

    SELECT
        'required_transfer_tables',
        count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) > 0,
        jsonb_build_object(
            'table_rows',count(*) FILTER (
                WHERE to_regclass('public.' || table_name) IS NOT NULL
            )
        )
    FROM required_tables

    UNION ALL

    SELECT
        'required_transfer_routines',
        count(*) FILTER (
            WHERE to_regprocedure(signature) IS NULL
        ) > 0,
        jsonb_build_object(
            'routine_rows',count(*) FILTER (
                WHERE to_regprocedure(signature) IS NOT NULL
            )
        )
    FROM required_routines

    UNION ALL

    SELECT
        'required_batch_lineage_columns',
        count(*) FILTER (WHERE c.column_name IS NULL) > 0,
        jsonb_build_object(
            'column_rows',count(*) FILTER (WHERE c.column_name IS NOT NULL)
        )
    FROM required_batch_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = 'product_batches'
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'transfer_table_rls',
        count(*) FILTER (WHERE NOT cls.relrowsecurity) > 0,
        jsonb_build_object('rls_rows',count(*) FILTER (WHERE cls.relrowsecurity))
    FROM required_tables e
    LEFT JOIN pg_class cls
      ON cls.oid = to_regclass('public.' || e.table_name)

    UNION ALL

    SELECT
        'browser_transfer_write_boundary',
        has_table_privilege(
            'authenticated','public.stock_transfer_documents',
            'INSERT,UPDATE,DELETE'
        )
        OR has_table_privilege(
            'authenticated','public.stock_transfer_lines',
            'INSERT,UPDATE,DELETE'
        )
        OR has_table_privilege(
            'authenticated','public.stock_transfer_fifo_allocations',
            'INSERT,UPDATE,DELETE'
        )
        OR has_table_privilege(
            'authenticated','public.stock_transfer_audit',
            'INSERT,UPDATE,DELETE'
        ),
        jsonb_build_object(
            'direct_write',
            has_table_privilege(
                'authenticated','public.stock_transfer_documents',
                'INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_transfer_lines',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'guarded_transfer_rpc_boundary',
        NOT has_function_privilege(
            'authenticated',
            'public.save_stock_transfer_document(uuid,bigint,uuid,uuid,date,text,jsonb)',
            'EXECUTE'
        )
        OR NOT has_function_privilege(
            'authenticated',
            'public.post_stock_transfer(uuid,bigint,uuid)',
            'EXECUTE'
        )
        OR NOT has_function_privilege(
            'authenticated',
            'public.cancel_stock_transfer(uuid,bigint)',
            'EXECUTE'
        )
        OR has_function_privilege(
            'anon',
            'public.post_stock_transfer(uuid,bigint,uuid)',
            'EXECUTE'
        ),
        jsonb_build_object(
            'authenticated_post',has_function_privilege(
                'authenticated',
                'public.post_stock_transfer(uuid,bigint,uuid)',
                'EXECUTE'
            ),
            'anon_post',has_function_privilege(
                'anon',
                'public.post_stock_transfer(uuid,bigint,uuid)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'legacy_transfer_rpc_retired',
        has_function_privilege(
            'anon',
            'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
            'EXECUTE'
        )
        OR has_function_privilege(
            'authenticated',
            'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
            'EXECUTE'
        )
        OR has_function_privilege(
            'service_role',
            'public.transfer_product_stock(uuid,uuid,uuid,numeric)',
            'EXECUTE'
        ),
        jsonb_build_object(
            'routine_exists',to_regprocedure(
                'public.transfer_product_stock(uuid,uuid,uuid,numeric)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'invalid_transfer_document_state',
        count(*) > 0,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_transfer_documents d
    WHERE d.source_warehouse_id = d.destination_warehouse_id
       OR d.line_count < 0
       OR d.total_quantity_base < 0
       OR d.total_cost < 0

    UNION ALL

    SELECT
        'invalid_transfer_fifo_allocation',
        count(*) > 0,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_transfer_fifo_allocations a
    JOIN public.product_batches source
      ON source.company_id = a.company_id
     AND source.id = a.source_batch_id
    JOIN public.product_batches destination
      ON destination.company_id = a.company_id
     AND destination.id = a.destination_batch_id
    JOIN public.stock_transfer_lines l
      ON l.company_id = a.company_id
     AND l.id = a.line_id
    JOIN public.stock_transfer_documents d
      ON d.company_id = a.company_id
     AND d.id = a.document_id
    WHERE source.product_id IS DISTINCT FROM l.product_id
       OR source.warehouse_id IS DISTINCT FROM d.source_warehouse_id
       OR destination.product_id IS DISTINCT FROM l.product_id
       OR destination.warehouse_id IS DISTINCT FROM
            d.destination_warehouse_id
       OR destination.source_batch_id IS DISTINCT FROM source.id
       OR destination.stock_transfer_line_id IS DISTINCT FROM l.id
       OR a.quantity_base <= 0
       OR a.total_cost <> round(a.quantity_base * a.unit_cost_base,4)

    UNION ALL

    SELECT
        'invalid_canonical_transfer_movement_pair',
        count(*) > 0,
        jsonb_build_object('group_count',count(*))
    FROM transfer_groups
    WHERE out_rows <> 1
       OR in_rows <> 1
       OR warehouse_count <> 2
       OR net_qty <> 0

    UNION ALL

    SELECT
        'posted_transfer_line_evidence',
        count(*) > 0,
        jsonb_build_object('line_count',count(*))
    FROM public.stock_transfer_lines l
    JOIN public.stock_transfer_documents d
      ON d.company_id = l.company_id
     AND d.id = l.document_id
    WHERE d.status = 'POSTED'
      AND (
          (
              SELECT COALESCE(sum(a.quantity_base),0)
              FROM public.stock_transfer_fifo_allocations a
              WHERE a.company_id = l.company_id
                AND a.line_id = l.id
          ) IS DISTINCT FROM l.quantity_base
          OR (
              SELECT count(*)
              FROM public.stock_movements sm
              WHERE sm.company_id = l.company_id
                AND sm.reference_table = 'stock_transfer_documents'
                AND sm.reference_id = l.document_id
                AND sm.source_line_id = l.id
                AND sm.movement_type IN (
                    'TRANSFER_IN'::public.stock_movement_type,
                    'TRANSFER_OUT'::public.stock_movement_type
                )
          ) <> 2
      )

    UNION ALL

    SELECT
        'incomplete_canonical_transfer_movement',
        count(*) > 0,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements
    WHERE reference_table = 'stock_transfer_documents'
      AND (
          base_uom_id IS NULL
          OR base_uom_name_snapshot IS NULL
          OR balance_after_base_qty IS NULL
          OR actor_id IS NULL
          OR posted_at IS NULL
          OR source_line_id IS NULL
          OR movement_status <> 'POSTED'
      )

    UNION ALL

    SELECT
        'stock_balance_movement_mismatch',
        count(*) > 0,
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    FULL JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
    WHERE ps.product_id IS NULL
       OR mt.product_id IS NULL
       OR ps.stock_qty IS DISTINCT FROM mt.qty

    UNION ALL

    SELECT
        'fifo_remaining_balance_mismatch',
        count(*) > 0,
        jsonb_build_object('pair_count',count(*))
    FROM public.product_stocks ps
    LEFT JOIN fifo_totals ft
      ON ft.company_id = ps.company_id
     AND ft.product_id = ps.product_id
     AND ft.warehouse_id = ps.warehouse_id
    WHERE ps.stock_qty > 0
      AND ps.stock_qty IS DISTINCT FROM COALESCE(ft.qty,0)
)
SELECT
    check_name,
    CASE WHEN violated THEN 'FAIL' ELSE 'PASS' END AS status,
    CASE WHEN violated THEN 1 ELSE 0 END AS violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violated THEN 1 ELSE 2 END,check_name;
