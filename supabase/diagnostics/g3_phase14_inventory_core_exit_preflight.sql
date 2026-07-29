-- G3 phase 14 preflight: inventory-core exit and stress-test readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no business names or transaction payloads.
-- - Cross-gate Sale/Return/Receipt coverage is reported as DEFERRED, not hidden.

WITH required_versions(version) AS (
    VALUES
        ('20260728120000'), ('20260728150000'), ('20260728180000'),
        ('20260728210000'), ('20260728230000'), ('20260729010000')
), required_routines(routine_name) AS (
    VALUES
        ('save_opening_stock_document'), ('post_opening_stock'),
        ('save_stock_transfer_document'), ('post_stock_transfer'),
        ('cancel_stock_transfer'), ('save_stock_adjustment_reason'),
        ('save_stock_adjustment_document'), ('post_stock_adjustment'),
        ('cancel_stock_adjustment'), ('save_stock_opname_session'),
        ('start_stock_opname'), ('record_stock_opname_count'),
        ('complete_stock_opname'), ('request_stock_opname_recount'),
        ('post_stock_opname'), ('cancel_stock_opname'),
        ('save_bundle_with_components'), ('get_bundle_availability')
), public_routines AS (
    SELECT DISTINCT p.proname
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
), movement_totals AS (
    SELECT
        company_id,
        product_id,
        warehouse_id,
        sum(qty_change) FILTER (WHERE movement_status = 'POSTED')
            AS movement_qty
    FROM public.stock_movements
    GROUP BY company_id,product_id,warehouse_id
), stock_reconciliation AS (
    SELECT
        COALESCE(ps.company_id,mt.company_id) AS company_id,
        COALESCE(ps.product_id,mt.product_id) AS product_id,
        COALESCE(ps.warehouse_id,mt.warehouse_id) AS warehouse_id,
        COALESCE(ps.stock_qty,0) AS stock_qty,
        COALESCE(mt.movement_qty,0) AS movement_qty
    FROM public.product_stocks ps
    FULL JOIN movement_totals mt
      ON mt.company_id = ps.company_id
     AND mt.product_id = ps.product_id
     AND mt.warehouse_id = ps.warehouse_id
), fifo_totals AS (
    SELECT
        company_id,
        product_id,
        warehouse_id,
        sum(qty_remaining) AS fifo_qty,
        count(*) FILTER (WHERE qty_remaining > 0) AS positive_layers
    FROM public.product_batches
    GROUP BY company_id,product_id,warehouse_id
), fifo_reconciliation AS (
    SELECT
        COALESCE(ps.company_id,ft.company_id) AS company_id,
        COALESCE(ps.product_id,ft.product_id) AS product_id,
        COALESCE(ps.warehouse_id,ft.warehouse_id) AS warehouse_id,
        COALESCE(ps.stock_qty,0) AS stock_qty,
        COALESCE(ft.fifo_qty,0) AS fifo_qty,
        COALESCE(ft.positive_layers,0) AS positive_layers
    FROM public.product_stocks ps
    FULL JOIN fifo_totals ft
      ON ft.company_id = ps.company_id
     AND ft.product_id = ps.product_id
     AND ft.warehouse_id = ps.warehouse_id
), latest_movement AS (
    SELECT DISTINCT ON (company_id,product_id,warehouse_id)
        company_id,product_id,warehouse_id,balance_after_base_qty
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
    ORDER BY
        company_id,product_id,warehouse_id,
        posted_at DESC NULLS LAST,created_at DESC,id DESC
), posted_source_gaps AS (
    SELECT 'OPENING'::text AS source_type,count(*) AS gap_count
    FROM public.opening_stock_documents d
    JOIN public.opening_stock_lines l
      ON l.company_id = d.company_id AND l.document_id = d.id
    LEFT JOIN public.stock_movements sm
      ON sm.company_id = l.company_id
     AND sm.source_line_id = l.id
     AND sm.movement_type = 'OPENING_BALANCE'::public.stock_movement_type
     AND sm.movement_status = 'POSTED'
    WHERE d.status = 'POSTED' AND sm.id IS NULL

    UNION ALL

    SELECT 'TRANSFER',count(*)
    FROM (
        SELECT l.company_id,l.id
        FROM public.stock_transfer_documents d
        JOIN public.stock_transfer_lines l
          ON l.company_id = d.company_id AND l.document_id = d.id
        LEFT JOIN public.stock_movements sm
          ON sm.company_id = l.company_id
         AND sm.source_line_id = l.id
         AND sm.movement_type IN (
             'TRANSFER_OUT'::public.stock_movement_type,
             'TRANSFER_IN'::public.stock_movement_type
         )
         AND sm.movement_status = 'POSTED'
        WHERE d.status = 'POSTED'
        GROUP BY l.company_id,l.id
        HAVING count(sm.id) <> 2
    ) gaps

    UNION ALL

    SELECT 'ADJUSTMENT',count(*)
    FROM (
        SELECT l.company_id,l.id
        FROM public.stock_adjustment_documents d
        JOIN public.stock_adjustment_lines l
          ON l.company_id = d.company_id AND l.document_id = d.id
        LEFT JOIN public.stock_movements sm
          ON sm.company_id = l.company_id
         AND sm.source_line_id = l.id
         AND sm.movement_type = 'ADJUSTMENT'::public.stock_movement_type
         AND sm.movement_status = 'POSTED'
        WHERE d.status = 'POSTED'
        GROUP BY l.company_id,l.id
        HAVING count(sm.id) <> 1
    ) gaps
), stress_fixture AS (
    SELECT
        count(*) FILTER (
            WHERE fr.stock_qty > 0 AND fr.fifo_qty = fr.stock_qty
        ) AS positive_fifo_pairs,
        count(*) FILTER (
            WHERE fr.stock_qty > 0
              AND fr.fifo_qty = fr.stock_qty
              AND fr.positive_layers >= 2
        ) AS multi_layer_pairs,
        (
            SELECT count(*)
            FROM public.products p
            WHERE p.is_active
              AND p.is_bundle
              AND EXISTS (
                  SELECT 1 FROM public.product_bundle_items bi
                  WHERE bi.company_id = p.company_id
                    AND bi.bundle_id = p.id
              )
        ) AS active_bundles,
        (
            SELECT count(*)
            FROM public.companies c
            WHERE c.status = 'ACTIVE'
              AND (
                  SELECT count(*) FROM public.warehouses w
                  WHERE w.company_id = c.id AND w.is_active
              ) >= 2
        ) AS companies_with_transfer_pair
    FROM fifo_reconciliation fr
), checks AS (
    SELECT
        'g3_inventory_core_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'required_inventory_rpc_state',
        CASE WHEN count(pr.proname) = (SELECT count(*) FROM required_routines)
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',(SELECT count(*) FROM required_routines),
            'routine_names_found',count(pr.proname),
            'missing',COALESCE(
                jsonb_agg(r.routine_name ORDER BY r.routine_name)
                    FILTER (WHERE pr.proname IS NULL),
                '[]'::jsonb
            )
        )
    FROM required_routines r
    LEFT JOIN public_routines pr ON pr.proname = r.routine_name

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE stock_qty <> movement_qty

    UNION ALL

    SELECT
        'stock_balance_fifo_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM fifo_reconciliation
    WHERE stock_qty <> fifo_qty

    UNION ALL

    SELECT
        'latest_movement_balance_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM latest_movement lm
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = lm.company_id
     AND ps.product_id = lm.product_id
     AND ps.warehouse_id = lm.warehouse_id
    WHERE lm.balance_after_base_qty IS NULL
       OR lm.balance_after_base_qty <> COALESCE(ps.stock_qty,0)

    UNION ALL

    SELECT
        'negative_or_invalid_stock_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_stocks
    WHERE stock_qty < 0

    UNION ALL

    SELECT
        'invalid_fifo_layer_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_batches
    WHERE qty_purchased <= 0
       OR qty_remaining < 0
       OR qty_remaining > qty_purchased
       OR cogs_unit < 0

    UNION ALL

    SELECT
        'incomplete_posted_movement_snapshot',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.stock_movements
    WHERE movement_status = 'POSTED'
      AND (
          base_uom_id IS NULL
          OR NULLIF(btrim(base_uom_name_snapshot),'') IS NULL
          OR balance_after_base_qty IS NULL
          OR actor_id IS NULL
          OR posted_at IS NULL
          OR source_line_id IS NULL
      )

    UNION ALL

    SELECT
        'duplicate_canonical_movement_source',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,reference_table,source_line_id,movement_type
        FROM public.stock_movements
        WHERE movement_status = 'POSTED' AND source_line_id IS NOT NULL
        GROUP BY company_id,reference_table,source_line_id,movement_type
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'posted_inventory_source_movement_coverage',
        CASE WHEN sum(gap_count) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'gap_count',sum(gap_count),
            'by_source',jsonb_object_agg(source_type,gap_count)
        )
    FROM posted_source_gaps

    UNION ALL

    SELECT
        'posted_opname_adjustment_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM public.stock_opname_details d
    JOIN public.stock_opnames o
      ON o.company_id = d.company_id AND o.id = d.opname_id
    WHERE o.status = 'POSTED'
      AND d.variance_at_count <> 0
      AND d.adjustment_line_id IS NULL

    UNION ALL

    SELECT
        'bundle_virtual_stock_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.products p
    WHERE p.is_bundle
      AND (
          EXISTS (
              SELECT 1 FROM public.product_stocks ps
              WHERE ps.company_id = p.company_id AND ps.product_id = p.id
          )
          OR EXISTS (
              SELECT 1 FROM public.product_batches pb
              WHERE pb.company_id = p.company_id AND pb.product_id = p.id
          )
          OR EXISTS (
              SELECT 1 FROM public.stock_movements sm
              WHERE sm.company_id = p.company_id AND sm.product_id = p.id
          )
      )

    UNION ALL

    SELECT
        'active_bundle_component_contract',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('bundle_count',count(*))
    FROM public.products bundle
    WHERE bundle.is_active
      AND bundle.is_bundle
      AND (
          NOT EXISTS (
              SELECT 1 FROM public.product_bundle_items bi
              WHERE bi.company_id = bundle.company_id
                AND bi.bundle_id = bundle.id
          )
          OR EXISTS (
              SELECT 1
              FROM public.product_bundle_items bi
              JOIN public.products component
                ON component.company_id = bi.company_id
               AND component.id = bi.item_id
              WHERE bi.company_id = bundle.company_id
                AND bi.bundle_id = bundle.id
                AND (
                    component.is_bundle
                    OR NOT component.is_active
                    OR bi.component_qty <= 0
                )
          )
          OR NOT EXISTS (
              SELECT 1 FROM public.product_uoms pu
              WHERE pu.company_id = bundle.company_id
                AND pu.product_id = bundle.id
                AND pu.is_active
                AND pu.sales_allowed
                AND NOT pu.purchase_allowed
                AND pu.factor_to_base = 1
          )
      )

    UNION ALL

    SELECT
        'browser_direct_stock_write_boundary',
        CASE WHEN
            has_table_privilege(
                'authenticated','public.product_stocks','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.product_batches','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated','public.stock_movements','INSERT,UPDATE,DELETE'
            )
            OR has_table_privilege(
                'authenticated',
                'public.product_bundle_items','INSERT,UPDATE,DELETE'
            )
        THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object(
            'product_stocks_write',has_table_privilege(
                'authenticated','public.product_stocks','INSERT,UPDATE,DELETE'
            ),
            'product_batches_write',has_table_privilege(
                'authenticated','public.product_batches','INSERT,UPDATE,DELETE'
            ),
            'stock_movements_write',has_table_privilege(
                'authenticated','public.stock_movements','INSERT,UPDATE,DELETE'
            ),
            'bundle_components_write',has_table_privilege(
                'authenticated',
                'public.product_bundle_items','INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'stress_fixture_readiness',
        CASE WHEN
            positive_fifo_pairs > 0
            AND multi_layer_pairs > 0
            AND active_bundles > 0
            AND companies_with_transfer_pair > 0
        THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'positive_fifo_pairs',positive_fifo_pairs,
            'multi_layer_fifo_pairs',multi_layer_pairs,
            'active_bundles',active_bundles,
            'companies_with_transfer_pair',companies_with_transfer_pair
        )
    FROM stress_fixture

    UNION ALL

    SELECT
        'cross_gate_transaction_stock_coverage',
        'DEFERRED',
        jsonb_build_object(
            'g4',jsonb_build_array(
                'concurrent Sale checkout',
                'Bundle component deduction',
                'Sales Return FIFO restoration'
            ),
            'g5',jsonb_build_array(
                'Goods Receipt FIFO intake',
                'Purchase Return FIFO consumption'
            ),
            'reason',
                'Transaction posting is intentionally unopened in G3 core'
        )

    UNION ALL

    SELECT
        'inventory_core_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'stock_pairs',(SELECT count(*) FROM public.product_stocks),
            'movement_rows',(SELECT count(*) FROM public.stock_movements),
            'fifo_layers',(SELECT count(*) FROM public.product_batches),
            'posted_opening_documents',(
                SELECT count(*) FROM public.opening_stock_documents
                WHERE status = 'POSTED'
            ),
            'posted_transfer_documents',(
                SELECT count(*) FROM public.stock_transfer_documents
                WHERE status = 'POSTED'
            ),
            'posted_adjustment_documents',(
                SELECT count(*) FROM public.stock_adjustment_documents
                WHERE status = 'POSTED'
            ),
            'posted_opname_sessions',(
                SELECT count(*) FROM public.stock_opnames
                WHERE status = 'POSTED'
            ),
            'active_bundles',(
                SELECT count(*) FROM public.products
                WHERE is_bundle AND is_active
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'SETUP' THEN 2
        WHEN 'PASS' THEN 3
        WHEN 'DEFERRED' THEN 4
        ELSE 5
    END,
    check_name;
