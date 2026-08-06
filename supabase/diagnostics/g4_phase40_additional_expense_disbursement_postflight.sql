-- G4 phase 40 postflight: additional Expense review/disbursement foundation.
-- SELECT-only and aggregate-only.

WITH expected_columns(column_name) AS (
    VALUES
        ('rejected_by'),('rejected_at'),('rejection_reason'),
        ('disbursed_by'),('disbursed_at'),('expense_disbursement_id')
), expected_routines(signature) AS (
    VALUES
        ('public.review_additional_expense_disbursement(uuid,bigint,text,text)'),
        ('public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)')
), checks AS (
    SELECT 'migration_ledger'::text AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*)-1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260804100000'

    UNION ALL
    SELECT 'required_additional_columns',
        CASE WHEN count(*) FILTER (WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE column_state.column_name IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name=
        'expense_additional_disbursement_requests'
     AND column_state.column_name=expected.column_name

    UNION ALL
    SELECT 'required_additional_routines',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(expected.signature) IS NULL
        )=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE to_regprocedure(expected.signature) IS NULL
        ),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.signature ORDER BY expected.signature)
                    FILTER (
                        WHERE to_regprocedure(expected.signature) IS NULL
                    ),
                '[]'::jsonb
            )
        )
    FROM expected_routines expected

    UNION ALL
    SELECT 'additional_disbursement_event_enum',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1)::BIGINT,
        jsonb_build_object('event_rows',count(*))
    FROM pg_enum enum_value
    JOIN pg_type enum_type ON enum_type.oid=enum_value.enumtypid
    JOIN pg_namespace n ON n.oid=enum_type.typnamespace
    WHERE n.nspname='public' AND enum_type.typname='event_type'
      AND enum_value.enumlabel='EXPENSE_ADDITIONAL_DISBURSEMENT'

    UNION ALL
    SELECT 'additional_request_disbursement_unique_index',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1)::BIGINT,
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes
    WHERE schemaname='public'
      AND tablename='expense_additional_disbursement_requests'
      AND indexname='uq_expense_additional_request_disbursement'

    UNION ALL
    SELECT 'browser_additional_rpc_boundary',
        CASE WHEN has_function_privilege(
            'anon',
            'public.review_additional_expense_disbursement(uuid,bigint,text,text)',
            'EXECUTE'
        ) OR has_function_privilege(
            'anon',
            'public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)',
            'EXECUTE'
        ) OR NOT has_function_privilege(
            'authenticated',
            'public.review_additional_expense_disbursement(uuid,bigint,text,text)',
            'EXECUTE'
        ) OR NOT has_function_privilege(
            'authenticated',
            'public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)',
            'EXECUTE'
        ) THEN 'FAIL' ELSE 'PASS' END,
        CASE WHEN has_function_privilege(
            'anon',
            'public.review_additional_expense_disbursement(uuid,bigint,text,text)',
            'EXECUTE'
        ) OR has_function_privilege(
            'anon',
            'public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)',
            'EXECUTE'
        ) OR NOT has_function_privilege(
            'authenticated',
            'public.review_additional_expense_disbursement(uuid,bigint,text,text)',
            'EXECUTE'
        ) OR NOT has_function_privilege(
            'authenticated',
            'public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)',
            'EXECUTE'
        ) THEN 1 ELSE 0 END::BIGINT,
        jsonb_build_object(
            'anon_review',has_function_privilege(
                'anon',
                'public.review_additional_expense_disbursement(uuid,bigint,text,text)',
                'EXECUTE'),
            'anon_disburse',has_function_privilege(
                'anon',
                'public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)',
                'EXECUTE'),
            'authenticated_review',has_function_privilege(
                'authenticated',
                'public.review_additional_expense_disbursement(uuid,bigint,text,text)',
                'EXECUTE'),
            'authenticated_disburse',has_function_privilege(
                'authenticated',
                'public.disburse_additional_expense(uuid,bigint,bigint,uuid,text,uuid)',
                'EXECUTE')
        )

    UNION ALL
    SELECT 'additional_request_lifecycle_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_additional_disbursement_requests request
    WHERE (request.status='SUBMITTED' AND (
              request.approved_by IS NOT NULL OR request.approved_at IS NOT NULL
              OR request.rejected_by IS NOT NULL
              OR request.disbursed_by IS NOT NULL
              OR request.expense_disbursement_id IS NOT NULL))
       OR (request.status='APPROVED' AND (
              request.approved_by IS NULL OR request.approved_at IS NULL
              OR request.rejected_by IS NOT NULL
              OR request.disbursed_by IS NOT NULL
              OR request.expense_disbursement_id IS NOT NULL))
       OR (request.status='REJECTED' AND (
              request.rejected_by IS NULL OR request.rejected_at IS NULL
              OR NULLIF(btrim(request.rejection_reason),'') IS NULL
              OR request.disbursed_by IS NOT NULL
              OR request.expense_disbursement_id IS NOT NULL))
       OR (request.status='DISBURSED' AND (
              request.approved_by IS NULL OR request.approved_at IS NULL
              OR request.disbursed_by IS NULL OR request.disbursed_at IS NULL
              OR request.expense_disbursement_id IS NULL))

    UNION ALL
    SELECT 'disbursed_request_final_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_additional_disbursement_requests request
    LEFT JOIN public.expense_disbursements disbursement
      ON disbursement.company_id=request.company_id
     AND disbursement.id=request.expense_disbursement_id
    LEFT JOIN public.financial_events event
      ON event.company_id=disbursement.company_id
     AND event.id=disbursement.financial_event_id
    WHERE request.status='DISBURSED'
      AND (
          disbursement.id IS NULL OR disbursement.document_id<>request.document_id
          OR disbursement.amount<>request.amount
          OR disbursement.payment_method_id<>request.payment_method_id
          OR event.id IS NULL
          OR event.event_type<>'EXPENSE_ADDITIONAL_DISBURSEMENT'::public.event_type
          OR event.source_table<>'expense_disbursements'
          OR event.source_id<>disbursement.id
      )

    UNION ALL
    SELECT 'cash_additional_drawer_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_additional_disbursement_requests request
    JOIN public.expense_disbursements disbursement
      ON disbursement.company_id=request.company_id
     AND disbursement.id=request.expense_disbursement_id
    LEFT JOIN public.cash_drawer_movements movement
      ON movement.company_id=disbursement.company_id
     AND movement.source_table='expense_disbursements'
     AND movement.source_id=disbursement.id
    WHERE request.status='DISBURSED'
      AND request.payment_method_type_snapshot='CASH'
      AND (
          movement.id IS NULL OR movement.direction<>'OUT'
          OR movement.amount<>request.amount
          OR movement.cashier_session_id<>disbursement.cashier_session_id
      )

    UNION ALL
    SELECT 'noncash_additional_drawer_isolation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.expense_additional_disbursement_requests request
    JOIN public.expense_disbursements disbursement
      ON disbursement.company_id=request.company_id
     AND disbursement.id=request.expense_disbursement_id
    JOIN public.cash_drawer_movements movement
      ON movement.company_id=disbursement.company_id
     AND movement.source_table='expense_disbursements'
     AND movement.source_id=disbursement.id
    WHERE request.status='DISBURSED'
      AND request.payment_method_type_snapshot<>'CASH'

    UNION ALL
    SELECT 'expense_document_disbursement_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('document_count',count(*))
    FROM public.expense_documents document
    LEFT JOIN LATERAL (
        SELECT COALESCE(sum(disbursement.amount),0) AS total
        FROM public.expense_disbursements disbursement
        WHERE disbursement.company_id=document.company_id
          AND disbursement.document_id=document.id
    ) total ON TRUE
    WHERE document.disbursed_amount<>total.total
       OR document.outstanding_amount<0
       OR document.outstanding_amount<>
          document.disbursed_amount-document.actual_expense_amount-
          document.returned_amount

    UNION ALL
    SELECT 'browser_direct_additional_write_boundary',
        CASE WHEN has_table_privilege(
            'authenticated',
            'public.expense_additional_disbursement_requests',
            'INSERT,UPDATE,DELETE'
        ) OR has_table_privilege(
            'authenticated','public.expense_disbursements',
            'INSERT,UPDATE,DELETE'
        ) OR has_table_privilege(
            'authenticated','public.cash_drawer_movements',
            'INSERT,UPDATE,DELETE'
        ) THEN 'FAIL' ELSE 'PASS' END,
        CASE WHEN has_table_privilege(
            'authenticated',
            'public.expense_additional_disbursement_requests',
            'INSERT,UPDATE,DELETE'
        ) OR has_table_privilege(
            'authenticated','public.expense_disbursements',
            'INSERT,UPDATE,DELETE'
        ) OR has_table_privilege(
            'authenticated','public.cash_drawer_movements',
            'INSERT,UPDATE,DELETE'
        ) THEN 1 ELSE 0 END::BIGINT,
        jsonb_build_object(
            'request_write',has_table_privilege(
                'authenticated',
                'public.expense_additional_disbursement_requests',
                'INSERT,UPDATE,DELETE'),
            'disbursement_write',has_table_privilege(
                'authenticated','public.expense_disbursements',
                'INSERT,UPDATE,DELETE'),
            'drawer_write',has_table_privilege(
                'authenticated','public.cash_drawer_movements',
                'INSERT,UPDATE,DELETE')
        )

    UNION ALL
    SELECT 'additional_disbursement_runtime_inventory','INFO',0,
        jsonb_build_object(
            'requests',count(*),
            'submitted',count(*) FILTER (WHERE status='SUBMITTED'),
            'approved',count(*) FILTER (WHERE status='APPROVED'),
            'rejected',count(*) FILTER (WHERE status='REJECTED'),
            'disbursed',count(*) FILTER (WHERE status='DISBURSED'),
            'disbursed_amount',COALESCE(sum(amount) FILTER (
                WHERE status='DISBURSED'
            ),0)
        )
    FROM public.expense_additional_disbursement_requests
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
