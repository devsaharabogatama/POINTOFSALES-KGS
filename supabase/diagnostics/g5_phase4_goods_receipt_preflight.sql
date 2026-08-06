-- G5 phase 4 preflight: canonical Goods Receipt readiness.
-- SAFETY: SELECT-only; aggregate metadata/data only; no business names.

WITH required_versions(version) AS (
    VALUES ('20260805234500'),('20260806010000')
), confirmed_orders AS (
    SELECT d.id,d.company_id,d.store_id,d.destination_warehouse_id,d.supplier_id,
           d.status,d.line_count
    FROM public.supplier_order_documents d
    WHERE d.status IN ('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
), order_line_allocation AS (
    SELECT l.id,l.company_id,l.document_id,l.product_id,l.ordered_uom_id,
           l.ordered_base_qty,l.estimated_unit_price,
           COALESCE(sum(a.allocated_base_qty),0) AS allocated_base_qty
    FROM public.supplier_order_lines l
    LEFT JOIN public.supplier_order_request_allocations a
      ON a.company_id=l.company_id AND a.supplier_order_line_id=l.id
    GROUP BY l.id
), stock_reconciliation AS (
    SELECT ps.company_id,ps.product_id,ps.warehouse_id,
           ps.stock_qty,
           COALESCE((SELECT sum(sm.qty_change) FROM public.stock_movements sm
               WHERE sm.company_id=ps.company_id AND sm.product_id=ps.product_id
                 AND sm.warehouse_id=ps.warehouse_id),0) AS movement_qty,
           COALESCE((SELECT sum(pb.qty_remaining) FROM public.product_batches pb
               WHERE pb.company_id=ps.company_id AND pb.product_id=ps.product_id
                 AND pb.warehouse_id=ps.warehouse_id),0) AS fifo_qty
    FROM public.product_stocks ps
), checks AS (
    SELECT 'g5_goods_receipt_dependencies'::text AS check_name,
           CASE WHEN count(*) FILTER(WHERE m.version IS NULL)=0
                THEN 'PASS' ELSE 'BLOCKER' END AS status,
           jsonb_build_object('expected',count(*),'missing',COALESCE(
             jsonb_agg(r.version ORDER BY r.version) FILTER(WHERE m.version IS NULL),'[]'::jsonb)) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version=r.version

    UNION ALL
    SELECT 'canonical_goods_receipt_schema_state','SETUP',jsonb_build_object(
        'missing_tables',(SELECT COALESCE(jsonb_agg(name ORDER BY name),'[]'::jsonb)
          FROM (SELECT name FROM (VALUES
            ('goods_receipt_documents'),('goods_receipt_lines'),
            ('goods_receipt_condition_allocations'),('goods_receipt_audit'),
            ('goods_receipt_ap_provisionals')) expected(name)
            WHERE to_regclass('public.'||name) IS NULL) missing),
        'expected_tables',5,
        'posting_rpc_exists',to_regprocedure('public.post_goods_receipt(uuid,bigint,uuid)') IS NOT NULL,
        'save_rpc_exists',to_regprocedure('public.save_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)') IS NOT NULL
    )

    UNION ALL
    SELECT 'goods_receipt_batch_lineage_state','SETUP',jsonb_build_object(
        'missing_columns',COALESCE(jsonb_agg(e.column_name ORDER BY e.column_name)
          FILTER(WHERE c.column_name IS NULL),'[]'::jsonb)
    )
    FROM (VALUES ('goods_receipt_line_id'),('supplier_order_line_id')) e(column_name)
    LEFT JOIN information_schema.columns c ON c.table_schema='public'
      AND c.table_name='product_batches' AND c.column_name=e.column_name

    UNION ALL
    SELECT 'confirmed_supplier_order_inventory','INFO',jsonb_build_object(
        'orders',count(*),'companies',count(DISTINCT company_id),
        'stores',count(DISTINCT store_id),'partially_received',count(*) FILTER(WHERE status='PARTIALLY_RECEIVED'),
        'received',count(*) FILTER(WHERE status='RECEIVED'))
    FROM confirmed_orders

    UNION ALL
    SELECT 'invalid_confirmed_order_reference',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('row_count',count(*))
    FROM confirmed_orders o
    LEFT JOIN public.stores s ON s.company_id=o.company_id AND s.id=o.store_id
    LEFT JOIN public.warehouses w ON w.company_id=o.company_id AND w.id=o.destination_warehouse_id
    LEFT JOIN public.suppliers supplier ON supplier.company_id=o.company_id AND supplier.id=o.supplier_id
    WHERE s.id IS NULL OR s.status<>'ACTIVE' OR w.id IS NULL OR NOT w.is_active
       OR NOT w.is_purchase_destination OR supplier.id IS NULL OR NOT supplier.is_active

    UNION ALL
    SELECT 'invalid_confirmed_order_line_reference',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('row_count',count(*))
    FROM order_line_allocation l
    JOIN confirmed_orders o ON o.company_id=l.company_id AND o.id=l.document_id
    LEFT JOIN public.products p ON p.company_id=l.company_id AND p.id=l.product_id
    LEFT JOIN public.product_uoms pu ON pu.company_id=l.company_id
      AND pu.product_id=l.product_id AND pu.uom_id=l.ordered_uom_id
    LEFT JOIN public.uoms u ON u.company_id=l.company_id AND u.id=l.ordered_uom_id
    WHERE p.id IS NULL OR NOT p.is_active OR p.is_bundle OR pu.id IS NULL
       OR NOT pu.is_active OR NOT pu.purchase_allowed OR u.id IS NULL OR NOT u.is_active
       OR l.ordered_base_qty<=0 OR l.estimated_unit_price<0

    UNION ALL
    SELECT 'confirmed_order_line_without_request_allocation',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('line_count',count(*))
    FROM order_line_allocation l
    JOIN confirmed_orders o ON o.company_id=l.company_id AND o.id=l.document_id
    WHERE l.allocated_base_qty<=0 OR l.allocated_base_qty>l.ordered_base_qty

    UNION ALL
    SELECT 'confirmed_order_store_terminal_readiness',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('store_count',count(*))
    FROM (SELECT DISTINCT o.company_id,o.store_id FROM confirmed_orders o) scope
    WHERE NOT EXISTS(SELECT 1 FROM public.pos_terminals terminal
      WHERE terminal.company_id=scope.company_id AND terminal.store_id=scope.store_id
        AND terminal.status='ACTIVE')

    UNION ALL
    SELECT 'confirmed_order_damaged_warehouse_scope',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
      jsonb_build_object('companies_without_damaged_warehouse',count(*))
    FROM (SELECT DISTINCT company_id FROM confirmed_orders) scope
    WHERE NOT EXISTS(SELECT 1 FROM public.warehouses w
      WHERE w.company_id=scope.company_id AND w.is_active AND w.warehouse_type='DAMAGED')

    UNION ALL
    SELECT 'goods_receipt_transaction_category_readiness',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('company_count',count(*))
    FROM (SELECT DISTINCT company_id FROM confirmed_orders) scope
    WHERE NOT EXISTS(SELECT 1 FROM public.transaction_categories tc
      WHERE tc.company_id=scope.company_id AND tc.system_key='GOODS_RECEIPT' AND tc.is_active)

    UNION ALL
    SELECT 'goods_receipt_finance_function_catalog','INFO',jsonb_build_object(
      'system_event_exists',EXISTS(SELECT 1 FROM public.system_events
        WHERE system_key='GOODS_RECEIPT' AND is_active),
      'required_functions',COALESCE((SELECT to_jsonb(required_account_functions)
        FROM public.system_events WHERE system_key='GOODS_RECEIPT'),'[]'::jsonb))

    UNION ALL
    SELECT 'open_negative_stock_replenishment_scope','INFO',jsonb_build_object(
      'allocation_rows',count(*),'companies',count(DISTINCT company_id),
      'remaining_base_qty',COALESCE(sum(shortage_base_qty-replenished_base_qty),0))
    FROM public.negative_stock_sale_allocations WHERE reconciled_at IS NULL

    UNION ALL
    SELECT 'stock_balance_movement_reconciliation',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation WHERE stock_qty<>movement_qty

    UNION ALL
    SELECT 'nonnegative_fifo_not_exceeding_stock',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
      jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation WHERE fifo_qty<0 OR (stock_qty>=0 AND fifo_qty<>stock_qty)

    UNION ALL
    SELECT 'legacy_purchase_inventory','INFO',jsonb_build_object(
      'headers',count(*),'companies',count(DISTINCT company_id),
      'details',(SELECT count(*) FROM public.purchases_details))
    FROM public.purchases_headers

    UNION ALL
    SELECT 'invalid_legacy_purchase_shape',
      CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
      jsonb_build_object('row_count',count(*))
    FROM public.purchases_headers h
    WHERE h.subtotal<0 OR h.grand_total<0 OR h.paid_amount<0
       OR h.paid_amount>h.grand_total

    UNION ALL
    SELECT 'direct_goods_receipt_write_boundary','INFO',jsonb_build_object(
      'legacy_header_insert',has_table_privilege('authenticated','public.purchases_headers','INSERT'),
      'legacy_detail_insert',has_table_privilege('authenticated','public.purchases_details','INSERT'),
      'stock_update',has_table_privilege('authenticated','public.product_stocks','UPDATE'),
      'batch_insert',has_table_privilege('authenticated','public.product_batches','INSERT'),
      'movement_insert',has_table_privilege('authenticated','public.stock_movements','INSERT'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
  WHEN 'SETUP' THEN 3 WHEN 'PASS' THEN 4 ELSE 5 END,check_name;
