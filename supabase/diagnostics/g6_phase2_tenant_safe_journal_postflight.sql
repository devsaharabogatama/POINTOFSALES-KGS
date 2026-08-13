-- G6 corrective phase 2 postflight.
-- SAFETY: SELECT-only aggregate verification; no Finance routine execution.

WITH required_tables(table_name) AS (
    VALUES
        ('accounting_periods'),('finance_journals'),
        ('finance_journal_lines'),('finance_journal_audit')
), required_routines(routine_name) AS (
    VALUES
        ('create_accounting_period'),('lock_accounting_period'),
        ('reopen_accounting_period')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260810180000'

    UNION ALL

    SELECT
        'required_finance_journal_tables',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE to_regclass('public.' || table_name) IS NULL),
        jsonb_build_object(
            'missing',COALESCE(
                jsonb_agg(table_name ORDER BY table_name)
                    FILTER (WHERE to_regclass('public.' || table_name) IS NULL),
                '[]'::jsonb
            )
        )
    FROM required_tables

    UNION ALL

    SELECT
        'accounting_period_canonical_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.accounting_periods period
    WHERE period.master_version <= 0
       OR period.status NOT IN ('OPEN','LOCKED','REOPENED')
       OR period.start_date <> make_date(
           period.period_year,period.period_month,1
       )
       OR period.end_date <> (
           make_date(period.period_year,period.period_month,1)
           + INTERVAL '1 month' - INTERVAL '1 day'
       )::DATE

    UNION ALL

    SELECT
        'duplicate_company_period_month',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,period_year,period_month
        FROM public.accounting_periods
        GROUP BY company_id,period_year,period_month
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'rejected_journal_lines_quarantined',
        CASE WHEN count(*) = 0
                  AND NOT has_table_privilege(
                      'authenticated','public.journal_lines','SELECT'
                  )
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) + CASE WHEN has_table_privilege(
            'authenticated','public.journal_lines','SELECT'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'row_count',count(*),
            'authenticated_select',has_table_privilege(
                'authenticated','public.journal_lines','SELECT'
            )
        )
    FROM public.journal_lines

    UNION ALL

    SELECT
        'browser_canonical_finance_write_boundary',
        CASE WHEN bool_or(has_table_privilege(
            'authenticated',format('public.%I',table_name),
            'INSERT,UPDATE,DELETE'
        )) THEN 'FAIL' ELSE 'PASS' END,
        count(*) FILTER (WHERE has_table_privilege(
            'authenticated',format('public.%I',table_name),
            'INSERT,UPDATE,DELETE'
        )),
        jsonb_build_object(
            'writable_tables',COALESCE(
                jsonb_agg(table_name ORDER BY table_name) FILTER (
                    WHERE has_table_privilege(
                        'authenticated',format('public.%I',table_name),
                        'INSERT,UPDATE,DELETE'
                    )
                ),'[]'::jsonb
            )
        )
    FROM required_tables

    UNION ALL

    SELECT
        'canonical_finance_rls',
        CASE WHEN count(*) = 4 THEN 'PASS' ELSE 'FAIL' END,
        4-count(*),jsonb_build_object('rls_rows',count(*))
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN (
          'accounting_periods','finance_journals',
          'finance_journal_lines','finance_journal_audit'
      )
      AND relation.relrowsecurity

    UNION ALL

    SELECT
        'required_period_routines',
        CASE WHEN count(DISTINCT routine.proname) = 3
             THEN 'PASS' ELSE 'FAIL' END,
        3-count(DISTINCT routine.proname),
        jsonb_build_object(
            'routine_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(DISTINCT routine.proname ORDER BY routine.proname),
                '[]'::jsonb
            )
        )
    FROM required_routines expected
    LEFT JOIN pg_proc routine ON routine.proname = expected.routine_name
    LEFT JOIN pg_namespace namespace
      ON namespace.oid = routine.pronamespace AND namespace.nspname = 'public'
    WHERE routine.oid IS NULL OR namespace.oid IS NOT NULL

    UNION ALL

    SELECT
        'period_rpc_browser_boundary',
        CASE WHEN count(*) FILTER (
            WHERE has_function_privilege('anon',routine.oid,'EXECUTE')
               OR NOT has_function_privilege(
                   'authenticated',routine.oid,'EXECUTE'
               )
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE has_function_privilege('anon',routine.oid,'EXECUTE')
               OR NOT has_function_privilege(
                   'authenticated',routine.oid,'EXECUTE'
               )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    JOIN required_routines expected ON expected.routine_name = routine.proname
    WHERE namespace.nspname = 'public'

    UNION ALL

    SELECT
        'required_history_triggers',
        CASE WHEN count(*) = 5 THEN 'PASS' ELSE 'FAIL' END,
        5-count(*),jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_state
    WHERE trigger_state.tgname IN (
        'g6_touch_accounting_period','g6_guard_accounting_period_delete',
        'g6_guard_finance_journal','g6_guard_finance_journal_line',
        'g6_guard_finance_journal_audit'
    )
      AND NOT trigger_state.tgisinternal
      AND trigger_state.tgenabled <> 'D'

    UNION ALL

    SELECT
        'posted_journal_balance',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals journal
    WHERE journal.status = 'POSTED'
      AND (
          journal.total_debit <= 0
          OR round(journal.total_debit,4) <>
             round(journal.total_credit,4)
          OR journal.total_debit <> COALESCE((
              SELECT sum(line.debit)
              FROM public.finance_journal_lines line
              WHERE line.company_id = journal.company_id
                AND line.journal_id = journal.id
          ),0)
          OR journal.total_credit <> COALESCE((
              SELECT sum(line.credit)
              FROM public.finance_journal_lines line
              WHERE line.company_id = journal.company_id
                AND line.journal_id = journal.id
          ),0)
      )

    UNION ALL

    SELECT
        'posted_journal_snapshot_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('line_count',count(*))
    FROM public.finance_journal_lines line
    JOIN public.finance_journals journal
      ON journal.company_id = line.company_id AND journal.id = line.journal_id
    WHERE journal.status = 'POSTED'
      AND (
          btrim(line.account_code_snapshot) = ''
          OR btrim(line.account_name_snapshot) = ''
          OR line.normal_balance_snapshot NOT IN ('DEBIT','CREDIT')
      )

    UNION ALL

    SELECT
        'finance_phase2_runtime_inventory',
        'INFO',0,
        jsonb_build_object(
            'periods',(SELECT count(*) FROM public.accounting_periods),
            'canonical_journals',(SELECT count(*) FROM public.finance_journals),
            'canonical_lines',(
                SELECT count(*) FROM public.finance_journal_lines
            ),
            'audit_rows',(SELECT count(*) FROM public.finance_journal_audit),
            'legacy_journal_rows',(SELECT count(*) FROM public.journal_entries),
            'hold_events',(
                SELECT count(*) FROM public.financial_events
                WHERE status::TEXT = 'HOLD'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
