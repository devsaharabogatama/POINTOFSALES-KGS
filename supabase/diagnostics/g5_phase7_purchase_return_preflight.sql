-- G5 phase 7 preflight: Purchase Return readiness after Goods Receipt.
-- SAFETY: SELECT-only; aggregate metadata/data only; no business names.

WITH required_versions(version) AS (
    VALUES ('20260806040000'),('20260806050000')
), posted_receipts AS (
    SELECT d.id,d.company_id,d.store_id,d.warehouse_id,d.supplier_order_id,
           d.provisional_ap_total,d.financial_event_id
    FROM public.goods_receipt_documents d
    WHERE d.status='POSTED'
), receipt_lines AS (
    SELECT l.id,l.company_id,l.document_id,l.product_id,l.base_uom_id,
           l.received_base_qty,l.accepted_good_base_qty,l.damaged_base_qty,
           l.rejected_base_qty,l.estimated_base_unit_cost,
           l.provisional_ap_amount
    FROM public.goods_receipt_lines l
    JOIN posted_receipts d
      ON d.company_id=l.company_id AND d.id=l.document_id
), accepted_allocations AS (
    SELECT a.id,a.company_id,a.receipt_line_id,a.condition_type,a.warehouse_id,
           a.quantity_base,a.product_batch_id
    FROM public.goods_receipt_condition_allocations a
    JOIN receipt_lines l
      ON l.company_id=a.company_id AND l.id=a.receipt_line_id
    WHERE a.condition_type IN('GOOD','DAMAGED')
), stock_reconciliation AS (
    SELECT ps.company_id,ps.product_id,ps.warehouse_id,ps.stock_qty,
           COALESCE((SELECT sum(sm.qty_change)
             FROM public.stock_movements sm
             WHERE sm.company_id=ps.company_id
               AND sm.product_id=ps.product_id
               AND sm.warehouse_id=ps.warehouse_id),0) AS movement_qty,
           COALESCE((SELECT sum(pb.qty_remaining)
             FROM public.product_batches pb
             WHERE pb.company_id=ps.company_id
               AND pb.product_id=ps.product_id
               AND pb.warehouse_id=ps.warehouse_id),0) AS fifo_qty
    FROM public.product_stocks ps
), checks AS (
    SELECT
        'g5_purchase_return_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER(WHERE m.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER(WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version=r.version

    UNION ALL

    SELECT
        'canonical_purchase_return_schema_state',
        'SETUP',
        jsonb_build_object(
            'missing_tables',(
                SELECT COALESCE(jsonb_agg(v.table_name ORDER BY v.table_name),'[]'::jsonb)
                FROM (VALUES
                    ('purchase_return_documents'),
                    ('purchase_return_lines'),
                    ('purchase_return_fifo_allocations'),
                    ('purchase_return_ap_adjustments'),
                    ('purchase_return_audit')
                ) AS v(table_name)
                WHERE NOT EXISTS(
                    SELECT 1
                    FROM pg_catalog.pg_class c
                    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
                    WHERE n.nspname='public'
                      AND c.relname=v.table_name
                      AND c.relkind IN('r','p')
                )
            ),
            'expected_tables',5
        )

    UNION ALL

    SELECT
        'canonical_purchase_return_routine_state',
        'SETUP',
        jsonb_build_object(
            'missing_routines',(
                SELECT COALESCE(jsonb_agg(v.routine_name ORDER BY v.routine_name),'[]'::jsonb)
                FROM (VALUES
                    ('save_purchase_return_draft'),
                    ('cancel_purchase_return_draft'),
                    ('review_purchase_return'),
                    ('post_purchase_return')
                ) AS v(routine_name)
                WHERE NOT EXISTS(
                    SELECT 1
                    FROM pg_catalog.pg_proc p
                    JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='public' AND p.proname=v.routine_name
                )
            ),
            'expected_routines',4
        )

    UNION ALL

    SELECT
        'posted_goods_receipt_inventory',
        'INFO',
        jsonb_build_object(
            'receipts',count(*),
            'companies',count(DISTINCT company_id),
            'stores',count(DISTINCT store_id),
            'provisional_ap_total',COALESCE(sum(provisional_ap_total),0)
        )
    FROM posted_receipts

    UNION ALL

    SELECT
        'invalid_posted_receipt_source',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('receipt_count',count(*))
    FROM posted_receipts d
    LEFT JOIN public.stores s
      ON s.company_id=d.company_id AND s.id=d.store_id
    LEFT JOIN public.warehouses w
      ON w.company_id=d.company_id AND w.id=d.warehouse_id
    LEFT JOIN public.supplier_order_documents so
      ON so.company_id=d.company_id AND so.id=d.supplier_order_id
    LEFT JOIN public.financial_events fe
      ON fe.company_id=d.company_id AND fe.id=d.financial_event_id
    WHERE s.id IS NULL OR w.id IS NULL OR so.id IS NULL OR fe.id IS NULL
       OR fe.system_event_key<>'GOODS_RECEIPT' OR fe.status<>'HOLD'

    UNION ALL

    SELECT
        'invalid_posted_receipt_line_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM receipt_lines l
    LEFT JOIN public.products p
      ON p.company_id=l.company_id AND p.id=l.product_id
    LEFT JOIN public.uoms u
      ON u.company_id=l.company_id AND u.id=l.base_uom_id
    WHERE p.id IS NULL OR u.id IS NULL OR l.received_base_qty<=0
       OR l.accepted_good_base_qty<0 OR l.damaged_base_qty<0
       OR l.rejected_base_qty<0
       OR l.accepted_good_base_qty+l.damaged_base_qty+l.rejected_base_qty
          <>l.received_base_qty
       OR l.estimated_base_unit_cost<0 OR l.provisional_ap_amount<0

    UNION ALL

    SELECT
        'receipt_condition_quantity_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('line_count',count(*))
    FROM (
        SELECT l.id,l.accepted_good_base_qty+l.damaged_base_qty AS accepted_qty,
               COALESCE(sum(a.quantity_base),0) AS allocated_qty
        FROM receipt_lines l
        LEFT JOIN accepted_allocations a
          ON a.company_id=l.company_id AND a.receipt_line_id=l.id
        GROUP BY l.id,l.accepted_good_base_qty,l.damaged_base_qty
        HAVING l.accepted_good_base_qty+l.damaged_base_qty
               <>COALESCE(sum(a.quantity_base),0)
    ) mismatch

    UNION ALL

    SELECT
        'accepted_receipt_without_fifo_lineage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('allocation_count',count(*))
    FROM accepted_allocations a
    LEFT JOIN public.product_batches b
      ON b.company_id=a.company_id AND b.id=a.product_batch_id
    WHERE b.id IS NULL
       OR b.goods_receipt_condition_allocation_id<>a.id
       OR b.goods_receipt_line_id<>a.receipt_line_id
       OR b.warehouse_id<>a.warehouse_id
       OR b.qty_purchased<>a.quantity_base

    UNION ALL

    SELECT
        'accepted_receipt_without_purchase_movement',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('allocation_count',count(*))
    FROM accepted_allocations a
    WHERE NOT EXISTS(
        SELECT 1
        FROM public.stock_movements sm
        WHERE sm.company_id=a.company_id
          AND sm.source_line_id=a.id
          AND sm.movement_type='PURCHASE'
          AND sm.qty_change=a.quantity_base
    )

    UNION ALL

    SELECT
        'posted_receipt_ap_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('receipt_count',count(*))
    FROM (
        SELECT d.id,d.provisional_ap_total,
               COALESCE(sum(ap.amount),0) AS ap_amount
        FROM posted_receipts d
        LEFT JOIN public.goods_receipt_ap_provisionals ap
          ON ap.company_id=d.company_id AND ap.receipt_id=d.id
        GROUP BY d.id,d.provisional_ap_total
        HAVING d.provisional_ap_total<>COALESCE(sum(ap.amount),0)
    ) mismatch

    UNION ALL

    SELECT
        'non_open_goods_receipt_ap_source',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM public.goods_receipt_ap_provisionals ap
    JOIN posted_receipts d
      ON d.company_id=ap.company_id AND d.id=ap.receipt_id
    WHERE ap.status<>'OPEN'

    UNION ALL

    SELECT
        'purchase_return_source_availability',
        'INFO',
        jsonb_build_object(
            'accepted_allocations',count(*),
            'allocations_with_fifo_remaining',count(*) FILTER(
                WHERE b.qty_remaining>0
            ),
            'returnable_base_qty',COALESCE(sum(GREATEST(b.qty_remaining,0)),0),
            'fully_consumed_allocations',count(*) FILTER(
                WHERE b.qty_remaining=0
            )
        )
    FROM accepted_allocations a
    JOIN public.product_batches b
      ON b.company_id=a.company_id AND b.id=a.product_batch_id

    UNION ALL

    SELECT
        'purchase_return_transaction_category_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM (SELECT DISTINCT company_id FROM posted_receipts) scope
    WHERE NOT EXISTS(
        SELECT 1
        FROM public.transaction_categories tc
        WHERE tc.company_id=scope.company_id
          AND tc.system_key='PURCHASE_RETURN'
          AND tc.is_active
    )

    UNION ALL

    SELECT
        'purchase_return_finance_catalog',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'system_event_rows',count(*),
            'required_functions',COALESCE(
                (SELECT to_jsonb(se.required_account_functions)
                 FROM public.system_events se
                 WHERE se.system_key='PURCHASE_RETURN'),
                '[]'::jsonb
            ),
            'optional_functions',COALESCE(
                (SELECT to_jsonb(se.optional_account_functions)
                 FROM public.system_events se
                 WHERE se.system_key='PURCHASE_RETURN'),
                '[]'::jsonb
            )
        )
    FROM public.system_events se
    WHERE se.system_key='PURCHASE_RETURN' AND se.is_active

    UNION ALL

    SELECT
        'purchase_return_movement_enum',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('label_rows',count(*))
    FROM pg_catalog.pg_enum e
    JOIN pg_catalog.pg_type t ON t.oid=e.enumtypid
    JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='stock_movement_type'
      AND e.enumlabel='PURCHASE_RETURN'

    UNION ALL

    SELECT
        'stock_balance_movement_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE stock_qty<>movement_qty

    UNION ALL

    SELECT
        'stock_balance_fifo_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE fifo_qty<0 OR (stock_qty>=0 AND fifo_qty<>stock_qty)

    UNION ALL

    SELECT
        'direct_purchase_return_write_boundary',
        'INFO',
        jsonb_build_object(
            'goods_receipt_update',has_table_privilege(
                'authenticated','public.goods_receipt_documents','UPDATE'
            ),
            'goods_receipt_line_update',has_table_privilege(
                'authenticated','public.goods_receipt_lines','UPDATE'
            ),
            'stock_update',has_table_privilege(
                'authenticated','public.product_stocks','UPDATE'
            ),
            'batch_update',has_table_privilege(
                'authenticated','public.product_batches','UPDATE'
            ),
            'movement_insert',has_table_privilege(
                'authenticated','public.stock_movements','INSERT'
            ),
            'ap_update',has_table_privilege(
                'authenticated','public.goods_receipt_ap_provisionals','UPDATE'
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
