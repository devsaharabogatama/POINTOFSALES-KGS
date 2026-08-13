-- SLD-R4 preflight: explicit Delivery-fee refund and closing regression.
-- SAFETY: SELECT-only, aggregate-only, and no business identity output.

WITH required_versions(version) AS (
    VALUES ('20260811140000'),('20260811143000')
), sale_return_amounts AS (
    SELECT
        document.company_id,
        document.id AS document_id,
        document.source_sales_id,
        document.status,
        document.refund_before_rounding,
        document.rounding_adjustment,
        document.refund_total,
        sale.delivery_fee_amount,
        sale.fulfillment_mode,
        COALESCE(sum(line.refund_before_rounding),0) AS product_refund_amount
    FROM public.sales_return_documents document
    JOIN public.sales_headers sale
      ON sale.company_id=document.company_id
     AND sale.id=document.source_sales_id
    LEFT JOIN public.sales_return_lines line
      ON line.company_id=document.company_id
     AND line.document_id=document.id
    GROUP BY document.company_id,document.id,document.source_sales_id,
        document.status,document.refund_before_rounding,
        document.rounding_adjustment,document.refund_total,
        sale.delivery_fee_amount,sale.fulfillment_mode
), return_coverage AS (
    SELECT
        sale.company_id,
        sale.id AS sales_id,
        sale.fulfillment_mode,
        sale.delivery_fee_amount,
        bool_and(
            detail.qty=COALESCE(returned.returned_qty,0)
        ) AS all_product_quantity_returned,
        COALESCE(sum(returned.returned_qty),0) AS returned_quantity
    FROM public.sales_headers sale
    JOIN public.sales_details detail
      ON detail.company_id=sale.company_id AND detail.sales_id=sale.id
    LEFT JOIN LATERAL (
        SELECT sum(line.quantity_uom) AS returned_qty
        FROM public.sales_return_lines line
        JOIN public.sales_return_documents document
          ON document.company_id=line.company_id
         AND document.id=line.document_id
         AND document.status='POSTED'
        WHERE line.company_id=detail.company_id
          AND line.source_sales_detail_id=detail.id
    ) returned ON TRUE
    WHERE sale.document_status='POSTED'
    GROUP BY sale.company_id,sale.id,sale.fulfillment_mode,
        sale.delivery_fee_amount
), checks AS (
    SELECT
        'sld_r4_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
                FILTER(WHERE migration.version IS NULL),'[]'::JSONB)
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'canonical_delivery_fee_return_schema_state','SETUP',
        jsonb_build_object(
            'missing_columns',COALESCE(jsonb_agg(expected.column_name
                ORDER BY expected.column_name) FILTER(WHERE column_state.column_name IS NULL),
                '[]'::JSONB),
            'expected_columns',count(*)
        )
    FROM (VALUES
        ('source_delivery_fee_amount_snapshot'),
        ('delivery_fee_refund_requested'),
        ('delivery_fee_refund_amount'),
        ('delivery_fee_refund_decided_by'),
        ('delivery_fee_refund_decided_at')
    ) expected(column_name)
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='sales_return_documents'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_delivery_fee_return_routine_state','SETUP',
        jsonb_build_object(
            'save_rpc_exists',to_regprocedure(
                'public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)'
            ) IS NOT NULL,
            'legacy_save_rpc_exists',to_regprocedure(
                'public.save_sales_return_draft(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)'
            ) IS NOT NULL,
            'post_rpc_exists',to_regprocedure(
                'public.post_sales_return(uuid,bigint,uuid)'
            ) IS NOT NULL
        )

    UNION ALL

    SELECT
        'posted_return_payment_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('document_count',count(*))
    FROM public.sales_return_documents document
    LEFT JOIN LATERAL (
        SELECT COALESCE(sum(refund.amount),0) AS refund_amount
        FROM public.sales_return_refunds refund
        WHERE refund.company_id=document.company_id
          AND refund.document_id=document.id
    ) payment ON TRUE
    WHERE document.status='POSTED'
      AND document.refund_total IS DISTINCT FROM payment.refund_amount

    UNION ALL

    SELECT
        'return_product_amount_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM sale_return_amounts amount
    WHERE amount.refund_before_rounding IS DISTINCT FROM
          amount.product_refund_amount

    UNION ALL

    SELECT
        'legacy_full_return_delivery_fee_decision_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'posted_return_sales',count(*),
            'delivery_fee_total',COALESCE(sum(coverage.delivery_fee_amount),0)
        )
    FROM return_coverage coverage
    WHERE coverage.all_product_quantity_returned
      AND coverage.fulfillment_mode='DELIVERY'
      AND coverage.delivery_fee_amount>0

    UNION ALL

    SELECT
        'open_draft_delivery_fee_normalization_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'draft_count',count(*),
            'suspected_delivery_fee_in_rounding',COALESCE(sum(
                amount.delivery_fee_amount
            ),0)
        )
    FROM sale_return_amounts amount
    WHERE amount.status='DRAFT'
      AND amount.delivery_fee_amount>0
      AND abs(
          amount.rounding_adjustment-amount.delivery_fee_amount
      )<=0.0001

    UNION ALL

    SELECT
        'partial_return_delivery_fee_auto_refund_risk',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('return_count',count(*))
    FROM sale_return_amounts amount
    JOIN return_coverage coverage
      ON coverage.company_id=amount.company_id
     AND coverage.sales_id=amount.source_sales_id
    WHERE amount.status='POSTED'
      AND amount.delivery_fee_amount>0
      AND NOT coverage.all_product_quantity_returned
      AND amount.refund_total>
          amount.product_refund_amount+amount.rounding_adjustment

    UNION ALL

    SELECT
        'sales_refund_event_delivery_fee_snapshot_state','SETUP',
        jsonb_build_object(
            'sales_refund_events',count(*),
            'events_with_delivery_fee_refund',count(*) FILTER(
                WHERE event.amounts ? 'deliveryFeeRefund'
            )
        )
    FROM public.financial_events event
    WHERE event.event_type='SALES_REFUND'::public.event_type

    UNION ALL

    SELECT
        'browser_direct_sales_return_write_boundary',
        CASE WHEN bool_or(has_table_privilege(
            'authenticated',relation_name,'INSERT,UPDATE,DELETE'
        )) THEN 'BLOCKER' ELSE 'PASS' END,
        jsonb_build_object('direct_write',COALESCE(bool_or(has_table_privilege(
            'authenticated',relation_name,'INSERT,UPDATE,DELETE'
        )),FALSE))
    FROM (VALUES
        ('public.sales_return_documents'),
        ('public.sales_return_lines'),
        ('public.sales_return_refunds'),
        ('public.sales_return_audit')
    ) target(relation_name)

    UNION ALL

    SELECT
        'nonterminal_offline_submission',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('submission_count',count(*))
    FROM public.pos_offline_sale_submissions
    WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')

    UNION ALL

    SELECT
        'sales_return_finance_boundary','DEFERRED',
        jsonb_build_object(
            'hold_events',count(*) FILTER(WHERE event.status='HOLD'),
            'posted_events',count(*) FILTER(WHERE event.status='POSTED'),
            'reason','SALE and SALES_REFUND posting expressions remain G6-controlled'
        )
    FROM public.financial_events event
    WHERE event.event_type='SALES_REFUND'::public.event_type

    UNION ALL

    SELECT
        'delivery_fee_return_inventory','INFO',
        jsonb_build_object(
            'delivery_sales',count(*) FILTER(
                WHERE sale.fulfillment_mode='DELIVERY'
            ),
            'delivery_sales_with_fee',count(*) FILTER(
                WHERE sale.fulfillment_mode='DELIVERY'
                  AND sale.delivery_fee_amount>0
            ),
            'return_documents',count(DISTINCT document.id),
            'posted_returns',count(DISTINCT document.id) FILTER(
                WHERE document.status='POSTED'
            )
        )
    FROM public.sales_headers sale
    LEFT JOIN public.sales_return_documents document
      ON document.company_id=sale.company_id
     AND document.source_sales_id=sale.id
    WHERE sale.document_status='POSTED'
)
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2 WHEN 'BACKFILL' THEN 3
    WHEN 'SETUP' THEN 4 WHEN 'PASS' THEN 5 WHEN 'DEFERRED' THEN 6 ELSE 7
END,check_name;
