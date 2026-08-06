Okay clearly the fun project yeah project under pen projecting original project yeah plus come on seven yeah by your planting set oh yeah hello hello hello are in same yeah plus nanti process carrying process yeah ninety chat okay clear addition yeah limapi then the terminal like this
-- SELECT-only and aggregate-only.

WITH expected_tables(table_name) AS (
    VALUES
        ('sales_return_documents'),('sales_return_lines'),
        ('sales_return_fifo_restorations'),('sales_return_refunds'),
        ('sales_return_audit')
), expected_routines(routine_name) AS (
    VALUES
        ('save_sales_return_draft'),('post_sales_return'),
        ('cancel_sales_return_draft'),('list_returnable_sales')
), expected_triggers(trigger_name) AS (
    VALUES
        ('guard_final_sales_return_document'),
        ('guard_final_sales_return_lines'),
        ('guard_final_sales_return_refunds'),
        ('guard_final_sales_return_restorations'),
        ('guard_sales_return_audit_immutable')
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        count(*)::BIGINT violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations
    WHERE version='20260803010000'

    UNION ALL
    SELECT 'required_sales_return_tables',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.'||table_name) IS NULL
        )=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE to_regclass('public.'||table_name) IS NULL
        ),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(table_name ORDER BY table_name) FILTER (
                WHERE to_regclass('public.'||table_name) IS NULL
            ),'[]'::JSONB
        ))
    FROM expected_tables

    UNION ALL
    SELECT 'required_sales_return_routines',
        CASE WHEN count(*) FILTER (WHERE NOT EXISTS (
            SELECT 1 FROM pg_proc routine
            WHERE routine.pronamespace='public'::regnamespace
              AND routine.proname=expected.routine_name
        ))=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE NOT EXISTS (
            SELECT 1 FROM pg_proc routine
            WHERE routine.pronamespace='public'::regnamespace
              AND routine.proname=expected.routine_name
        )),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(routine_name ORDER BY routine_name) FILTER (
                WHERE NOT EXISTS (
                    SELECT 1 FROM pg_proc routine
                    WHERE routine.pronamespace='public'::regnamespace
                      AND routine.proname=expected.routine_name
                )
            ),'[]'::JSONB
        ))
    FROM expected_routines expected

    UNION ALL
    SELECT 'required_sales_return_triggers',
        CASE WHEN count(*) FILTER (WHERE trigger.oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE trigger.oid IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(expected.trigger_name ORDER BY expected.trigger_name)
                FILTER (WHERE trigger.oid IS NULL),'[]'::JSONB
        ))
    FROM expected_triggers expected
    LEFT JOIN pg_trigger trigger
      ON trigger.tgname=expected.trigger_name AND NOT trigger.tgisinternal

    UNION ALL
    SELECT 'browser_sales_return_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_sales_return_draft(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated','public.post_sales_return(uuid,bigint,uuid)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.cancel_sales_return_draft(uuid,bigint,text)','EXECUTE'
            )
            AND has_function_privilege(
                'authenticated','public.list_returnable_sales(text,integer)',
                'EXECUTE'
            )
            THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_sales_return_draft(uuid,bigint,uuid,uuid,text,text,jsonb,jsonb)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated','public.post_sales_return(uuid,bigint,uuid)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.cancel_sales_return_draft(uuid,bigint,text)','EXECUTE'
            )
            AND has_function_privilege(
                'authenticated','public.list_returnable_sales(text,integer)',
                'EXECUTE'
            ) THEN 0 ELSE 1 END,
        jsonb_build_object('expected_rpc_rows',4)

    UNION ALL
    SELECT 'browser_direct_sales_return_write_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('direct_write_table_count',count(*))
    FROM expected_tables expected
    WHERE has_table_privilege(
        'authenticated','public.'||expected.table_name,'INSERT,UPDATE,DELETE'
    )

    UNION ALL
    SELECT 'posted_return_source_quantity_limit',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('source_line_count',count(*))
    FROM (
        SELECT line.company_id,line.source_sales_detail_id
        FROM public.sales_return_lines line
        JOIN public.sales_return_documents document
          ON document.company_id=line.company_id AND document.id=line.document_id
         AND document.status='POSTED'
        JOIN public.sales_details source
          ON source.company_id=line.company_id
         AND source.id=line.source_sales_detail_id
        GROUP BY line.company_id,line.source_sales_detail_id,source.qty
        HAVING sum(line.quantity_uom)>source.qty
    ) invalid

    UNION ALL
    SELECT 'posted_return_refund_total',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.sales_return_documents document
    WHERE document.status='POSTED' AND document.refund_total<>(
        SELECT COALESCE(sum(refund.amount),0)
        FROM public.sales_return_refunds refund
        WHERE refund.company_id=document.company_id
          AND refund.document_id=document.id
    )

    UNION ALL
    SELECT 'posted_physical_return_movement_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('restoration_count',count(*))
    FROM public.sales_return_fifo_restorations restoration
    JOIN public.sales_return_documents document
      ON document.company_id=restoration.company_id
     AND document.id=restoration.document_id AND document.status='POSTED'
    WHERE NOT EXISTS (
        SELECT 1 FROM public.stock_movements movement
        WHERE movement.company_id=restoration.company_id
          AND movement.reference_table='sales_return_documents'
          AND movement.reference_id=restoration.document_id
          AND movement.source_line_id=restoration.id
          AND movement.movement_type='SALES_RETURN'::public.stock_movement_type
          AND movement.movement_status='POSTED'
    )

    UNION ALL
    SELECT 'posted_no_physical_return_without_stock',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('line_count',count(*))
    FROM public.sales_return_lines line
    JOIN public.sales_return_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
     AND document.status='POSTED'
    WHERE line.return_condition='NO_PHYSICAL_RETURN'
      AND EXISTS (
          SELECT 1 FROM public.sales_return_fifo_restorations restoration
          WHERE restoration.company_id=line.company_id
            AND restoration.return_line_id=line.id
      )

    UNION ALL
    SELECT 'posted_return_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.sales_return_documents document
    LEFT JOIN public.financial_events event
      ON event.company_id=document.company_id
     AND event.id=document.financial_event_id
    WHERE document.status='POSTED' AND (
        event.id IS NULL OR event.source_table<>'sales_return_documents'
        OR event.source_id<>document.id OR event.root_sales_id<>document.source_sales_id
        OR event.system_event_key<>'SALES_RETURN'
        OR event.status<>'HOLD'::public.event_status
    )

    UNION ALL
    SELECT 'sales_return_runtime_inventory','INFO',0,
        jsonb_build_object(
            'documents',count(*),
            'drafts',count(*) FILTER (WHERE status='DRAFT'),
            'posted',count(*) FILTER (WHERE status='POSTED'),
            'canceled',count(*) FILTER (WHERE status='CANCELED'),
            'refund_total',COALESCE(sum(refund_total) FILTER (
                WHERE status='POSTED'
            ),0)
        )
    FROM public.sales_return_documents
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
