-- G4 phase 29 preflight: canonical Expense and non-sale Cash flow readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Expense/category/person/business names.

WITH required_versions(version) AS (
    VALUES
        ('20260803010000'),
        ('20260803020000')
), expected_tables(table_name) AS (
    VALUES
        ('expense_categories'),
        ('expense_approval_policies'),
        ('expense_documents'),
        ('expense_disbursements'),
        ('expense_settlements'),
        ('expense_returns'),
        ('cash_in_documents'),
        ('cash_drawer_movements'),
        ('expense_audit')
), active_stores AS (
    SELECT s.id AS store_id, s.company_id
    FROM public.stores s
    JOIN public.companies c ON c.id = s.company_id
    WHERE c.status = 'ACTIVE'
      AND s.status = 'ACTIVE'
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
                      FROM public.payment_method_store_assignments a
                      WHERE a.company_id = pm.company_id
                        AND a.payment_method_id = pm.id
                        AND a.store_id = s.store_id
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
                      FROM public.payment_method_store_assignments a
                      WHERE a.company_id = pm.company_id
                        AND a.payment_method_id = pm.id
                        AND a.store_id = s.store_id
                  )
              )
        ) AS has_transfer
    FROM active_stores s
), required_system_events(system_key) AS (
    VALUES ('EXPENSE_DISBURSEMENT'),('EXPENSE_SETTLEMENT'),('CASH_IN')
), required_account_functions(function_key) AS (
    VALUES ('OUTSTANDING_EXPENSE'),('EXPENSE'),('CASH_DRAWER'),('BANK')
), active_companies AS (
    SELECT id AS company_id
    FROM public.companies
    WHERE status = 'ACTIVE'
), company_event_readiness AS (
    SELECT c.company_id, e.system_key
    FROM active_companies c
    CROSS JOIN required_system_events e
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.transaction_categories tc
        WHERE tc.company_id = c.company_id
          AND tc.system_key = e.system_key
          AND tc.is_active
    )
), company_account_readiness AS (
    SELECT c.company_id, f.function_key
    FROM active_companies c
    CROSS JOIN required_account_functions f
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.chart_of_accounts coa
        WHERE coa.company_id = c.company_id
          AND coa.system_function_key = f.function_key
          AND coa.is_active
          AND coa.is_postable
    )
), checks AS (
    SELECT
        'g4_phase29_dependencies'::text AS check_name,
        CASE WHEN count(*) FILTER (WHERE m.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(r.version ORDER BY r.version)
                    FILTER (WHERE m.version IS NULL),
                '[]'::jsonb
            )
        ) AS details
    FROM required_versions r
    LEFT JOIN private.kgs_schema_migrations m ON m.version = r.version

    UNION ALL

    SELECT
        'canonical_expense_schema_state',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || e.table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_tables',COALESCE(
                jsonb_agg(e.table_name ORDER BY e.table_name)
                    FILTER (WHERE to_regclass('public.' || e.table_name) IS NULL),
                '[]'::jsonb
            ),
            'expected_tables',count(*)
        )
    FROM expected_tables e

    UNION ALL

    SELECT
        'legacy_cash_advance_inventory',
        'INFO',
        jsonb_build_object(
            'rows',count(*),
            'companies',count(DISTINCT company_id),
            'stores',count(DISTINCT store_id),
            'sessions',count(DISTINCT session_id),
            'categories',count(DISTINCT lower(regexp_replace(
                btrim(category),'\s+',' ','g'
            ))),
            'cash_rows',count(*) FILTER (
                WHERE payment_method::text = 'Cash'
            ),
            'noncash_rows',count(*) FILTER (
                WHERE payment_method::text <> 'Cash'
            )
        )
    FROM public.cash_advances

    UNION ALL

    SELECT
        'invalid_legacy_cash_advance_value',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.cash_advances
    WHERE amount <= 0
       OR btrim(category) = ''

    UNION ALL

    SELECT
        'legacy_cash_advance_tenant_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.cash_advances ca
    LEFT JOIN public.cashier_sessions cs
      ON cs.company_id = ca.company_id
     AND cs.store_id = ca.store_id
     AND cs.id = ca.session_id
    WHERE cs.id IS NULL

    UNION ALL

    SELECT
        'legacy_cash_advance_backfill_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'rows',count(*),
            'normalized_category_groups',count(DISTINCT (
                company_id,
                lower(regexp_replace(btrim(category),'\s+',' ','g'))
            ))
        )
    FROM public.cash_advances

    UNION ALL

    SELECT
        'legacy_cash_advance_financial_event_inventory',
        'INFO',
        jsonb_build_object(
            'event_rows',count(*),
            'source_rows',count(DISTINCT source_id),
            'hold_rows',count(*) FILTER (WHERE status::text = 'HOLD'),
            'processed_rows',count(*) FILTER (WHERE processed_at IS NOT NULL)
        )
    FROM public.financial_events
    WHERE source_table = 'cash_advances'

    UNION ALL

    SELECT
        'legacy_cash_advance_trigger_state',
        'REVIEW',
        jsonb_build_object(
            'trigger_rows',count(*),
            'enabled_trigger_rows',count(*) FILTER (WHERE t.tgenabled <> 'D')
        )
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = 'cash_advances'
      AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'active_store_expense_payment_readiness',
        CASE WHEN count(*) FILTER (WHERE NOT has_cash) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_stores',count(*),
            'stores_without_cash',count(*) FILTER (WHERE NOT has_cash),
            'stores_without_transfer',count(*) FILTER (WHERE NOT has_transfer)
        )
    FROM store_payment_readiness

    UNION ALL

    SELECT
        'active_company_expense_category_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'missing_company_event_rows',count(*),
            'companies_affected',count(DISTINCT company_id),
            'system_events',COALESCE(
                jsonb_agg(DISTINCT system_key) FILTER (WHERE system_key IS NOT NULL),
                '[]'::jsonb
            )
        )
    FROM company_event_readiness

    UNION ALL

    SELECT
        'active_company_expense_account_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'missing_company_function_rows',count(*),
            'companies_affected',count(DISTINCT company_id),
            'functions',COALESCE(
                jsonb_agg(DISTINCT function_key)
                    FILTER (WHERE function_key IS NOT NULL),
                '[]'::jsonb
            )
        )
    FROM company_account_readiness

    UNION ALL

    SELECT
        'open_cashier_session_expense_scope',
        'INFO',
        jsonb_build_object(
            'open_sessions',count(*),
            'companies',count(DISTINCT company_id),
            'stores',count(DISTINCT store_id),
            'terminals',count(DISTINCT pos_id)
        )
    FROM public.cashier_sessions
    WHERE status::text = 'OPEN'

    UNION ALL

    SELECT
        'expense_feature_entitlement_state',
        'INFO',
        jsonb_build_object(
            'catalog_rows',count(*),
            'enabled_companies',count(*) FILTER (WHERE is_enabled)
        )
    FROM public.company_features
    WHERE feature_code = 'expense_enabled'

    UNION ALL

    SELECT
        'direct_expense_cash_write_privilege',
        'INFO',
        jsonb_build_object(
            'legacy_cash_advance_insert',has_table_privilege(
                'authenticated','public.cash_advances','INSERT'
            ),
            'legacy_cash_advance_update',has_table_privilege(
                'authenticated','public.cash_advances','UPDATE'
            ),
            'cashier_session_update',has_table_privilege(
                'authenticated','public.cashier_sessions','UPDATE'
            ),
            'financial_event_insert',has_table_privilege(
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
