-- G4 phase 46 postflight: Deposit variance resolution foundation.
-- SAFETY: SELECT-only aggregate verification.

WITH expected_tables(table_name) AS (
    VALUES
        ('deposit_variance_resolution_requests'),
        ('deposit_variance_resolution_audit')
), expected_routines(routine_name) AS (
    VALUES
        ('assign_deposit_variance_responsible_party'),
        ('resolve_deposit_variance'),
        ('review_deposit_variance_resolution')
), expected_allocation_columns(column_name) AS (
    VALUES
        ('status'),('submitted_by'),('submitted_at'),('reviewed_by'),
        ('reviewed_at'),('rejection_reason'),('resolution_reference')
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        count(*) FILTER(WHERE FALSE)::BIGINT violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations
    WHERE version='20260804160000'

    UNION ALL
    SELECT 'required_variance_resolution_tables',
        CASE WHEN count(*) FILTER(WHERE existing.table_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE existing.table_name IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(expected.table_name ORDER BY expected.table_name)
                FILTER(WHERE existing.table_name IS NULL),'[]'::JSONB))
    FROM expected_tables expected
    LEFT JOIN information_schema.tables existing
      ON existing.table_schema='public'
     AND existing.table_name=expected.table_name

    UNION ALL
    SELECT 'required_variance_resolution_routines',
        CASE WHEN count(*) FILTER(WHERE routine.oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE routine.oid IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                FILTER(WHERE routine.oid IS NULL),'[]'::JSONB))
    FROM expected_routines expected
    LEFT JOIN pg_proc routine
      ON routine.proname=expected.routine_name
     AND routine.pronamespace='public'::regnamespace

    UNION ALL
    SELECT 'required_variance_allocation_columns',
        CASE WHEN count(*) FILTER(WHERE existing.column_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE existing.column_name IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(expected.column_name ORDER BY expected.column_name)
                FILTER(WHERE existing.column_name IS NULL),'[]'::JSONB))
    FROM expected_allocation_columns expected
    LEFT JOIN information_schema.columns existing
      ON existing.table_schema='public'
     AND existing.table_name='deposit_variance_allocations'
     AND existing.column_name=expected.column_name

    UNION ALL
    SELECT 'deposit_variance_resolution_event',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),jsonb_build_object('event_rows',count(*))
    FROM pg_enum enum_value
    JOIN pg_type enum_type ON enum_type.oid=enum_value.enumtypid
    WHERE enum_type.typname='event_type'
      AND enum_value.enumlabel='DEPOSIT_VARIANCE_RESOLUTION'

    UNION ALL
    SELECT 'invalid_variance_exception_runtime_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.deposit_variance_exceptions exception
    WHERE exception.master_version<=0
       OR exception.remaining_amount<0
       OR exception.resolved_amount<0
       OR exception.remaining_amount<>
            exception.original_amount-exception.resolved_amount
       OR (exception.status IN ('RESOLVED','WRITTEN_OFF')
           AND exception.remaining_amount<>0)

    UNION ALL
    SELECT 'approved_variance_request_final_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('request_count',count(*))
    FROM public.deposit_variance_resolution_requests request
    WHERE request.status='APPROVED' AND (
        request.allocation_id IS NULL OR request.financial_event_id IS NULL
        OR request.reviewed_by IS NULL OR request.reviewed_at IS NULL
    )

    UNION ALL
    SELECT 'nonapproved_variance_request_zero_effect',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('request_count',count(*))
    FROM public.deposit_variance_resolution_requests request
    WHERE request.status<>'APPROVED' AND (
        request.allocation_id IS NOT NULL OR request.financial_event_id IS NOT NULL
        OR EXISTS(
            SELECT 1 FROM public.deposit_variance_allocations allocation
            WHERE allocation.company_id=request.company_id
              AND allocation.resolution_request_id=request.id
        )
    )

    UNION ALL
    SELECT 'variance_allocation_request_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('allocation_count',count(*))
    FROM public.deposit_variance_allocations allocation
    LEFT JOIN public.deposit_variance_resolution_requests request
      ON request.company_id=allocation.company_id
     AND request.id=allocation.resolution_request_id
    WHERE request.id IS NULL OR request.status<>'APPROVED'
       OR request.allocation_id<>allocation.id
       OR request.financial_event_id<>allocation.financial_event_id

    UNION ALL
    SELECT 'variance_exception_allocation_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('exception_count',count(*))
    FROM public.deposit_variance_exceptions exception
    WHERE exception.resolved_amount<>(
        SELECT COALESCE(sum(allocation.allocation_amount),0)
        FROM public.deposit_variance_allocations allocation
        WHERE allocation.company_id=exception.company_id
          AND allocation.variance_exception_id=exception.id
    )

    UNION ALL
    SELECT 'approved_variance_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('request_count',count(*))
    FROM public.deposit_variance_resolution_requests request
    LEFT JOIN public.financial_events event
      ON event.company_id=request.company_id
     AND event.id=request.financial_event_id
    WHERE request.status='APPROVED' AND (
        event.id IS NULL OR event.source_table<>
            'deposit_variance_resolution_requests'
        OR event.source_id<>request.id
        OR event.status<>'HOLD'::public.event_status
    )

    UNION ALL
    SELECT 'maker_checker_resolution_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('request_count',count(*))
    FROM public.deposit_variance_resolution_requests request
    WHERE request.resolution_type IN (
        'COMPANY_EXPENSE','WRITE_OFF','CASH_OVERAGE_INCOME','SOURCE_CORRECTION'
    ) AND (
        NOT request.requires_review
        OR (request.status='APPROVED' AND request.created_by=request.reviewed_by)
    )

    UNION ALL
    SELECT 'variance_resolution_history_immutable',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-2),jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_state
    WHERE NOT trigger_state.tgisinternal
      AND trigger_state.tgname IN (
        'g4_deposit_variance_allocation_immutable',
        'g4_deposit_variance_resolution_audit_immutable'
      )

    UNION ALL
    SELECT 'browser_variance_resolution_rpc_boundary',
        CASE WHEN count(*)=3
              AND count(*) FILTER(WHERE anon_exec)=0
              AND count(*) FILTER(WHERE authenticated_exec)=3
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=3
              AND count(*) FILTER(WHERE anon_exec)=0
              AND count(*) FILTER(WHERE authenticated_exec)=3
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'routine_rows',count(*),
            'anon_executable_rows',count(*) FILTER(WHERE anon_exec),
            'authenticated_executable_rows',count(*) FILTER(
                WHERE authenticated_exec
            )
        )
    FROM (
        SELECT procedure.oid,
            has_function_privilege('anon',procedure.oid,'EXECUTE') anon_exec,
            has_function_privilege(
                'authenticated',procedure.oid,'EXECUTE'
            ) authenticated_exec
        FROM pg_proc procedure
        JOIN pg_namespace namespace
          ON namespace.oid=procedure.pronamespace
        WHERE namespace.nspname='public'
          AND procedure.proname IN (
            'assign_deposit_variance_responsible_party',
            'resolve_deposit_variance',
            'review_deposit_variance_resolution'
          )
    ) routine

    UNION ALL
    SELECT 'browser_variance_resolution_write_boundary',
        CASE WHEN NOT request_write AND NOT audit_write
             AND NOT allocation_write AND NOT exception_write
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT request_write AND NOT audit_write
             AND NOT allocation_write AND NOT exception_write
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'request_write',request_write,'audit_write',audit_write,
            'allocation_write',allocation_write,
            'exception_write',exception_write
        )
    FROM (
        SELECT
          has_table_privilege('authenticated',
            'public.deposit_variance_resolution_requests',
            'INSERT,UPDATE,DELETE') request_write,
          has_table_privilege('authenticated',
            'public.deposit_variance_resolution_audit',
            'INSERT,UPDATE,DELETE') audit_write,
          has_table_privilege('authenticated',
            'public.deposit_variance_allocations',
            'INSERT,UPDATE,DELETE') allocation_write,
          has_table_privilege('authenticated',
            'public.deposit_variance_exceptions',
            'INSERT,UPDATE,DELETE') exception_write
    ) privilege

    UNION ALL
    SELECT 'variance_resolution_runtime_inventory','INFO',0,
        jsonb_build_object(
            'exceptions',(
                SELECT count(*) FROM public.deposit_variance_exceptions
            ),
            'requests',(
                SELECT count(*)
                FROM public.deposit_variance_resolution_requests
            ),
            'allocations',(
                SELECT count(*) FROM public.deposit_variance_allocations
            ),
            'resolution_events',(
                SELECT count(*) FROM public.financial_events event
                WHERE event.event_type=
                    'DEPOSIT_VARIANCE_RESOLUTION'::public.event_type
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
