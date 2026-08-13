-- SLD-R4 postflight: explicit Delivery-fee refund on Sales Return.
-- SAFETY: SELECT-only; aggregate contract evidence only.

WITH expected_columns(column_name) AS (
    VALUES
        ('source_delivery_fee_amount_snapshot'),
        ('delivery_fee_refund_requested'),
        ('delivery_fee_refund_amount'),
        ('delivery_fee_refund_decided_by'),
        ('delivery_fee_refund_decided_at')
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations
    WHERE version='20260811150000'

    UNION ALL
    SELECT 'required_return_columns',
        CASE WHEN count(column_info.column_name)=5 THEN 'PASS' ELSE 'FAIL' END,
        5-count(column_info.column_name),
        jsonb_build_object(
            'expected',5,
            'missing',COALESCE(jsonb_agg(expected.column_name ORDER BY expected.column_name)
                FILTER(WHERE column_info.column_name IS NULL),'[]'::JSONB)
        )
    FROM expected_columns expected
    LEFT JOIN information_schema.columns column_info
      ON column_info.table_schema='public'
     AND column_info.table_name='sales_return_documents'
     AND column_info.column_name=expected.column_name

    UNION ALL
    SELECT 'required_return_routines',
        CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,4-count(*),
        jsonb_build_object('expected',4,'routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE (namespace.nspname,routine.proname) IN (
        ('public','save_sales_return_draft'),
        ('public','save_sales_return_draft_with_delivery_fee'),
        ('private','save_sales_return_draft_sld_r4'),
        ('private','save_sales_return_draft_sld_r4_core')
    )

    UNION ALL
    SELECT 'required_return_guards',
        CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,4-count(*),
        jsonb_build_object('expected',4,'object_rows',count(*))
    FROM (
        SELECT constraint_info.oid
        FROM pg_constraint constraint_info
        WHERE constraint_info.conname='sales_return_delivery_fee_refund_contract'
          AND constraint_info.conrelid='public.sales_return_documents'::regclass
        UNION ALL
        SELECT index_info.indexrelid
        FROM pg_index index_info
        JOIN pg_class index_class ON index_class.oid=index_info.indexrelid
        WHERE index_class.relname='uq_sales_return_one_posted_delivery_fee_refund'
          AND index_info.indrelid='public.sales_return_documents'::regclass
        UNION ALL
        SELECT trigger_info.oid
        FROM pg_trigger trigger_info
        WHERE trigger_info.tgrelid='public.sales_return_documents'::regclass
          AND trigger_info.tgname='sld_r4_validate_delivery_fee_refund_post'
          AND trigger_info.tgenabled<>'D'
        UNION ALL
        SELECT trigger_info.oid
        FROM pg_trigger trigger_info
        WHERE trigger_info.tgrelid='public.financial_events'::regclass
          AND trigger_info.tgname='sld_r4_sales_refund_event_fee_snapshot'
          AND trigger_info.tgenabled<>'D'
    ) object_info

    UNION ALL
    SELECT 'invalid_posted_delivery_fee_refund',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.sales_return_documents document
    WHERE document.status='POSTED' AND (
        document.delivery_fee_refund_amount<0
        OR document.delivery_fee_refund_amount>
            document.source_delivery_fee_amount_snapshot
        OR (document.delivery_fee_refund_requested
            AND document.delivery_fee_refund_amount=0)
        OR (NOT document.delivery_fee_refund_requested
            AND document.delivery_fee_refund_amount<>0)
        OR (document.source_delivery_fee_amount_snapshot>0 AND (
            document.delivery_fee_refund_decided_by IS NULL
            OR document.delivery_fee_refund_decided_at IS NULL
        ))
    )

    UNION ALL
    SELECT 'posted_return_payment_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.sales_return_documents document
    WHERE document.status='POSTED' AND abs(
        document.refund_total-COALESCE((
            SELECT sum(refund.amount)
            FROM public.sales_return_refunds refund
            WHERE refund.company_id=document.company_id
              AND refund.document_id=document.id
        ),0)
    )>0.0001

    UNION ALL
    SELECT 'sales_refund_event_delivery_fee_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('event_count',count(*))
    FROM public.sales_return_documents document
    JOIN public.financial_events event
      ON event.company_id=document.company_id
     AND event.source_table='sales_return_documents'
     AND event.source_id=document.id
     AND event.event_type='SALES_REFUND'::public.event_type
    WHERE document.status='POSTED'
      AND document.delivery_fee_refund_amount>0
      AND (
          NOT COALESCE(event.amounts?'deliveryFeeRefund',FALSE)
          OR (event.amounts->>'deliveryFeeRefund')::NUMERIC<>
                document.delivery_fee_refund_amount
      )

    UNION ALL
    SELECT 'browser_return_write_boundary',
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.sales_return_documents','INSERT,UPDATE,DELETE'
        ) AND has_function_privilege(
            'authenticated',
            'public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)',
            'EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.sales_return_documents','INSERT,UPDATE,DELETE'
        ) AND has_function_privilege(
            'authenticated',
            'public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)',
            'EXECUTE'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated','public.sales_return_documents','INSERT,UPDATE,DELETE'
            ),
            'guarded_rpc',has_function_privilege(
                'authenticated',
                'public.save_sales_return_draft_with_delivery_fee(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb,boolean)',
                'EXECUTE'
            )
        )

    UNION ALL
    SELECT 'delivery_fee_return_runtime_inventory','INFO',0,
        jsonb_build_object(
            'delivery_sales',count(DISTINCT sale.id),
            'return_documents',count(DISTINCT document.id),
            'explicit_fee_refunds',count(DISTINCT document.id) FILTER(
                WHERE document.delivery_fee_refund_amount>0
            )
        )
    FROM public.sales_headers sale
    LEFT JOIN public.sales_return_documents document
      ON document.company_id=sale.company_id
     AND document.source_sales_id=sale.id
    WHERE sale.document_status='POSTED' AND sale.delivery_fee_amount>0

    UNION ALL
    SELECT 'sales_return_finance_boundary','DEFERRED',0,
        jsonb_build_object(
            'reason','SALE and SALES_REFUND posting expressions remain G6-controlled',
            'hold_events',count(*) FILTER(WHERE event.status='HOLD'),
            'posted_events',count(*) FILTER(WHERE event.status='POSTED')
        )
    FROM public.financial_events event
    WHERE event.event_type='SALES_REFUND'::public.event_type
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2
    WHEN 'DEFERRED' THEN 3 ELSE 4 END,check_name;
