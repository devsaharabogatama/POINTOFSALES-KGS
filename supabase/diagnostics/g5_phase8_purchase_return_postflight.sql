-- G5 phase 8 postflight: canonical Purchase Return foundation.
-- SAFETY: SELECT-only; aggregate metadata/data only.

WITH expected_tables(table_name) AS (
    VALUES
        ('purchase_return_documents'),
        ('purchase_return_lines'),
        ('purchase_return_fifo_allocations'),
        ('purchase_return_ap_adjustments'),
        ('purchase_return_audit')
), expected_routines(routine_name) AS (
    VALUES
        ('save_purchase_return_draft'),
        ('review_purchase_return'),
        ('post_purchase_return'),
        ('cancel_purchase_return_draft')
), expected_triggers(trigger_name) AS (
    VALUES
        ('g5_guard_purchase_return_documents'),
        ('g5_guard_purchase_return_lines'),
        ('g5_guard_purchase_return_fifo'),
        ('g5_guard_purchase_return_ap'),
        ('g5_guard_purchase_return_audit')
), stock_reconciliation AS (
    SELECT stock.company_id,stock.product_id,stock.warehouse_id,stock.stock_qty,
           COALESCE((SELECT sum(movement.qty_change)
             FROM public.stock_movements movement
             WHERE movement.company_id=stock.company_id
               AND movement.product_id=stock.product_id
               AND movement.warehouse_id=stock.warehouse_id),0) AS movement_qty,
           COALESCE((SELECT sum(batch.qty_remaining)
             FROM public.product_batches batch
             WHERE batch.company_id=stock.company_id
               AND batch.product_id=stock.product_id
               AND batch.warehouse_id=stock.warehouse_id),0) AS fifo_qty
    FROM public.product_stocks stock
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
           CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
           CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
           jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260806070000'

    UNION ALL

    SELECT 'required_purchase_return_tables',
           CASE WHEN count(*) FILTER(WHERE c.oid IS NULL)=0
                THEN 'PASS' ELSE 'FAIL' END,
           count(*) FILTER(WHERE c.oid IS NULL),
           jsonb_build_object(
             'expected',count(*),
             'missing',COALESCE(jsonb_agg(e.table_name ORDER BY e.table_name)
               FILTER(WHERE c.oid IS NULL),'[]'::jsonb)
           )
    FROM expected_tables e
    LEFT JOIN pg_catalog.pg_namespace n ON n.nspname='public'
    LEFT JOIN pg_catalog.pg_class c
      ON c.relnamespace=n.oid AND c.relname=e.table_name
     AND c.relkind IN('r','p')

    UNION ALL

    SELECT 'required_purchase_return_routines',
           CASE WHEN count(*) FILTER(WHERE p.oid IS NULL)=0
                THEN 'PASS' ELSE 'FAIL' END,
           count(*) FILTER(WHERE p.oid IS NULL),
           jsonb_build_object(
             'expected',count(*),
             'missing',COALESCE(jsonb_agg(e.routine_name ORDER BY e.routine_name)
               FILTER(WHERE p.oid IS NULL),'[]'::jsonb)
           )
    FROM expected_routines e
    LEFT JOIN pg_catalog.pg_namespace n ON n.nspname='public'
    LEFT JOIN pg_catalog.pg_proc p
      ON p.pronamespace=n.oid AND p.proname=e.routine_name

    UNION ALL

    SELECT 'required_purchase_return_triggers',
           CASE WHEN count(*) FILTER(WHERE t.oid IS NULL)=0
                THEN 'PASS' ELSE 'FAIL' END,
           count(*) FILTER(WHERE t.oid IS NULL),
           jsonb_build_object('expected',count(*),'trigger_rows',count(t.oid))
    FROM expected_triggers e
    LEFT JOIN pg_catalog.pg_trigger t
      ON t.tgname=e.trigger_name AND NOT t.tgisinternal

    UNION ALL

    SELECT 'purchase_return_rls',
           CASE WHEN count(*) FILTER(WHERE NOT c.relrowsecurity)=0
                     AND count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
           count(*) FILTER(WHERE NOT c.relrowsecurity)
             + CASE WHEN count(*)=5 THEN 0 ELSE 1 END,
           jsonb_build_object('table_rows',count(*))
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    JOIN expected_tables e ON e.table_name=c.relname
    WHERE n.nspname='public' AND c.relkind IN('r','p')

    UNION ALL

    SELECT 'browser_purchase_return_rpc_boundary',
           CASE WHEN
             has_function_privilege('authenticated',
              'public.save_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)','EXECUTE')
             AND has_function_privilege('authenticated',
              'public.review_purchase_return(uuid,bigint,text,text)','EXECUTE')
             AND has_function_privilege('authenticated',
              'public.post_purchase_return(uuid,bigint,uuid)','EXECUTE')
             AND has_function_privilege('authenticated',
              'public.cancel_purchase_return_draft(uuid,bigint,text)','EXECUTE')
             AND NOT has_function_privilege('anon',
              'public.post_purchase_return(uuid,bigint,uuid)','EXECUTE')
           THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN
             has_function_privilege('authenticated',
              'public.save_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)','EXECUTE')
             AND has_function_privilege('authenticated',
              'public.review_purchase_return(uuid,bigint,text,text)','EXECUTE')
             AND has_function_privilege('authenticated',
              'public.post_purchase_return(uuid,bigint,uuid)','EXECUTE')
             AND has_function_privilege('authenticated',
              'public.cancel_purchase_return_draft(uuid,bigint,text)','EXECUTE')
             AND NOT has_function_privilege('anon',
              'public.post_purchase_return(uuid,bigint,uuid)','EXECUTE')
           THEN 0 ELSE 1 END,
           jsonb_build_object('expected_authenticated_rpc_rows',4)

    UNION ALL

    SELECT 'browser_direct_purchase_return_write_boundary',
           CASE WHEN NOT (
             has_table_privilege('authenticated','public.purchase_return_documents','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.purchase_return_lines','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.purchase_return_fifo_allocations','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.purchase_return_ap_adjustments','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.product_stocks','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.product_batches','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.stock_movements','INSERT,UPDATE,DELETE')
           ) THEN 'PASS' ELSE 'FAIL' END,
           CASE WHEN NOT (
             has_table_privilege('authenticated','public.purchase_return_documents','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.purchase_return_lines','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.purchase_return_fifo_allocations','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.purchase_return_ap_adjustments','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.product_stocks','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.product_batches','INSERT,UPDATE,DELETE')
             OR has_table_privilege('authenticated','public.stock_movements','INSERT,UPDATE,DELETE')
           ) THEN 0 ELSE 1 END,
           jsonb_build_object('direct_write',FALSE)

    UNION ALL

    SELECT 'posted_purchase_return_lifecycle_shape',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('row_count',count(*))
    FROM public.purchase_return_documents document
    WHERE document.status='POSTED' AND (
      document.review_status<>'APPROVED' OR document.reviewed_by IS NULL
      OR document.reviewed_at IS NULL OR document.handed_over_at IS NULL
      OR document.posted_by IS NULL OR document.posted_at IS NULL
      OR document.posting_idempotency_key IS NULL
      OR document.financial_event_id IS NULL
    )

    UNION ALL

    SELECT 'nonfinal_purchase_return_with_final_effect',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('document_count',count(*))
    FROM public.purchase_return_documents document
    WHERE document.status<>'POSTED' AND (
      document.financial_event_id IS NOT NULL
      OR EXISTS(SELECT 1 FROM public.purchase_return_fifo_allocations allocation
        WHERE allocation.company_id=document.company_id
          AND allocation.document_id=document.id)
      OR EXISTS(SELECT 1 FROM public.purchase_return_ap_adjustments adjustment
        WHERE adjustment.company_id=document.company_id
          AND adjustment.document_id=document.id)
      OR EXISTS(SELECT 1 FROM public.stock_movements movement
        WHERE movement.company_id=document.company_id
          AND movement.reference_table='purchase_return_documents'
          AND movement.reference_id=document.id)
    )

    UNION ALL

    SELECT 'posted_purchase_return_line_effect_coverage',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('line_count',count(*))
    FROM public.purchase_return_lines line
    JOIN public.purchase_return_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
     AND document.status='POSTED'
    WHERE NOT EXISTS(SELECT 1 FROM public.purchase_return_fifo_allocations allocation
      WHERE allocation.company_id=line.company_id
        AND allocation.return_line_id=line.id)
       OR NOT EXISTS(SELECT 1 FROM public.purchase_return_ap_adjustments adjustment
      WHERE adjustment.company_id=line.company_id
        AND adjustment.return_line_id=line.id)

    UNION ALL

    SELECT 'posted_purchase_return_movement_coverage',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('allocation_count',count(*))
    FROM public.purchase_return_fifo_allocations allocation
    WHERE NOT EXISTS(SELECT 1 FROM public.stock_movements movement
      WHERE movement.company_id=allocation.company_id
        AND movement.reference_table='purchase_return_documents'
        AND movement.reference_id=allocation.document_id
        AND movement.source_line_id=allocation.id
        AND movement.movement_type='PURCHASE_RETURN'
        AND movement.qty_change=-allocation.quantity_base)

    UNION ALL

    SELECT 'posted_purchase_return_financial_event_coverage',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('document_count',count(*))
    FROM public.purchase_return_documents document
    LEFT JOIN public.financial_events event
      ON event.company_id=document.company_id
     AND event.id=document.financial_event_id
    WHERE document.status='POSTED' AND (
      event.id IS NULL OR event.status<>'HOLD'
      OR event.system_event_key<>'PURCHASE_RETURN'
      OR event.source_table<>'purchase_return_documents'
      OR event.source_id<>document.id
    )

    UNION ALL

    SELECT 'cumulative_purchase_return_quantity',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('allocation_count',count(*))
    FROM (
      SELECT source.id
      FROM public.goods_receipt_condition_allocations source
      JOIN public.purchase_return_lines line
        ON line.company_id=source.company_id
       AND line.source_condition_allocation_id=source.id
      JOIN public.purchase_return_documents document
        ON document.company_id=line.company_id AND document.id=line.document_id
       AND document.status='POSTED'
      GROUP BY source.id,source.quantity_base
      HAVING sum(line.return_base_qty)>source.quantity_base
    ) invalid

    UNION ALL

    SELECT 'cumulative_purchase_return_ap_adjustment',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('source_count',count(*))
    FROM (
      SELECT source.id
      FROM public.goods_receipt_ap_provisionals source
      JOIN public.purchase_return_ap_adjustments adjustment
        ON adjustment.company_id=source.company_id
       AND adjustment.source_ap_provisional_id=source.id
      JOIN public.purchase_return_documents document
        ON document.company_id=adjustment.company_id
       AND document.id=adjustment.document_id AND document.status='POSTED'
      GROUP BY source.id,source.amount
      HAVING sum(adjustment.amount)>source.amount
    ) invalid

    UNION ALL

    SELECT 'stock_balance_movement_reconciliation',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE stock_qty<>movement_qty

    UNION ALL

    SELECT 'stock_balance_fifo_reconciliation',
           CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
           jsonb_build_object('pair_count',count(*))
    FROM stock_reconciliation
    WHERE fifo_qty<0 OR (stock_qty>=0 AND fifo_qty<>stock_qty)

    UNION ALL

    SELECT 'purchase_return_runtime_inventory','INFO',0,
           jsonb_build_object(
             'documents',count(*),
             'drafts',count(*) FILTER(WHERE status='DRAFT'),
             'posted',count(*) FILTER(WHERE status='POSTED'),
             'canceled',count(*) FILTER(WHERE status='CANCELED'),
             'return_base_qty',COALESCE(sum(total_return_base_qty)
               FILTER(WHERE status='POSTED'),0),
             'ap_adjustment_total',COALESCE(sum(provisional_ap_adjustment_total)
               FILTER(WHERE status='POSTED'),0)
           )
    FROM public.purchase_return_documents
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
  CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;
