-- G4 phase 33 preflight: approved Expense disbursement readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Expense/category/person/business names.
-- - Does not disburse Cash/Transfer or alter expected Cashier drawer balance.

WITH required_versions(version) AS (
    VALUES ('20260803040000')
), enabled_companies AS (
    SELECT c.id AS company_id
    FROM public.companies c
    JOIN public.company_features feature
      ON feature.company_id = c.id
     AND feature.feature_code = 'expense_enabled'
     AND feature.is_enabled
    WHERE c.status = 'ACTIVE'
), active_stores AS (
    SELECT s.id AS store_id, s.company_id
    FROM public.stores s
    JOIN enabled_companies c ON c.company_id = s.company_id
    WHERE s.status = 'ACTIVE'
), approved_expenses AS (
    SELECT d.*
    FROM public.expense_documents d
    WHERE d.status = 'APPROVED'
), store_payment_readiness AS (
    SELECT
        s.company_id,
        s.store_id,
        EXISTS (
            SELECT 1
            FROM public.payment_methods pm
            WHERE pm.company_id = s.company_id
              AND pm.method_type = 'CASH'
              AND pm.settlement_route = 'CASH_DRAWER'
              AND pm.is_active
              AND pm.effective_from <= clock_timestamp()
              AND (pm.effective_to IS NULL
                   OR pm.effective_to > clock_timestamp())
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments assignment
                      WHERE assignment.company_id = pm.company_id
                        AND assignment.payment_method_id = pm.id
                        AND assignment.store_id = s.store_id
                  )
              )
        ) AS has_cash,
        EXISTS (
            SELECT 1
            FROM public.payment_methods pm
            WHERE pm.company_id = s.company_id
              AND pm.method_type IN ('TRANSFER','QRIS','CARD','E_WALLET')
              AND pm.settlement_route IN ('DIRECT_BANK','CLEARING')
              AND pm.is_active
              AND pm.effective_from <= clock_timestamp()
              AND (pm.effective_to IS NULL
                   OR pm.effective_to > clock_timestamp())
              AND (
                  pm.available_all_stores
                  OR EXISTS (
                      SELECT 1
                      FROM public.payment_method_store_assignments assignment
                      WHERE assignment.company_id = pm.company_id
                        AND assignment.payment_method_id = pm.id
                        AND assignment.store_id = s.store_id
                  )
              )
        ) AS has_noncash
    FROM active_stores s
), required_account_functions(function_key) AS (
    VALUES ('OUTSTANDING_EXPENSE'),('CASH_DRAWER'),('BANK')
), missing_company_accounts AS (
    SELECT c.company_id, required_function.function_key
    FROM enabled_companies c
    CROSS JOIN required_account_functions required_function
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.chart_of_accounts account
        WHERE account.company_id = c.company_id
          AND account.system_function_key = required_function.function_key
          AND account.is_active
          AND account.is_postable
    )
), expected_cash_routine AS (
    SELECT p.oid, p.prosrc
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'calculate_cashier_session_expected_cash'
), checks AS (
    SELECT
        'g4_phase33_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
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
      ON migration.version = required.version

    UNION ALL

    SELECT
        'canonical_disbursement_routine_state',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'disburse_expense_exists',count(*) = 1
        )
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'disburse_expense'

    UNION ALL

    SELECT
        'disbursement_approval_snapshot_state',
        CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'approval_snapshot_columns',COALESCE(
                jsonb_agg(column_name ORDER BY column_name),
                '[]'::jsonb
            )
        )
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'expense_disbursements'
      AND column_name IN (
          'approval_snapshot','approval_required_snapshot',
          'approval_policy_version_snapshot'
      )

    UNION ALL

    SELECT
        'expense_disbursement_event_enum_state',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expense_disbursement_event_exists',count(*) = 1
        )
    FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    JOIN pg_enum e ON e.enumtypid = t.oid
    WHERE n.nspname = 'public'
      AND t.typname = 'event_type'
      AND e.enumlabel = 'EXPENSE_DISBURSEMENT'

    UNION ALL

    SELECT
        'cashier_expected_cash_disbursement_state',
        CASE WHEN count(*) > 0
                   AND bool_or(prosrc ILIKE '%cash_drawer_movements%')
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'cash_drawer_movement_included',COALESCE(
                bool_or(prosrc ILIKE '%cash_drawer_movements%'),FALSE
            )
        )
    FROM expected_cash_routine

    UNION ALL

    SELECT
        'approved_expense_inventory',
        'INFO',
        jsonb_build_object(
            'approved_documents',count(*),
            'companies',count(DISTINCT company_id),
            'stores',count(DISTINCT store_id),
            'cash_documents',count(*) FILTER (
                WHERE requested_payment_method_type_snapshot = 'CASH'
            ),
            'noncash_documents',count(*) FILTER (
                WHERE requested_payment_method_type_snapshot <> 'CASH'
            ),
            'requested_amount_total',COALESCE(sum(requested_amount),0)
        )
    FROM approved_expenses

    UNION ALL

    SELECT
        'invalid_approved_expense_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM approved_expenses
    WHERE requested_amount <= 0
       OR disbursed_amount <> 0
       OR actual_expense_amount <> 0
       OR returned_amount <> 0
       OR outstanding_amount <> 0
       OR approved_by IS NULL
       OR approved_at IS NULL
       OR btrim(category_name_snapshot) = ''
       OR btrim(requested_payment_method_name_snapshot) = ''
       OR (evidence_policy_snapshot = 'REQUIRED' AND evidence_url IS NULL)

    UNION ALL

    SELECT
        'approved_expense_payment_reference_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM approved_expenses expense
    LEFT JOIN public.payment_methods method
      ON method.company_id = expense.company_id
     AND method.id = expense.requested_payment_method_id
    WHERE method.id IS NULL
       OR NOT method.is_active
       OR method.effective_from > clock_timestamp()
       OR (method.effective_to IS NOT NULL
           AND method.effective_to <= clock_timestamp())
       OR method.method_type <> expense.requested_payment_method_type_snapshot
       OR (method.method_type = 'CASH'
           AND method.settlement_route <> 'CASH_DRAWER')
       OR (method.method_type <> 'CASH'
           AND method.settlement_route NOT IN ('DIRECT_BANK','CLEARING'))
       OR (
           NOT method.available_all_stores
           AND NOT EXISTS (
               SELECT 1
               FROM public.payment_method_store_assignments assignment
               WHERE assignment.company_id = method.company_id
                 AND assignment.payment_method_id = method.id
                 AND assignment.store_id = expense.store_id
           )
       )

    UNION ALL

    SELECT
        'approved_cash_expense_session_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('document_count',count(*))
    FROM approved_expenses expense
    WHERE expense.requested_payment_method_type_snapshot = 'CASH'
      AND NOT EXISTS (
          SELECT 1
          FROM public.cashier_sessions session
          WHERE session.company_id = expense.company_id
            AND session.store_id = expense.store_id
            AND session.status::text = 'OPEN'
      )

    UNION ALL

    SELECT
        'enabled_store_disbursement_payment_readiness',
        CASE WHEN count(*) FILTER (WHERE NOT has_cash) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_stores',count(*),
            'stores_without_cash',count(*) FILTER (WHERE NOT has_cash),
            'stores_without_noncash',count(*) FILTER (WHERE NOT has_noncash)
        )
    FROM store_payment_readiness

    UNION ALL

    SELECT
        'enabled_company_disbursement_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM enabled_companies company
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.transaction_categories category
        WHERE category.company_id = company.company_id
          AND category.system_key = 'EXPENSE_DISBURSEMENT'
          AND category.is_active
    )

    UNION ALL

    SELECT
        'enabled_company_disbursement_account_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'missing_company_function_rows',count(*),
            'companies_affected',count(DISTINCT company_id),
            'functions',COALESCE(
                jsonb_agg(DISTINCT function_key)
                    FILTER (WHERE function_key IS NOT NULL),
                '[]'::jsonb
            )
        )
    FROM missing_company_accounts

    UNION ALL

    SELECT
        'invalid_existing_disbursement_reference',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    LEFT JOIN public.expense_documents expense
      ON expense.company_id = disbursement.company_id
     AND expense.id = disbursement.document_id
    LEFT JOIN public.payment_methods method
      ON method.company_id = disbursement.company_id
     AND method.id = disbursement.payment_method_id
    LEFT JOIN public.cashier_sessions session
      ON session.company_id = disbursement.company_id
     AND session.id = disbursement.cashier_session_id
    WHERE expense.id IS NULL
       OR method.id IS NULL
       OR disbursement.amount <= 0
       OR btrim(disbursement.payment_method_name_snapshot) = ''
       OR method.method_type <> disbursement.payment_method_type_snapshot
       OR (disbursement.payment_method_type_snapshot = 'CASH'
           AND (
               session.id IS NULL
               OR session.store_id <> expense.store_id
           ))

    UNION ALL

    SELECT
        'existing_disbursement_financial_event_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    LEFT JOIN public.financial_events event
      ON event.company_id = disbursement.company_id
     AND event.id = disbursement.financial_event_id
    WHERE event.id IS NULL
       OR event.source_table <> 'expense_disbursements'
       OR event.source_id <> disbursement.id

    UNION ALL

    SELECT
        'existing_cash_disbursement_drawer_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    LEFT JOIN public.cash_drawer_movements movement
      ON movement.company_id = disbursement.company_id
     AND movement.source_table = 'expense_disbursements'
     AND movement.source_id = disbursement.id
    WHERE disbursement.payment_method_type_snapshot = 'CASH'
      AND (
          movement.id IS NULL
          OR movement.direction <> 'OUT'
          OR movement.movement_type <> 'EXPENSE_DISBURSEMENT'
          OR movement.amount <> disbursement.amount
          OR movement.cashier_session_id <> disbursement.cashier_session_id
      )

    UNION ALL

    SELECT
        'noncash_disbursement_without_drawer_effect',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.expense_disbursements disbursement
    JOIN public.cash_drawer_movements movement
      ON movement.company_id = disbursement.company_id
     AND movement.source_table = 'expense_disbursements'
     AND movement.source_id = disbursement.id
    WHERE disbursement.payment_method_type_snapshot <> 'CASH'

    UNION ALL

    SELECT
        'expense_document_disbursement_total_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('document_count',count(*))
    FROM (
        SELECT expense.id
        FROM public.expense_documents expense
        LEFT JOIN public.expense_disbursements disbursement
          ON disbursement.company_id = expense.company_id
         AND disbursement.document_id = expense.id
        GROUP BY expense.id,expense.disbursed_amount
        HAVING expense.disbursed_amount <> COALESCE(sum(disbursement.amount),0)
    ) mismatch

    UNION ALL

    SELECT
        'expense_disbursement_inventory',
        'INFO',
        jsonb_build_object(
            'rows',count(*),
            'documents',count(DISTINCT document_id),
            'cash_rows',count(*) FILTER (
                WHERE payment_method_type_snapshot = 'CASH'
            ),
            'noncash_rows',count(*) FILTER (
                WHERE payment_method_type_snapshot <> 'CASH'
            ),
            'financial_event_rows',count(*) FILTER (
                WHERE financial_event_id IS NOT NULL
            )
        )
    FROM public.expense_disbursements

    UNION ALL

    SELECT
        'direct_expense_disbursement_write_privilege',
        'INFO',
        jsonb_build_object(
            'expense_documents_update',has_table_privilege(
                'authenticated','public.expense_documents','UPDATE'
            ),
            'expense_disbursements_insert',has_table_privilege(
                'authenticated','public.expense_disbursements','INSERT'
            ),
            'cash_drawer_movements_insert',has_table_privilege(
                'authenticated','public.cash_drawer_movements','INSERT'
            ),
            'financial_events_insert',has_table_privilege(
                'authenticated','public.financial_events','INSERT'
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
