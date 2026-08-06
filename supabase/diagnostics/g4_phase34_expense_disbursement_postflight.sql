-- G4 phase 34 postflight: guarded Expense disbursement foundation.
-- SELECT-only verification.

WITH required_columns(column_name) AS (
    VALUES
        ('store_id'),('pos_terminal_id'),
        ('payment_settlement_route_snapshot'),
        ('payment_account_function_snapshot'),('transaction_category_id'),
        ('outstanding_account_id_snapshot'),('payment_account_id_snapshot'),
        ('document_master_version_snapshot'),('approval_snapshot')
), required_constraints(constraint_name) AS (
    VALUES
        ('expense_disbursement_route_check'),
        ('expense_disbursement_approval_snapshot_check'),
        ('fk_expense_disbursement_store'),
        ('fk_expense_disbursement_terminal'),
        ('fk_expense_disbursement_store_session'),
        ('fk_expense_disbursement_transaction_category'),
        ('fk_expense_disbursement_outstanding_account'),
        ('fk_expense_disbursement_payment_account')
), checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*)-1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260803070000'

    UNION ALL

    SELECT
        'required_disbursement_columns',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.column_name ORDER BY required.column_name)
                    FILTER (WHERE c.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM required_columns required
    LEFT JOIN information_schema.columns c
      ON c.table_schema='public'
     AND c.table_name='expense_disbursements'
     AND c.column_name=required.column_name

    UNION ALL

    SELECT
        'required_disbursement_constraints',
        CASE WHEN count(*) FILTER (WHERE con.oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE con.oid IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'constraint_rows',count(con.oid)
        )
    FROM required_constraints required
    LEFT JOIN pg_constraint con
      ON con.conname=required.constraint_name
     AND con.conrelid='public.expense_disbursements'::regclass

    UNION ALL

    SELECT
        'expense_disbursement_event_enum',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),
        jsonb_build_object('enum_rows',count(*))
    FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    JOIN pg_enum e ON e.enumtypid=t.oid
    WHERE n.nspname='public'
      AND t.typname='event_type'
      AND e.enumlabel='EXPENSE_DISBURSEMENT'

    UNION ALL

    SELECT
        'guarded_disbursement_rpc',
        CASE WHEN count(*)=1
                  AND bool_and(p.prosecdef)
                  AND bool_and(p.prosrc ILIKE '%FOR UPDATE%')
                  AND bool_and(p.prosrc ILIKE '%pg_advisory_xact_lock%')
                  AND bool_and(p.prosrc ILIKE '%INSUFFICIENT_EXPECTED_CASH%')
                  AND bool_and(p.prosrc ILIKE '%cash_drawer_movements%')
                  AND bool_and(p.prosrc ILIKE '%financial_events%')
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1
                  AND bool_and(p.prosecdef)
                  AND bool_and(p.prosrc ILIKE '%FOR UPDATE%')
                  AND bool_and(p.prosrc ILIKE '%pg_advisory_xact_lock%')
                  AND bool_and(p.prosrc ILIKE '%cash_drawer_movements%')
                  AND bool_and(p.prosrc ILIKE '%financial_events%')
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public'
      AND p.proname='disburse_expense'
      AND pg_get_function_identity_arguments(p.oid)=
          'p_document_id uuid, p_master_version bigint, '
          'p_cashier_session_id uuid, p_evidence_url text, '
          'p_idempotency_key uuid'

    UNION ALL

    SELECT
        'private_disbursement_account_resolver',
        CASE WHEN count(*)=1
                  AND bool_and(p.prosecdef)
                  AND bool_and(p.prosrc ILIKE
                      '%transaction_account_rules%')
                  AND bool_and(p.prosrc ILIKE
                      '%company_account_function_fallbacks%')
                  AND bool_and(p.prosrc ILIKE
                      '%system_function_key%')
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='private'
      AND p.proname='resolve_expense_disbursement_account'

    UNION ALL

    SELECT
        'cashier_expected_cash_drawer_integration',
        CASE WHEN count(*)>0
                  AND bool_and(p.prosrc ILIKE
                      '%cash_drawer_movements%')
                  AND bool_and(p.prosrc ILIKE
                      '%sales_return_refunds%')
                  AND bool_and(p.prosrc ILIKE '%sales_payments%')
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)>0
                  AND bool_and(p.prosrc ILIKE
                      '%cash_drawer_movements%')
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='private'
      AND p.proname='calculate_cashier_session_expected_cash'

    UNION ALL

    SELECT
        'browser_disbursement_rpc_boundary',
        CASE WHEN has_function_privilege(
                'authenticated',
                'public.disburse_expense(uuid,bigint,uuid,text,uuid)',
                'EXECUTE'
            ) AND NOT has_function_privilege(
                'anon',
                'public.disburse_expense(uuid,bigint,uuid,text,uuid)',
                'EXECUTE'
            ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_function_privilege(
                'authenticated',
                'public.disburse_expense(uuid,bigint,uuid,text,uuid)',
                'EXECUTE'
            ) AND NOT has_function_privilege(
                'anon',
                'public.disburse_expense(uuid,bigint,uuid,text,uuid)',
                'EXECUTE'
            ) THEN 0 ELSE 1 END,
        jsonb_build_object('authenticated_execute',has_function_privilege(
            'authenticated',
            'public.disburse_expense(uuid,bigint,uuid,text,uuid)','EXECUTE'
        ))

    UNION ALL

    SELECT
        'browser_direct_disbursement_write_boundary',
        CASE WHEN has_table_privilege(
                'authenticated','public.expense_disbursements',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.cash_drawer_movements',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.financial_events','INSERT'
            ) THEN 'FAIL' ELSE 'PASS' END,
        CASE WHEN has_table_privilege(
                'authenticated','public.expense_disbursements',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.cash_drawer_movements',
                'INSERT,UPDATE,DELETE'
            ) OR has_table_privilege(
                'authenticated','public.financial_events','INSERT'
            ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'disbursement_write',has_table_privilege(
                'authenticated','public.expense_disbursements',
                'INSERT,UPDATE,DELETE'
            ),
            'drawer_write',has_table_privilege(
                'authenticated','public.cash_drawer_movements',
                'INSERT,UPDATE,DELETE'
            ),
            'financial_event_insert',has_table_privilege(
                'authenticated','public.financial_events','INSERT'
            )
        )

    UNION ALL

    SELECT
        'invalid_disbursement_snapshot',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    WHERE disbursement.amount<=0
       OR btrim(disbursement.payment_method_name_snapshot)=''
       OR btrim(disbursement.payment_account_function_snapshot)=''
       OR disbursement.document_master_version_snapshot<=0
       OR jsonb_typeof(disbursement.approval_snapshot)<>'object'
       OR disbursement.financial_event_id IS NULL
       OR (disbursement.payment_method_type_snapshot='CASH' AND (
           disbursement.cashier_session_id IS NULL
           OR disbursement.pos_terminal_id IS NULL
           OR disbursement.payment_settlement_route_snapshot<>'CASH_DRAWER'
       ))
       OR (disbursement.payment_method_type_snapshot<>'CASH' AND (
           disbursement.cashier_session_id IS NOT NULL
           OR disbursement.pos_terminal_id IS NOT NULL
           OR disbursement.payment_settlement_route_snapshot NOT IN
              ('DIRECT_BANK','CLEARING')
       ))

    UNION ALL

    SELECT
        'disbursement_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    LEFT JOIN public.financial_events event
      ON event.company_id=disbursement.company_id
     AND event.id=disbursement.financial_event_id
    WHERE event.id IS NULL
       OR event.event_type::TEXT<>'EXPENSE_DISBURSEMENT'
       OR event.source_table<>'expense_disbursements'
       OR event.source_id<>disbursement.id
       OR event.system_event_key<>'EXPENSE_DISBURSEMENT'
       OR event.status::TEXT<>'HOLD'

    UNION ALL

    SELECT
        'cash_disbursement_drawer_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    LEFT JOIN public.cash_drawer_movements movement
      ON movement.company_id=disbursement.company_id
     AND movement.source_table='expense_disbursements'
     AND movement.source_id=disbursement.id
    WHERE disbursement.payment_method_type_snapshot='CASH'
      AND (movement.id IS NULL OR movement.direction<>'OUT'
           OR movement.movement_type<>'EXPENSE_DISBURSEMENT'
           OR movement.amount<>disbursement.amount
           OR movement.cashier_session_id<>disbursement.cashier_session_id)

    UNION ALL

    SELECT
        'noncash_disbursement_without_drawer_effect',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    JOIN public.cash_drawer_movements movement
      ON movement.company_id=disbursement.company_id
     AND movement.source_table='expense_disbursements'
     AND movement.source_id=disbursement.id
    WHERE disbursement.payment_method_type_snapshot<>'CASH'

    UNION ALL

    SELECT
        'expense_disbursement_total_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('document_count',count(*))
    FROM (
        SELECT document.id
        FROM public.expense_documents document
        LEFT JOIN public.expense_disbursements disbursement
          ON disbursement.company_id=document.company_id
         AND disbursement.document_id=document.id
        GROUP BY document.id,document.disbursed_amount
        HAVING document.disbursed_amount<>
            COALESCE(sum(disbursement.amount),0)
    ) mismatch

    UNION ALL

    SELECT
        'expense_disbursement_journal_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('journal_rows',count(*))
    FROM public.journal_entries journal
    JOIN public.financial_events event
      ON event.company_id=journal.company_id
     AND event.id=journal.financial_event_id
    WHERE event.source_table='expense_disbursements'

    UNION ALL

    SELECT
        'expense_disbursement_runtime_inventory',
        'INFO',0::BIGINT,
        jsonb_build_object(
            'approved_documents',(
                SELECT count(*) FROM public.expense_documents
                WHERE status='APPROVED'
            ),
            'disbursed_documents',(
                SELECT count(*) FROM public.expense_documents
                WHERE status='DISBURSED'
            ),
            'disbursement_rows',count(*),
            'cash_rows',count(*) FILTER (
                WHERE payment_method_type_snapshot='CASH'
            ),
            'noncash_rows',count(*) FILTER (
                WHERE payment_method_type_snapshot<>'CASH'
            )
        )
    FROM public.expense_disbursements
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
