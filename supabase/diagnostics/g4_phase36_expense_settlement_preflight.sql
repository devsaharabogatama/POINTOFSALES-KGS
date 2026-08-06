-- G4 phase 36 preflight: Expense actual/return/outstanding readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Expense/person/business names.
-- - Does not settle Expense, return funds, create Cash In, or alter a drawer.

WITH required_versions(version) AS (
    VALUES ('20260803070000')
), enabled_companies AS (
    SELECT company.id AS company_id
    FROM public.companies company
    JOIN public.company_features feature
      ON feature.company_id=company.id
     AND feature.feature_code='expense_enabled'
     AND feature.is_enabled
    WHERE company.status='ACTIVE'
), disbursed_documents AS (
    SELECT document.*
    FROM public.expense_documents document
    WHERE document.status IN (
        'DISBURSED','PARTIALLY_SETTLED','SETTLED','SETTLED_NO_EXPENSE'
    )
), document_event_totals AS (
    SELECT
        document.company_id,
        document.id AS document_id,
        document.disbursed_amount,
        document.actual_expense_amount,
        document.returned_amount,
        document.outstanding_amount,
        COALESCE(disbursement.total,0) AS disbursement_total,
        COALESCE(settlement.total,0) AS settlement_total,
        COALESCE(returned.total,0) AS return_total
    FROM public.expense_documents document
    LEFT JOIN LATERAL (
        SELECT sum(row.amount) AS total
        FROM public.expense_disbursements row
        WHERE row.company_id=document.company_id
          AND row.document_id=document.id
    ) disbursement ON TRUE
    LEFT JOIN LATERAL (
        SELECT sum(row.actual_expense_amount) AS total
        FROM public.expense_settlements row
        WHERE row.company_id=document.company_id
          AND row.document_id=document.id
    ) settlement ON TRUE
    LEFT JOIN LATERAL (
        SELECT sum(row.amount) AS total
        FROM public.expense_returns row
        WHERE row.company_id=document.company_id
          AND row.document_id=document.id
    ) returned ON TRUE
), expected_document_columns(column_name) AS (
    VALUES
        ('disbursed_by'),('disbursed_at'),('settled_by'),('settled_at')
), expected_settlement_columns(column_name) AS (
    VALUES
        ('store_id'),('status'),('submitted_by'),('submitted_at'),
        ('reviewed_by'),('reviewed_at'),('transaction_category_id'),
        ('outstanding_account_id_snapshot'),
        ('document_master_version_snapshot')
), expected_return_columns(column_name) AS (
    VALUES
        ('store_id'),('pos_terminal_id'),
        ('payment_settlement_route_snapshot'),
        ('payment_account_function_snapshot'),('transaction_category_id'),
        ('outstanding_account_id_snapshot'),('payment_account_id_snapshot'),
        ('document_master_version_snapshot')
), required_runtime_routines(routine_name) AS (
    VALUES
        ('save_expense_settlement'),('review_expense_settlement'),
        ('return_expense_funds'),('request_additional_expense_disbursement')
), required_event_types(event_name) AS (
    VALUES
        ('EXPENSE_SETTLEMENT'),('EXPENSE_RETURN'),
        ('EXPENSE_ADDITIONAL_DISBURSEMENT')
), open_store_sessions AS (
    SELECT DISTINCT session.company_id,session.store_id
    FROM public.cashier_sessions session
    JOIN enabled_companies company ON company.company_id=session.company_id
    WHERE session.status='OPEN'
), checks AS (
    SELECT
        'g4_phase36_dependencies'::text AS check_name,
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
        'canonical_expense_settlement_routine_state',
        CASE WHEN count(*) FILTER (WHERE routine_state.oid IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_routines',count(*),
            'missing',COALESCE(
                jsonb_agg(required.routine_name ORDER BY required.routine_name)
                    FILTER (WHERE routine_state.oid IS NULL),
                '[]'::jsonb
            )
        )
    FROM required_runtime_routines required
    LEFT JOIN LATERAL (
        SELECT p.oid
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='public' AND p.proname=required.routine_name
        LIMIT 1
    ) routine_state ON TRUE

    UNION ALL

    SELECT
        'canonical_expense_document_settlement_schema',
        CASE WHEN count(*) FILTER (WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_document_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='expense_documents'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_expense_settlement_schema',
        CASE WHEN count(*) FILTER (WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'table_exists',to_regclass('public.expense_settlements') IS NOT NULL,
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_settlement_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='expense_settlements'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_expense_return_schema',
        CASE WHEN count(*) FILTER (WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'table_exists',to_regclass('public.expense_returns') IS NOT NULL,
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER (WHERE column_state.column_name IS NULL),
                '[]'::jsonb
            )
        )
    FROM expected_return_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='expense_returns'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'expense_settlement_event_enum_state',
        CASE WHEN count(*) FILTER (WHERE enum_state.enumlabel IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(required.event_name ORDER BY required.event_name)
                    FILTER (WHERE enum_state.enumlabel IS NULL),
                '[]'::jsonb
            )
        )
    FROM required_event_types required
    LEFT JOIN LATERAL (
        SELECT enum.enumlabel
        FROM pg_type type
        JOIN pg_namespace namespace ON namespace.oid=type.typnamespace
        JOIN pg_enum enum ON enum.enumtypid=type.oid
        WHERE namespace.nspname='public'
          AND type.typname='event_type'
          AND enum.enumlabel=required.event_name
        LIMIT 1
    ) enum_state ON TRUE

    UNION ALL

    SELECT
        'disbursed_expense_event_total_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('document_count',count(*))
    FROM document_event_totals total
    WHERE total.disbursed_amount<>total.disbursement_total
       OR total.actual_expense_amount<>total.settlement_total
       OR total.returned_amount<>total.return_total
       OR total.outstanding_amount<>
          total.disbursement_total-total.settlement_total-total.return_total

    UNION ALL

    SELECT
        'invalid_disbursed_expense_lifecycle_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM disbursed_documents document
    WHERE document.disbursed_amount<=0
       OR document.actual_expense_amount<0
       OR document.returned_amount<0
       OR document.outstanding_amount<0
       OR document.actual_expense_amount+document.returned_amount>
          document.disbursed_amount
       OR (document.status='DISBURSED'
           AND (document.actual_expense_amount<>0
                OR document.returned_amount<>0))
       OR (document.status='SETTLED'
           AND (document.actual_expense_amount<=0
                OR document.outstanding_amount<>0))
       OR (document.status='SETTLED_NO_EXPENSE'
           AND (document.actual_expense_amount<>0
                OR document.outstanding_amount<>0))

    UNION ALL

    SELECT
        'settlement_or_return_without_disbursement',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_documents document
    WHERE EXISTS (
        SELECT 1 FROM public.expense_settlements settlement
        WHERE settlement.company_id=document.company_id
          AND settlement.document_id=document.id
        UNION ALL
        SELECT 1 FROM public.expense_returns returned
        WHERE returned.company_id=document.company_id
          AND returned.document_id=document.id
    )
      AND NOT EXISTS (
          SELECT 1 FROM public.expense_disbursements disbursement
          WHERE disbursement.company_id=document.company_id
            AND disbursement.document_id=document.id
      )

    UNION ALL

    SELECT
        'existing_settlement_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_settlements settlement
    LEFT JOIN public.financial_events event
      ON event.company_id=settlement.company_id
     AND event.id=settlement.financial_event_id
    WHERE event.id IS NULL
       OR event.source_table<>'expense_settlements'
       OR event.source_id<>settlement.id

    UNION ALL

    SELECT
        'existing_return_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_returns returned
    LEFT JOIN public.financial_events event
      ON event.company_id=returned.company_id
     AND event.id=returned.financial_event_id
    WHERE event.id IS NULL
       OR event.source_table<>'expense_returns'
       OR event.source_id<>returned.id

    UNION ALL

    SELECT
        'existing_cash_return_drawer_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_returns returned
    LEFT JOIN public.cash_drawer_movements movement
      ON movement.company_id=returned.company_id
     AND movement.source_table='expense_returns'
     AND movement.source_id=returned.id
    WHERE returned.payment_method_type_snapshot='CASH'
      AND (
          returned.receiving_session_id IS NULL
          OR movement.id IS NULL
          OR movement.direction<>'IN'
          OR movement.movement_type<>'EXPENSE_RETURN'
          OR movement.amount<>returned.amount
          OR movement.cashier_session_id<>returned.receiving_session_id
      )

    UNION ALL

    SELECT
        'existing_noncash_return_without_drawer_effect',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_returns returned
    JOIN public.cash_drawer_movements movement
      ON movement.company_id=returned.company_id
     AND movement.source_table='expense_returns'
     AND movement.source_id=returned.id
    WHERE returned.payment_method_type_snapshot<>'CASH'

    UNION ALL

    SELECT
        'disbursed_expense_category_account_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('document_count',count(*))
    FROM disbursed_documents document
    LEFT JOIN public.expense_categories category
      ON category.company_id=document.company_id
     AND category.id=document.category_id
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id=document.company_id
     AND account.id=COALESCE(
         document.expense_account_id_snapshot,category.expense_account_id
     )
    WHERE category.id IS NULL
       OR account.id IS NULL
       OR NOT account.is_active
       OR NOT account.is_postable

    UNION ALL

    SELECT
        'cash_return_session_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('store_count',count(*))
    FROM (
        SELECT DISTINCT document.company_id,document.store_id
        FROM disbursed_documents document
        WHERE document.outstanding_amount>0
          AND EXISTS (
              SELECT 1
              FROM public.expense_disbursements disbursement
              WHERE disbursement.company_id=document.company_id
                AND disbursement.document_id=document.id
                AND disbursement.payment_method_type_snapshot='CASH'
          )
    ) scope
    LEFT JOIN open_store_sessions session
      ON session.company_id=scope.company_id
     AND session.store_id=scope.store_id
    WHERE session.store_id IS NULL

    UNION ALL

    SELECT
        'overdue_expense_settlement_inventory',
        'INFO',
        jsonb_build_object(
            'outstanding_documents',count(*) FILTER (
                WHERE outstanding_amount>0
            ),
            'overdue_documents',count(*) FILTER (
                WHERE outstanding_amount>0
                  AND expected_settlement_date<current_date
            ),
            'outstanding_amount_total',COALESCE(sum(outstanding_amount),0)
        )
    FROM disbursed_documents

    UNION ALL

    SELECT
        'expense_settlement_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'disbursed_documents',count(*),
            'cash_documents',count(*) FILTER (
                WHERE requested_payment_method_type_snapshot='CASH'
            ),
            'noncash_documents',count(*) FILTER (
                WHERE requested_payment_method_type_snapshot<>'CASH'
            ),
            'partially_settled_documents',count(*) FILTER (
                WHERE status='PARTIALLY_SETTLED'
            ),
            'settled_documents',count(*) FILTER (
                WHERE status IN ('SETTLED','SETTLED_NO_EXPENSE')
            ),
            'settlement_rows',(SELECT count(*) FROM public.expense_settlements),
            'return_rows',(SELECT count(*) FROM public.expense_returns)
        )
    FROM disbursed_documents

    UNION ALL

    SELECT
        'direct_expense_settlement_write_privilege',
        'INFO',
        jsonb_build_object(
            'expense_documents_update',has_table_privilege(
                'authenticated','public.expense_documents','UPDATE'
            ),
            'expense_disbursements_insert',has_table_privilege(
                'authenticated','public.expense_disbursements','INSERT'
            ),
            'expense_settlements_insert',has_table_privilege(
                'authenticated','public.expense_settlements','INSERT'
            ),
            'expense_returns_insert',has_table_privilege(
                'authenticated','public.expense_returns','INSERT'
            ),
            'cash_in_documents_insert',has_table_privilege(
                'authenticated','public.cash_in_documents','INSERT'
            ),
            'cash_drawer_movements_insert',has_table_privilege(
                'authenticated','public.cash_drawer_movements','INSERT'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3
        WHEN 'SETUP' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
