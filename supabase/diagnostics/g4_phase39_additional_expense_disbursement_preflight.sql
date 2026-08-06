-- G4 phase 39 preflight: additional Expense approval/disbursement readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Expense/person/business names.
-- - Does not approve, reject, disburse, or change a Cashier drawer.

WITH required_versions(version) AS (
    VALUES ('20260803100000')
), expected_request_columns(column_name) AS (
    VALUES
        ('rejected_by'),('rejected_at'),('rejection_reason'),
        ('disbursed_by'),('disbursed_at'),('expense_disbursement_id')
), expected_runtime_routines(routine_name) AS (
    VALUES
        ('review_additional_expense_disbursement'),
        ('disburse_additional_expense')
), request_inventory AS (
    SELECT request.*
    FROM public.expense_additional_disbursement_requests request
), checks AS (
    SELECT
        'g4_phase39_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'canonical_additional_request_schema_state',
        CASE WHEN count(*) FILTER (WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_columns',count(*),
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_request_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name=
        'expense_additional_disbursement_requests'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_additional_runtime_state',
        CASE WHEN count(*) FILTER (WHERE routine_state.routine_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_routines',count(*),
            'missing_routines',COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER (WHERE routine_state.routine_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_runtime_routines expected
    LEFT JOIN LATERAL (
        SELECT p.proname AS routine_name
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname=expected.routine_name
        LIMIT 1
    ) routine_state ON TRUE

    UNION ALL

    SELECT
        'additional_disbursement_event_state',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('event_rows',count(*))
    FROM pg_enum enum_value
    JOIN pg_type enum_type ON enum_type.oid=enum_value.enumtypid
    JOIN pg_namespace n ON n.oid=enum_type.typnamespace
    WHERE n.nspname='public' AND enum_type.typname='event_type'
      AND enum_value.enumlabel='EXPENSE_ADDITIONAL_DISBURSEMENT'

    UNION ALL

    SELECT
        'guarded_additional_request_rpc',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='request_additional_expense_disbursement'

    UNION ALL

    SELECT
        'invalid_additional_request_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM request_inventory request
    WHERE request.amount<=0
       OR request.master_version<=0
       OR request.document_master_version_snapshot<=0
       OR btrim(request.payment_method_name_snapshot)=''
       OR request.payment_method_type_snapshot NOT IN (
            'CASH','TRANSFER','QRIS','CARD','E_WALLET'
       )
       OR request.status NOT IN (
            'SUBMITTED','APPROVED','DISBURSED','REJECTED','CANCELED'
       )
       OR (request.status='SUBMITTED' AND (
            NOT request.approval_required_snapshot
            OR request.approved_by IS NOT NULL
            OR request.approved_at IS NOT NULL
       ))
       OR (request.status='APPROVED' AND (
            request.approved_by IS NULL OR request.approved_at IS NULL
       ))
       OR (request.evidence_url IS NOT NULL
           AND request.evidence_url!~*'^https://')

    UNION ALL

    SELECT
        'additional_request_tenant_reference_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
    FROM request_inventory request
    LEFT JOIN public.expense_documents document
      ON document.company_id=request.company_id
     AND document.id=request.document_id
    LEFT JOIN public.stores store
      ON store.company_id=request.company_id AND store.id=request.store_id
    LEFT JOIN public.payment_methods method
      ON method.company_id=request.company_id
     AND method.id=request.payment_method_id
    WHERE document.id IS NULL OR store.id IS NULL OR method.id IS NULL
       OR document.store_id IS DISTINCT FROM request.store_id

    UNION ALL

    SELECT
        'duplicate_open_additional_request',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,document_id
        FROM request_inventory
        WHERE status IN ('SUBMITTED','APPROVED')
        GROUP BY company_id,document_id
        HAVING count(*)>1
    ) duplicate_groups

    UNION ALL

    SELECT
        'open_request_invalid_document_state',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM request_inventory request
    JOIN public.expense_documents document
      ON document.company_id=request.company_id
     AND document.id=request.document_id
    WHERE request.status IN ('SUBMITTED','APPROVED')
      AND (
          document.status NOT IN ('DISBURSED','PARTIALLY_SETTLED')
          OR document.outstanding_amount<0
          OR request.document_master_version_snapshot>
             document.master_version
      )

    UNION ALL

    SELECT
        'open_request_invalid_payment_method',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM request_inventory request
    JOIN public.payment_methods method
      ON method.company_id=request.company_id
     AND method.id=request.payment_method_id
    WHERE request.status IN ('SUBMITTED','APPROVED')
      AND (
          NOT method.is_active
          OR method.method_type IS DISTINCT FROM
             request.payment_method_type_snapshot
      )

    UNION ALL

    SELECT
        'request_only_zero_disbursement_effect',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM request_inventory request
    JOIN public.expense_disbursements disbursement
      ON disbursement.company_id=request.company_id
     AND disbursement.idempotency_key=request.idempotency_key
    WHERE request.status IN ('SUBMITTED','APPROVED')

    UNION ALL

    SELECT
        'approved_cash_request_session_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('request_count',count(*))
    FROM request_inventory request
    WHERE request.status='APPROVED'
      AND request.payment_method_type_snapshot='CASH'
      AND NOT EXISTS (
          SELECT 1 FROM public.cashier_sessions session
          WHERE session.company_id=request.company_id
            AND session.store_id=request.store_id
            AND session.status='OPEN'
      )

    UNION ALL

    SELECT
        'direct_additional_request_write_privilege',
        'INFO',
        jsonb_build_object(
            'authenticated_insert',has_table_privilege(
                'authenticated',
                'public.expense_additional_disbursement_requests','INSERT'
            ),
            'authenticated_update',has_table_privilege(
                'authenticated',
                'public.expense_additional_disbursement_requests','UPDATE'
            ),
            'expense_disbursement_insert',has_table_privilege(
                'authenticated','public.expense_disbursements','INSERT'
            ),
            'cash_drawer_insert',has_table_privilege(
                'authenticated','public.cash_drawer_movements','INSERT'
            )
        )

    UNION ALL

    SELECT
        'additional_request_inventory',
        'INFO',
        jsonb_build_object(
            'requests',count(*),
            'companies',count(DISTINCT company_id),
            'documents',count(DISTINCT document_id),
            'submitted',count(*) FILTER (WHERE status='SUBMITTED'),
            'approved',count(*) FILTER (WHERE status='APPROVED'),
            'disbursed',count(*) FILTER (WHERE status='DISBURSED'),
            'rejected',count(*) FILTER (WHERE status='REJECTED'),
            'cash_requests',count(*) FILTER (
                WHERE payment_method_type_snapshot='CASH'
            ),
            'noncash_requests',count(*) FILTER (
                WHERE payment_method_type_snapshot<>'CASH'
            )
        )
    FROM request_inventory

    UNION ALL

    SELECT
        'expense_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'disbursed_documents',count(*) FILTER (
                WHERE status='DISBURSED'
            ),
            'partially_settled_documents',count(*) FILTER (
                WHERE status='PARTIALLY_SETTLED'
            ),
            'open_expense_documents',count(*) FILTER (
                WHERE status IN ('DISBURSED','PARTIALLY_SETTLED')
                  AND outstanding_amount>0
            ),
            'expense_disbursement_rows',(
                SELECT count(*) FROM public.expense_disbursements
            )
        )
    FROM public.expense_documents
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
