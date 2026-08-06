-- G4 phase 43 postflight: canonical multi-Session Cash Deposit foundation.
-- SAFETY: SELECT-only aggregate verification.

WITH expected_tables(table_name) AS (
    VALUES
        ('cash_deposit_policies'),('cash_deposit_documents'),
        ('cash_deposit_session_lines'),('cash_deposit_audit'),
        ('deposit_variance_exceptions'),('deposit_variance_allocations')
), expected_routines(routine_name) AS (
    VALUES
        ('list_cash_deposit_eligible_sessions'),('save_cash_deposit_draft'),
        ('submit_cash_deposit'),('review_cash_deposit'),
        ('cancel_cash_deposit')
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        count(*) FILTER(WHERE FALSE)::BIGINT violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations WHERE version='20260804130000'

    UNION ALL
    SELECT 'required_cash_deposit_tables',
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
    SELECT 'required_cash_deposit_routines',
        CASE WHEN count(*) FILTER(WHERE routine.oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE routine.oid IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                FILTER(WHERE routine.oid IS NULL),'[]'::JSONB))
    FROM expected_routines expected
    LEFT JOIN pg_proc routine ON routine.proname=expected.routine_name
     AND routine.pronamespace='public'::regnamespace

    UNION ALL
    SELECT 'active_company_policy_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    WHERE company.status='ACTIVE' AND NOT EXISTS(
        SELECT 1 FROM public.cash_deposit_policies policy
        WHERE policy.company_id=company.id AND policy.store_id IS NULL
          AND policy.is_active)

    UNION ALL
    SELECT 'invalid_cash_deposit_document_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.cash_deposit_documents document
    WHERE document.actual_deposit_amount<=0
       OR document.total_expected_deposit<0
       OR document.deposit_variance<>
            document.actual_deposit_amount-document.total_expected_deposit
       OR document.variance_type<>CASE
            WHEN document.deposit_variance<0 THEN 'UNDER_DEPOSIT'
            WHEN document.deposit_variance>0 THEN 'OVER_DEPOSIT'
            ELSE 'MATCHED' END

    UNION ALL
    SELECT 'submitted_or_approved_without_locked_session',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.cash_deposit_documents document
    WHERE document.status IN ('SUBMITTED','APPROVED')
      AND NOT EXISTS(
          SELECT 1 FROM public.cash_deposit_session_lines line
          WHERE line.company_id=document.company_id
            AND line.deposit_document_id=document.id
            AND line.allocation_status=CASE
                WHEN document.status='APPROVED' THEN 'POSTED' ELSE 'LOCKED' END)

    UNION ALL
    SELECT 'multiple_active_deposits_per_session',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (SELECT company_id,cashier_session_id
          FROM public.cash_deposit_session_lines
          WHERE allocation_status IN ('LOCKED','POSTED')
          GROUP BY company_id,cashier_session_id HAVING count(*)>1) duplicate

    UNION ALL
    SELECT 'approved_deposit_final_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.cash_deposit_documents document
    WHERE document.status='APPROVED' AND (
        document.financial_event_id IS NULL
        OR document.transaction_category_id IS NULL
        OR document.cash_drawer_account_id IS NULL
        OR document.destination_account_id IS NULL
        OR EXISTS(SELECT 1 FROM public.cash_deposit_session_lines line
                  WHERE line.deposit_document_id=document.id
                    AND line.allocation_status<>'POSTED'))

    UNION ALL
    SELECT 'approved_variance_exception_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.cash_deposit_documents document
    WHERE document.status='APPROVED' AND document.deposit_variance<>0
      AND NOT EXISTS(SELECT 1 FROM public.deposit_variance_exceptions exception
                     WHERE exception.company_id=document.company_id
                       AND exception.cash_deposit_document_id=document.id)

    UNION ALL
    SELECT 'matched_deposit_without_variance_exception',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.cash_deposit_documents document
    JOIN public.deposit_variance_exceptions exception
      ON exception.company_id=document.company_id
     AND exception.cash_deposit_document_id=document.id
    WHERE document.deposit_variance=0

    UNION ALL
    SELECT 'cash_deposit_financial_event_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('event_count',count(*))
    FROM public.cash_deposit_documents document
    JOIN public.financial_events event ON event.id=document.financial_event_id
    WHERE event.event_type IS DISTINCT FROM 'BANK_DEPOSIT'::public.event_type
       OR event.source_table<>'cash_deposit_documents'
       OR event.source_id<>document.id OR event.status<>'HOLD'::public.event_status
       OR event.system_event_key<>'CASH_DEPOSIT'

    UNION ALL
    SELECT 'history_immutable_triggers',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=2 THEN 0 ELSE 2-count(*) END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger
    JOIN pg_class relation ON relation.oid=trigger.tgrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname IN ('cash_deposit_audit','deposit_variance_allocations')
      AND trigger.tgname IN ('g4_cash_deposit_audit_immutable','g4_deposit_variance_allocation_immutable')
      AND NOT trigger.tgisinternal AND trigger.tgenabled<>'D'

    UNION ALL
    SELECT 'browser_cash_deposit_rpc_boundary',
        CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=5 THEN 0 ELSE 5-count(*) END,
        jsonb_build_object('authenticated_rpc_rows',count(*))
    FROM expected_routines expected
    JOIN pg_proc routine ON routine.proname=expected.routine_name
     AND routine.pronamespace='public'::regnamespace
    WHERE has_function_privilege('authenticated',routine.oid,'EXECUTE')
      AND NOT has_function_privilege('anon',routine.oid,'EXECUTE')

    UNION ALL
    SELECT 'browser_direct_cash_deposit_write_boundary',
        CASE WHEN has_table_privilege('authenticated','public.cash_deposit_documents','INSERT,UPDATE,DELETE')
               OR has_table_privilege('authenticated','public.cash_deposit_session_lines','INSERT,UPDATE,DELETE')
               OR has_table_privilege('authenticated','public.financial_events','INSERT')
             THEN 'FAIL' ELSE 'PASS' END,
        CASE WHEN has_table_privilege('authenticated','public.cash_deposit_documents','INSERT,UPDATE,DELETE')
               OR has_table_privilege('authenticated','public.cash_deposit_session_lines','INSERT,UPDATE,DELETE')
               OR has_table_privilege('authenticated','public.financial_events','INSERT')
             THEN 1 ELSE 0 END,
        jsonb_build_object(
          'document_write',has_table_privilege('authenticated','public.cash_deposit_documents','INSERT,UPDATE,DELETE'),
          'line_write',has_table_privilege('authenticated','public.cash_deposit_session_lines','INSERT,UPDATE,DELETE'),
          'event_insert',has_table_privilege('authenticated','public.financial_events','INSERT'))

    UNION ALL
    SELECT 'cash_deposit_runtime_inventory','INFO',0,
        jsonb_build_object(
          'documents',count(*),'drafts',count(*) FILTER(WHERE status='DRAFT'),
          'submitted',count(*) FILTER(WHERE status='SUBMITTED'),
          'approved',count(*) FILTER(WHERE status='APPROVED'),
          'variance_documents',count(*) FILTER(WHERE deposit_variance<>0),
          'variance_exceptions',(SELECT count(*) FROM public.deposit_variance_exceptions))
    FROM public.cash_deposit_documents
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
