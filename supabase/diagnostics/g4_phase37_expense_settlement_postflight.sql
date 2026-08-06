-- G4 phase 37 postflight: Expense settlement/return foundation.
-- SELECT-only and aggregate-only.

WITH expected_columns(table_name,column_name) AS (
    VALUES
        ('expense_documents','disbursed_by'),
        ('expense_documents','disbursed_at'),
        ('expense_documents','settled_by'),
        ('expense_documents','settled_at'),
        ('expense_settlements','store_id'),
        ('expense_settlements','transaction_category_id'),
        ('expense_settlements','outstanding_account_id_snapshot'),
        ('expense_settlements','document_master_version_snapshot'),
        ('expense_returns','store_id'),
        ('expense_returns','pos_terminal_id'),
        ('expense_returns','payment_settlement_route_snapshot'),
        ('expense_returns','payment_account_function_snapshot'),
        ('expense_returns','transaction_category_id'),
        ('expense_returns','outstanding_account_id_snapshot'),
        ('expense_returns','payment_account_id_snapshot'),
        ('expense_returns','document_master_version_snapshot')
), expected_tables(table_name) AS (
    VALUES
        ('expense_settlement_requests'),
        ('expense_additional_disbursement_requests')
), expected_routines(routine_name) AS (
    VALUES
        ('save_expense_settlement'),('review_expense_settlement'),
        ('return_expense_funds'),
        ('request_additional_expense_disbursement')
), expected_event_types(event_name) AS (
    VALUES ('EXPENSE_SETTLEMENT'),('EXPENSE_RETURN')
), document_totals AS (
    SELECT
        document.id,
        document.disbursed_amount,document.actual_expense_amount,
        document.returned_amount,document.outstanding_amount,
        COALESCE((
            SELECT sum(disbursement.amount)
            FROM public.expense_disbursements disbursement
            WHERE disbursement.company_id=document.company_id
              AND disbursement.document_id=document.id
        ),0) AS disbursed_detail,
        COALESCE((
            SELECT sum(settlement.actual_expense_amount)
            FROM public.expense_settlements settlement
            WHERE settlement.company_id=document.company_id
              AND settlement.document_id=document.id
        ),0) AS actual_detail,
        COALESCE((
            SELECT sum(returned.amount)
            FROM public.expense_returns returned
            WHERE returned.company_id=document.company_id
              AND returned.document_id=document.id
        ),0) AS returned_detail
    FROM public.expense_documents document
    GROUP BY document.id
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260803100000'

    UNION ALL
    SELECT 'required_settlement_tables',
        CASE WHEN count(*) FILTER (WHERE state.table_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE state.table_name IS NULL),
        jsonb_build_object('missing',COALESCE(
            jsonb_agg(expected.table_name ORDER BY expected.table_name)
                FILTER (WHERE state.table_name IS NULL),'[]'::jsonb))
    FROM expected_tables expected
    LEFT JOIN information_schema.tables state
      ON state.table_schema='public' AND state.table_name=expected.table_name

    UNION ALL
    SELECT 'required_settlement_columns',
        CASE WHEN count(*) FILTER (WHERE state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE state.column_name IS NULL),
        jsonb_build_object('missing',COALESCE(
            jsonb_agg(expected.table_name||'.'||expected.column_name
                ORDER BY expected.table_name,expected.column_name)
                FILTER (WHERE state.column_name IS NULL),'[]'::jsonb))
    FROM expected_columns expected
    LEFT JOIN information_schema.columns state
      ON state.table_schema='public' AND state.table_name=expected.table_name
     AND state.column_name=expected.column_name

    UNION ALL
    SELECT 'required_settlement_routines',
        CASE WHEN count(*) FILTER (WHERE state.oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE state.oid IS NULL),
        jsonb_build_object('missing',COALESCE(
            jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                FILTER (WHERE state.oid IS NULL),'[]'::jsonb))
    FROM expected_routines expected
    LEFT JOIN LATERAL (
        SELECT p.oid FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname=expected.routine_name
        LIMIT 1
    ) state ON TRUE

    UNION ALL
    SELECT 'required_settlement_event_types',
        CASE WHEN count(*) FILTER (WHERE state.enumlabel IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE state.enumlabel IS NULL),
        jsonb_build_object('missing',COALESCE(
            jsonb_agg(expected.event_name ORDER BY expected.event_name)
                FILTER (WHERE state.enumlabel IS NULL),'[]'::jsonb))
    FROM expected_event_types expected
    LEFT JOIN LATERAL (
        SELECT enum.enumlabel FROM pg_type type
        JOIN pg_namespace namespace ON namespace.oid=type.typnamespace
        JOIN pg_enum enum ON enum.enumtypid=type.oid
        WHERE namespace.nspname='public' AND type.typname='event_type'
          AND enum.enumlabel=expected.event_name LIMIT 1
    ) state ON TRUE

    UNION ALL
    SELECT 'required_settlement_rls',
        CASE WHEN count(*)=2 AND bool_and(class.relrowsecurity)
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=2 AND bool_and(class.relrowsecurity)
             THEN 0 ELSE 1 END::BIGINT,
        jsonb_build_object('table_rows',count(*))
    FROM pg_class class
    JOIN pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public'
      AND class.relname IN (
          'expense_settlement_requests',
          'expense_additional_disbursement_requests'
      )

    UNION ALL
    SELECT 'expense_document_lifecycle_trigger',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END::BIGINT,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger
    JOIN pg_class class ON class.oid=trigger.tgrelid
    JOIN pg_namespace namespace ON namespace.oid=class.relnamespace
    WHERE namespace.nspname='public'
      AND class.relname='expense_documents'
      AND trigger.tgname='expense_document_lifecycle_timestamps'
      AND NOT trigger.tgisinternal

    UNION ALL
    SELECT 'expense_document_event_total_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM document_totals total
    WHERE total.disbursed_amount<>total.disbursed_detail
       OR total.actual_expense_amount<>total.actual_detail
       OR total.returned_amount<>total.returned_detail
       OR total.outstanding_amount<>
          total.disbursed_detail-total.actual_detail-total.returned_detail

    UNION ALL
    SELECT 'expense_document_lifecycle_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_documents document
    WHERE (document.disbursed_amount>0 AND (
              document.disbursed_by IS NULL OR document.disbursed_at IS NULL))
       OR (document.disbursed_amount=0 AND (
              document.disbursed_by IS NOT NULL OR document.disbursed_at IS NOT NULL))
       OR (document.status IN ('SETTLED','SETTLED_NO_EXPENSE') AND (
              document.outstanding_amount<>0 OR document.settled_by IS NULL
              OR document.settled_at IS NULL))

    UNION ALL
    SELECT 'settlement_request_lifecycle_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_settlement_requests request
    WHERE request.actual_expense_amount<=0
       OR (request.status='SUBMITTED' AND request.reviewed_by IS NOT NULL)
       OR (request.status='APPROVED' AND request.reviewed_by IS NULL)
       OR (request.status='REJECTED' AND (
              request.reviewed_by IS NULL
              OR NULLIF(btrim(request.rejection_reason),'') IS NULL))

    UNION ALL
    SELECT 'approved_settlement_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_settlements settlement
    LEFT JOIN public.financial_events event
      ON event.company_id=settlement.company_id
     AND event.id=settlement.financial_event_id
    WHERE event.id IS NULL OR event.source_table<>'expense_settlements'
       OR event.source_id<>settlement.id
       OR event.event_type<>'EXPENSE_SETTLEMENT'::public.event_type

    UNION ALL
    SELECT 'expense_return_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_returns returned
    LEFT JOIN public.financial_events event
      ON event.company_id=returned.company_id
     AND event.id=returned.financial_event_id
    WHERE event.id IS NULL OR event.source_table<>'expense_returns'
       OR event.source_id<>returned.id
       OR event.event_type<>'EXPENSE_RETURN'::public.event_type

    UNION ALL
    SELECT 'cash_return_drawer_and_cash_in_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_returns returned
    LEFT JOIN public.cash_drawer_movements movement
      ON movement.company_id=returned.company_id
     AND movement.source_table='expense_returns'
     AND movement.source_id=returned.id
    LEFT JOIN public.cash_in_documents cash_in
      ON cash_in.company_id=returned.company_id
     AND cash_in.source_type='EXPENSE_RETURN'
     AND cash_in.source_document_id=returned.document_id
     AND cash_in.amount=returned.amount
    WHERE returned.payment_method_type_snapshot='CASH'
      AND (movement.id IS NULL OR cash_in.id IS NULL
           OR movement.direction<>'IN'
           OR movement.amount<>returned.amount)

    UNION ALL
    SELECT 'noncash_return_drawer_isolation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_returns returned
    JOIN public.cash_drawer_movements movement
      ON movement.company_id=returned.company_id
     AND movement.source_table='expense_returns'
     AND movement.source_id=returned.id
    WHERE returned.payment_method_type_snapshot<>'CASH'

    UNION ALL
    SELECT 'additional_request_zero_cash_effect',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_additional_disbursement_requests request
    WHERE EXISTS (
        SELECT 1 FROM public.expense_disbursements disbursement
        WHERE disbursement.company_id=request.company_id
          AND disbursement.id=request.id
    ) OR EXISTS (
        SELECT 1 FROM public.cash_drawer_movements movement
        WHERE movement.company_id=request.company_id
          AND movement.source_id=request.id
    )

    UNION ALL
    SELECT 'browser_settlement_write_boundary',
        CASE WHEN has_table_privilege(
                'authenticated','public.expense_settlement_requests','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.expense_settlements','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.expense_returns','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.cash_in_documents','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.cash_drawer_movements','INSERT'
             ) THEN 'FAIL' ELSE 'PASS' END,
        CASE WHEN has_table_privilege(
                'authenticated','public.expense_settlement_requests','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.expense_settlements','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.expense_returns','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.cash_in_documents','INSERT'
             ) OR has_table_privilege(
                'authenticated','public.cash_drawer_movements','INSERT'
             ) THEN 1 ELSE 0 END::BIGINT,
        jsonb_build_object(
            'request_insert',has_table_privilege(
                'authenticated','public.expense_settlement_requests','INSERT'),
            'settlement_insert',has_table_privilege(
                'authenticated','public.expense_settlements','INSERT'),
            'return_insert',has_table_privilege(
                'authenticated','public.expense_returns','INSERT'),
            'cash_in_insert',has_table_privilege(
                'authenticated','public.cash_in_documents','INSERT'),
            'drawer_insert',has_table_privilege(
                'authenticated','public.cash_drawer_movements','INSERT')
        )

    UNION ALL
    SELECT 'expense_settlement_runtime_inventory','INFO',0,
        jsonb_build_object(
            'settlement_requests',(
                SELECT count(*) FROM public.expense_settlement_requests),
            'approved_settlements',(
                SELECT count(*) FROM public.expense_settlements),
            'returns',(SELECT count(*) FROM public.expense_returns),
            'additional_requests',(
                SELECT count(*)
                FROM public.expense_additional_disbursement_requests),
            'open_outstanding_documents',(
                SELECT count(*) FROM public.expense_documents
                WHERE outstanding_amount>0)
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
