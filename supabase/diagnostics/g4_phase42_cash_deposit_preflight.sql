-- G4 phase 42 preflight: canonical multi-Session Cash Deposit readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Deposit number, bank reference, or actor.
-- - Run the entire file in Supabase SQL Editor and export the final result.

WITH required_versions(version) AS (
    VALUES ('20260729040000'),('20260804100000')
), expected_tables(table_name) AS (
    VALUES
        ('cash_deposit_policies'),
        ('cash_deposit_documents'),
        ('cash_deposit_session_lines'),
        ('cash_deposit_audit'),
        ('deposit_variance_exceptions'),
        ('deposit_variance_allocations')
), expected_routines(routine_name) AS (
    VALUES
        ('list_cash_deposit_eligible_sessions'),
        ('save_cash_deposit_draft'),
        ('submit_cash_deposit'),
        ('review_cash_deposit')
), required_functions(function_key) AS (
    VALUES
        ('CASH_DRAWER'),
        ('MAIN_CASH'),
        ('CASH_IN_TRANSIT'),
        ('BANK'),
        ('UNDER_DEPOSIT_CONTROL'),
        ('CASH_OVERAGE_LIABILITY')
), legacy_deposits AS (
    SELECT
        deposit.id,
        deposit.company_id,
        deposit.store_id,
        deposit.session_id,
        deposit.deposit_no,
        deposit.amount,
        deposit.bank_account_info,
        session.status AS session_status,
        session.closing_cash_actual,
        session.company_id AS session_company_id,
        session.store_id AS session_store_id
    FROM public.bank_deposits deposit
    LEFT JOIN public.cashier_sessions session ON session.id=deposit.session_id
), legacy_deposit_events AS (
    SELECT DISTINCT event.source_id
    FROM public.financial_events event
    WHERE event.source_table='bank_deposits'
), active_company_function_readiness AS (
    SELECT company.id AS company_id,function.function_key
    FROM public.companies company
    CROSS JOIN required_functions function
    WHERE company.status='ACTIVE'
      AND NOT EXISTS (
          SELECT 1
          FROM public.chart_of_accounts account
          WHERE account.company_id=company.id
            AND account.system_function_key=function.function_key
            AND account.is_active
            AND account.is_postable
      )
      AND NOT EXISTS (
          SELECT 1
          FROM public.company_account_function_fallbacks fallback
          JOIN public.chart_of_accounts account
            ON account.company_id=fallback.company_id
           AND account.id=fallback.account_id
          WHERE fallback.company_id=company.id
            AND fallback.account_function_key=function.function_key
            AND fallback.status='ACTIVE'
            AND fallback.effective_from<=clock_timestamp()
            AND (
                fallback.effective_to IS NULL
                OR fallback.effective_to>clock_timestamp()
            )
            AND account.is_active
            AND account.is_postable
      )
), checks AS (
    SELECT
        'g4_phase42_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'canonical_cash_deposit_schema_state',
        CASE WHEN count(*) FILTER (WHERE existing.table_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_tables',count(*),
            'missing_tables',COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER (WHERE existing.table_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_tables expected
    LEFT JOIN information_schema.tables existing
      ON existing.table_schema='public'
     AND existing.table_name=expected.table_name

    UNION ALL

    SELECT
        'canonical_cash_deposit_routine_state',
        CASE WHEN count(*) FILTER (WHERE routine.oid IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_routines',count(*),
            'missing_routines',COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER (WHERE routine.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_routines expected
    LEFT JOIN pg_proc routine
      ON routine.proname=expected.routine_name
     AND routine.pronamespace='public'::regnamespace

    UNION ALL

    SELECT
        'legacy_bank_deposit_inventory',
        'INFO',
        jsonb_build_object(
            'deposit_rows',count(*),
            'companies',count(DISTINCT company_id),
            'stores',count(DISTINCT store_id),
            'sessions',count(DISTINCT session_id),
            'amount_total',COALESCE(sum(amount),0)
        )
    FROM legacy_deposits

    UNION ALL

    SELECT
        'legacy_bank_deposit_backfill_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count',count(*))
    FROM legacy_deposits

    UNION ALL

    SELECT
        'blank_legacy_deposit_identity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM legacy_deposits
    WHERE btrim(COALESCE(deposit_no,''))=''
       OR btrim(COALESCE(bank_account_info,''))=''

    UNION ALL

    SELECT
        'nonpositive_legacy_deposit_amount',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM legacy_deposits
    WHERE amount<=0

    UNION ALL

    SELECT
        'legacy_deposit_tenant_reference_integrity',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('orphan_or_cross_tenant_rows',count(*))
    FROM legacy_deposits
    WHERE session_company_id IS NULL
       OR session_company_id IS DISTINCT FROM company_id
       OR session_store_id IS DISTINCT FROM store_id

    UNION ALL

    SELECT
        'legacy_deposit_without_closed_session',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM legacy_deposits
    WHERE session_status IS DISTINCT FROM 'CLOSED'::public.session_status

    UNION ALL

    SELECT
        'duplicate_normalized_legacy_deposit_no',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT
            company_id,
            upper(regexp_replace(btrim(deposit_no),'\s+',' ','g'))
        FROM legacy_deposits
        GROUP BY
            company_id,
            upper(regexp_replace(btrim(deposit_no),'\s+',' ','g'))
        HAVING count(*)>1
    ) duplicate_groups

    UNION ALL

    SELECT
        'legacy_session_with_multiple_deposits',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('session_count',count(*))
    FROM (
        SELECT company_id,session_id
        FROM legacy_deposits
        GROUP BY company_id,session_id
        HAVING count(*)>1
    ) duplicate_sessions

    UNION ALL

    SELECT
        'legacy_deposit_without_financial_event',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM legacy_deposits deposit
    LEFT JOIN legacy_deposit_events event ON event.source_id=deposit.id
    WHERE event.source_id IS NULL

    UNION ALL

    SELECT
        'legacy_deposit_trigger_state',
        CASE WHEN count(*) FILTER (WHERE trigger.tgenabled<>'D')=0
             THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'trigger_rows',count(*),
            'enabled_trigger_rows',count(*) FILTER (WHERE trigger.tgenabled<>'D')
        )
    FROM pg_trigger trigger
    JOIN pg_class relation ON relation.oid=trigger.tgrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname='bank_deposits'
      AND NOT trigger.tgisinternal

    UNION ALL

    SELECT
        'closed_session_missing_actual_cash',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('session_count',count(*))
    FROM public.cashier_sessions
    WHERE status='CLOSED'::public.session_status
      AND closing_cash_actual IS NULL

    UNION ALL

    SELECT
        'closed_session_deposit_inventory',
        'INFO',
        jsonb_build_object(
            'closed_sessions',count(*),
            'sessions_without_legacy_deposit',count(*) FILTER (
                WHERE NOT EXISTS (
                    SELECT 1 FROM public.bank_deposits deposit
                    WHERE deposit.company_id=session.company_id
                      AND deposit.store_id=session.store_id
                      AND deposit.session_id=session.id
                )
            ),
            'actual_closing_cash_total',COALESCE(sum(closing_cash_actual),0)
        )
    FROM public.cashier_sessions session
    WHERE status='CLOSED'::public.session_status

    UNION ALL

    SELECT
        'cash_deposit_transaction_category_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    WHERE company.status='ACTIVE'
      AND NOT EXISTS (
          SELECT 1 FROM public.transaction_categories category
          WHERE category.company_id=company.id
            AND category.system_key='CASH_DEPOSIT'
            AND category.is_active
      )

    UNION ALL

    SELECT
        'cash_deposit_account_function_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'companies_affected',count(DISTINCT company_id),
            'missing_company_function_rows',count(*)
        )
    FROM active_company_function_readiness

    UNION ALL

    SELECT
        'direct_cash_deposit_write_privilege',
        'INFO',
        jsonb_build_object(
            'legacy_insert',has_table_privilege(
                'authenticated','public.bank_deposits','INSERT'
            ),
            'legacy_update',has_table_privilege(
                'authenticated','public.bank_deposits','UPDATE'
            ),
            'legacy_delete',has_table_privilege(
                'authenticated','public.bank_deposits','DELETE'
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
