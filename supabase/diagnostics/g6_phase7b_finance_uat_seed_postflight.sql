-- G6 phase 7B Finance UAT seed postflight.
-- SAFETY: SELECT-only; returns aggregate assertions and human-readable IDs.

WITH seed_product AS (
    SELECT product.company_id,product.id AS product_id
    FROM public.products product
    WHERE upper(btrim(product.sku))='UAT-FIN-001'
), seed_opening AS (
    SELECT document.company_id,document.id AS document_id,
           document.financial_event_id,document.total_cost
    FROM public.opening_stock_documents document
    JOIN public.opening_stock_lines line
      ON line.company_id=document.company_id
     AND line.document_id=document.id
    JOIN seed_product product
      ON product.company_id=line.company_id
     AND product.product_id=line.product_id
), seed_adjustment AS (
    SELECT document.company_id,document.id AS document_id,
           document.gain_financial_event_id,document.total_gain_value
    FROM public.stock_adjustment_documents document
    JOIN public.stock_adjustment_lines line
      ON line.company_id=document.company_id
     AND line.document_id=document.id
    JOIN seed_product product
      ON product.company_id=line.company_id
     AND product.product_id=line.product_id
), checks AS (
    SELECT
        'uat_seed_product_identity'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*)-1)::BIGINT AS violation_rows,
        jsonb_build_object('product_count',count(*)) AS details
    FROM seed_product

    UNION ALL

    SELECT
        'uat_stock_balance',
        CASE WHEN count(*)=1
                   AND min(stock.stock_qty)=105
                   AND max(stock.stock_qty)=105
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE stock.stock_qty<>105),
        jsonb_build_object(
            'balance_rows',count(*),
            'stock_qty',COALESCE(sum(stock.stock_qty),0)
        )
    FROM public.product_stocks stock
    JOIN seed_product product
      ON product.company_id=stock.company_id
     AND product.product_id=stock.product_id

    UNION ALL

    SELECT
        'uat_stock_fifo_reconciliation',
        CASE WHEN COALESCE(sum(batch.qty_remaining),0)=105
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN COALESCE(sum(batch.qty_remaining),0)=105 THEN 0 ELSE 1 END,
        jsonb_build_object(
            'remaining_base_qty',COALESCE(sum(batch.qty_remaining),0),
            'remaining_value',COALESCE(sum(
                batch.qty_remaining*batch.cogs_unit
            ),0)
        )
    FROM public.product_batches batch
    JOIN seed_product product
      ON product.company_id=batch.company_id
     AND product.product_id=batch.product_id

    UNION ALL

    SELECT
        'uat_stock_movement_reconciliation',
        CASE WHEN count(*)=2 AND COALESCE(sum(movement.qty_change),0)=105
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=2 AND COALESCE(sum(movement.qty_change),0)=105
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'movement_rows',count(*),
            'quantity_change',COALESCE(sum(movement.qty_change),0)
        )
    FROM public.stock_movements movement
    JOIN seed_product product
      ON product.company_id=movement.company_id
     AND product.product_id=movement.product_id

    UNION ALL

    SELECT
        'uat_opening_stock_source',
        CASE WHEN count(*)=1
                   AND min(opening.total_cost)=5000000
                   AND bool_and(document.status='POSTED')
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(
            WHERE opening.total_cost<>5000000 OR document.status<>'POSTED'
        ),
        jsonb_build_object(
            'document_count',count(*),
            'total_cost',COALESCE(sum(opening.total_cost),0)
        )
    FROM seed_opening opening
    JOIN public.opening_stock_documents document
      ON document.company_id=opening.company_id
     AND document.id=opening.document_id

    UNION ALL

    SELECT
        'uat_opening_finance_final_effect',
        CASE WHEN count(*)=1
                   AND bool_and(event.status::TEXT='POSTED')
                   AND bool_and(journal.status='POSTED')
                   AND bool_and(journal.display_no ~
                       '^JUR/[0-9]{4}/[0-9]{2}/[0-9]{6}$')
                   AND bool_and(journal.total_debit=5000000)
                   AND bool_and(journal.total_credit=5000000)
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(
            WHERE event.status::TEXT<>'POSTED'
               OR journal.status<>'POSTED'
               OR journal.total_debit<>5000000
               OR journal.total_credit<>5000000
        ),
        jsonb_build_object(
            'journal_count',count(*),
            'journal_numbers',COALESCE(
                jsonb_agg(journal.display_no ORDER BY journal.display_no),
                '[]'::JSONB
            )
        )
    FROM seed_opening opening
    JOIN public.financial_events event
      ON event.company_id=opening.company_id
     AND event.id=opening.financial_event_id
    JOIN public.finance_journals journal
      ON journal.company_id=event.company_id
     AND journal.financial_event_id=event.id

    UNION ALL

    SELECT
        'uat_controlled_queue_final_effect',
        CASE WHEN count(*)=1
                   AND bool_and(run.status='COMPLETED')
                   AND bool_and(run.posted_count=1)
                   AND bool_and(run.failed_count=0)
                   AND bool_and(run.skipped_count=0)
                   AND bool_and(run.display_no ~
                       '^PST/[0-9]{4}/[0-9]{2}/[0-9]{6}$')
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(
            WHERE run.status<>'COMPLETED'
               OR run.posted_count<>1
               OR run.failed_count<>0
               OR run.skipped_count<>0
        ),
        jsonb_build_object(
            'queue_count',count(*),
            'queue_numbers',COALESCE(
                jsonb_agg(run.display_no ORDER BY run.display_no),
                '[]'::JSONB
            )
        )
    FROM seed_opening opening
    JOIN public.finance_posting_queue_items item
      ON item.company_id=opening.company_id
     AND item.financial_event_id=opening.financial_event_id
    JOIN public.finance_posting_queue_runs run
      ON run.company_id=item.company_id AND run.id=item.queue_run_id

    UNION ALL

    SELECT
        'uat_stock_gain_pending_analysis',
        CASE WHEN count(*)=1
                   AND bool_and(event.status::TEXT='HOLD')
                   AND bool_and(adjustment.total_gain_value=250000)
                   AND count(journal.id)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(
            WHERE event.status::TEXT<>'HOLD'
               OR adjustment.total_gain_value<>250000
               OR journal.id IS NOT NULL
        ),
        jsonb_build_object(
            'event_count',count(*),
            'hold_count',count(*) FILTER(WHERE event.status::TEXT='HOLD'),
            'gain_value',COALESCE(sum(adjustment.total_gain_value),0),
            'journal_count',count(journal.id)
        )
    FROM seed_adjustment adjustment
    JOIN public.financial_events event
      ON event.company_id=adjustment.company_id
     AND event.id=adjustment.gain_financial_event_id
    LEFT JOIN public.finance_journals journal
      ON journal.company_id=event.company_id
     AND journal.financial_event_id=event.id
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY
    CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
