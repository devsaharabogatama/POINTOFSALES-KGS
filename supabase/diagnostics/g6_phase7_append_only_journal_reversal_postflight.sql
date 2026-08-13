-- G6 corrective phase 7A postflight: guarded append-only journal reversal.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*)-1) AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260811090000'

    UNION ALL

    SELECT
        'guarded_reversal_routine',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.oid = to_regprocedure(
          'public.reverse_finance_journal(uuid,bigint,date,text,uuid)'
      )

    UNION ALL

    SELECT
        'reversal_runtime_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname = 'reverse_finance_journal'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%SOURCE_DOCUMENT_REVERSAL_REQUIRED%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%REVERSAL_REASON_REQUIRED%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%OPEN_ACCOUNTING_PERIOD_REQUIRED%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%JOURNAL_ALREADY_REVERSED%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%FOR UPDATE%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%line.credit,line.debit%'

    UNION ALL

    SELECT
        'reversal_source_snapshot_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'private'
      AND routine.proname = 'trg_g6_guard_finance_journal_line'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%REVERSAL_LINE_SOURCE_MISMATCH%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%v_original_line.account_code_snapshot%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%v_original_line.credit%'
      AND pg_get_functiondef(routine.oid)
            ILIKE '%original_journal.status = ''POSTED''%'

    UNION ALL

    SELECT
        'reversal_unique_index',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes index_state
    WHERE index_state.schemaname = 'public'
      AND index_state.tablename = 'finance_journals'
      AND index_state.indexname = 'uq_finance_journals_company_reversal'

    UNION ALL

    SELECT
        'reversal_audit_action_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-1),
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint constraint_state
    JOIN pg_class relation ON relation.oid = constraint_state.conrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'finance_journal_audit'
      AND constraint_state.contype = 'c'
      AND pg_get_constraintdef(constraint_state.oid) ILIKE '%REVERSE%'

    UNION ALL

    SELECT
        'browser_reversal_rpc_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
                'EXECUTE'
            ),
            'anon_execute',has_function_privilege(
                'anon',
                'public.reverse_finance_journal(uuid,bigint,date,text,uuid)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'browser_direct_journal_write_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object(
            'writable_relations',COALESCE(
                jsonb_agg(relation_name ORDER BY relation_name),
                '[]'::jsonb
            )
        )
    FROM (
        SELECT relation_name
        FROM (VALUES
            ('finance_journals'),('finance_journal_lines'),
            ('finance_journal_audit'),('accounting_periods')
        ) required(relation_name)
        WHERE has_table_privilege(
            'authenticated',format('public.%I',relation_name),
            'INSERT,UPDATE,DELETE'
        )
    ) writable

    UNION ALL

    SELECT
        'posted_journal_balance_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals journal
    WHERE journal.status = 'POSTED'
      AND (
          journal.total_debit <= 0
          OR journal.total_debit <> journal.total_credit
      )

    UNION ALL

    SELECT
        'duplicate_journal_reversal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,reversal_of_journal_id
        FROM public.finance_journals
        WHERE reversal_of_journal_id IS NOT NULL
        GROUP BY company_id,reversal_of_journal_id
        HAVING count(*) > 1
    ) duplicate_group

    UNION ALL

    SELECT
        'automatic_journal_without_source_reversal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals reversal
    JOIN public.finance_journals original
      ON original.company_id = reversal.company_id
     AND original.id = reversal.reversal_of_journal_id
    WHERE reversal.journal_type = 'REVERSAL'
      AND original.journal_type NOT IN ('MANUAL','OPENING_BALANCE')

    UNION ALL

    SELECT
        'reversal_runtime_inventory','INFO',0,
        jsonb_build_object(
            'posted_journals',count(*) FILTER (WHERE status='POSTED'),
            'manual_journals',count(*) FILTER (WHERE journal_type='MANUAL'),
            'opening_balance_journals',count(*) FILTER (
                WHERE journal_type='OPENING_BALANCE'
            ),
            'automatic_journals',count(*) FILTER (
                WHERE journal_type='AUTOMATIC'
            ),
            'reversal_journals',count(*) FILTER (
                WHERE journal_type='REVERSAL'
            )
        )
    FROM public.finance_journals
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
