-- G6 corrective phase 7 preflight: Finance operations UI and pilot readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP object, function call with side effects,
--   privilege change, queue processing, journal posting, or reversal.
-- - Returns aggregate metadata only; no Company, user, account, or document name.

WITH required_versions(version) AS (
    VALUES
        ('20260810180000'),
        ('20260810210000'),
        ('20260810220000'),
        ('20260810230000')
), required_relations(relation_name) AS (
    VALUES
        ('accounting_periods'),
        ('finance_journals'),
        ('finance_journal_lines'),
        ('finance_journal_audit'),
        ('finance_posting_queue_runs'),
        ('finance_posting_queue_items'),
        ('finance_posting_queue_audit'),
        ('finance_report_definitions'),
        ('finance_report_versions'),
        ('finance_report_lines'),
        ('finance_reconciliation_documents'),
        ('finance_reconciliation_allocations'),
        ('finance_reconciliation_audit')
), required_routines(signature) AS (
    VALUES
        ('public.create_accounting_period(integer,integer)'),
        ('public.lock_accounting_period(uuid,bigint)'),
        ('public.reopen_accounting_period(uuid,bigint,text)'),
        ('public.preview_financial_event_posting_queue(integer)'),
        ('public.approve_financial_event_posting_queue(uuid,bigint)'),
        ('public.process_financial_event_posting_queue(uuid,bigint)'),
        ('public.get_finance_trial_balance(date,date,uuid,uuid)'),
        ('public.get_finance_general_ledger(uuid,date,date,uuid,uuid,integer,integer)'),
        ('public.get_finance_income_statement(date,date,uuid,uuid)'),
        ('public.get_finance_balance_sheet(date,uuid,uuid)'),
        ('public.get_finance_pending_analysis(date,date,integer,integer)'),
        ('public.get_finance_reconciliation_summary(date)')
), company_operator_readiness AS (
    SELECT
        company.id AS company_id,
        count(DISTINCT membership.user_id) FILTER (
            WHERE membership.status = 'ACTIVE'
              AND membership.role_code IN (
                  'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
              )
        ) AS finance_operator_count,
        count(DISTINCT membership.user_id) FILTER (
            WHERE membership.status = 'ACTIVE'
              AND membership.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
        ) AS reopen_approver_count
    FROM public.companies company
    LEFT JOIN public.company_memberships membership
      ON membership.company_id = company.id
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), current_period_readiness AS (
    SELECT
        company.id AS company_id,
        count(period.id) FILTER (
            WHERE period.status IN ('OPEN','REOPENED')
              AND (clock_timestamp() AT TIME ZONE company.timezone)::date
                    BETWEEN period.start_date AND period.end_date
        ) AS current_open_periods
    FROM public.companies company
    LEFT JOIN public.accounting_periods period
      ON period.company_id = company.id
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), fifo_value AS (
    SELECT
        batch.company_id,
        COALESCE(sum(batch.qty_remaining * batch.cogs_unit),0)::numeric(20,4)
            AS amount
    FROM public.product_batches batch
    WHERE batch.qty_remaining > 0
    GROUP BY batch.company_id
), inventory_gl_value AS (
    SELECT
        journal.company_id,
        COALESCE(sum(line.debit-line.credit),0)::numeric(20,4) AS amount
    FROM public.finance_journals journal
    JOIN public.finance_journal_lines line
      ON line.company_id = journal.company_id
     AND line.journal_id = journal.id
    JOIN public.chart_of_accounts account
      ON account.company_id = line.company_id
     AND account.id = line.account_id
    WHERE journal.status = 'POSTED'
      AND account.system_function_key = 'INVENTORY_ASSET'
    GROUP BY journal.company_id
), checks AS (
    SELECT
        'g6_phase7_dependencies'::text AS check_name,
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
        'canonical_finance_operation_schema',
        CASE WHEN count(*) FILTER (WHERE relation.oid IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.relation_name ORDER BY required.relation_name)
                    FILTER (WHERE relation.oid IS NULL),
                '[]'::jsonb
            )
        )
    FROM required_relations required
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = required.relation_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_finance_operation_routines',
        CASE WHEN count(*) FILTER (
            WHERE to_regprocedure(required.signature) IS NULL
        ) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.signature ORDER BY required.signature)
                    FILTER (
                        WHERE to_regprocedure(required.signature) IS NULL
                    ),
                '[]'::jsonb
            )
        )
    FROM required_routines required

    UNION ALL

    SELECT
        'canonical_finance_reversal_runtime',
        CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'expected_capability','guarded append-only journal reversal'
        )
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname = 'reverse_finance_journal'

    UNION ALL

    SELECT
        'active_finance_queue',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('run_count',count(*))
    FROM public.finance_posting_queue_runs run
    WHERE run.status IN ('PREVIEWED','APPROVED','PROCESSING')

    UNION ALL

    SELECT
        'failed_finance_queue_item',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'item_count',count(*),
            'queue_count',count(DISTINCT queue_run_id)
        )
    FROM public.finance_posting_queue_items item
    WHERE item.status = 'FAILED'

    UNION ALL

    SELECT
        'posted_journal_balance_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals journal
    WHERE journal.status = 'POSTED'
      AND (
          journal.total_debit <= 0
          OR journal.total_debit <> journal.total_credit
          OR NOT EXISTS (
              SELECT 1
              FROM public.finance_journal_lines line
              WHERE line.company_id = journal.company_id
                AND line.journal_id = journal.id
              GROUP BY line.company_id,line.journal_id
              HAVING sum(line.debit) = journal.total_debit
                 AND sum(line.credit) = journal.total_credit
                 AND sum(line.debit) = sum(line.credit)
          )
      )

    UNION ALL

    SELECT
        'posted_event_journal_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('event_count',count(*))
    FROM public.financial_events event
    WHERE event.status::text = 'POSTED'
      AND NOT EXISTS (
          SELECT 1 FROM public.finance_journals journal
          WHERE journal.company_id = event.company_id
            AND journal.financial_event_id = event.id
            AND journal.status = 'POSTED'
      )

    UNION ALL

    SELECT
        'automatic_journal_event_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals journal
    LEFT JOIN public.financial_events event
      ON event.company_id = journal.company_id
     AND event.id = journal.financial_event_id
    WHERE journal.status = 'POSTED'
      AND journal.journal_type = 'AUTOMATIC'
      AND (
          event.id IS NULL
          OR event.status::text <> 'POSTED'
      )

    UNION ALL

    SELECT
        'duplicate_financial_event_journal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,financial_event_id
        FROM public.finance_journals
        WHERE financial_event_id IS NOT NULL
        GROUP BY company_id,financial_event_id
        HAVING count(*) > 1
    ) duplicate_group

    UNION ALL

    SELECT
        'duplicate_journal_reversal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,reversal_of_journal_id
        FROM public.finance_journals
        WHERE reversal_of_journal_id IS NOT NULL
        GROUP BY company_id,reversal_of_journal_id
        HAVING count(*) > 1
    ) duplicate_group

    UNION ALL

    SELECT
        'invalid_existing_journal_reversal',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals reversal
    LEFT JOIN public.finance_journals original
      ON original.company_id = reversal.company_id
     AND original.id = reversal.reversal_of_journal_id
    WHERE reversal.journal_type = 'REVERSAL'
      AND (
          original.id IS NULL
          OR original.status <> 'POSTED'
          OR reversal.status <> 'POSTED'
          OR reversal.reversal_of_journal_id = reversal.id
          OR original.journal_type = 'REVERSAL'
      )

    UNION ALL

    SELECT
        'accounting_period_lifecycle_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('period_count',count(*))
    FROM public.accounting_periods period
    WHERE period.status NOT IN ('OPEN','LOCKED','REOPENED')
       OR period.start_date > period.end_date
       OR (
           period.status = 'LOCKED'
           AND (period.closed_by IS NULL OR period.closed_at IS NULL)
       )
       OR (
           period.status = 'REOPENED'
           AND (
               period.closed_by IS NULL OR period.closed_at IS NULL
               OR period.reopened_by IS NULL OR period.reopened_at IS NULL
               OR btrim(COALESCE(period.reopen_reason,'')) = ''
           )
       )

    UNION ALL

    SELECT
        'active_company_current_period_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('company_count',count(*))
    FROM current_period_readiness readiness
    WHERE readiness.current_open_periods <> 1

    UNION ALL

    SELECT
        'pilot_company_role_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'company_count',count(*),
            'requires','Finance operator plus Company Owner/Admin approver'
        )
    FROM company_operator_readiness readiness
    WHERE readiness.finance_operator_count = 0
       OR readiness.reopen_approver_count = 0

    UNION ALL

    SELECT
        'browser_direct_finance_write_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'writable_relations',COALESCE(
                jsonb_agg(relation_name ORDER BY relation_name),
                '[]'::jsonb
            )
        )
    FROM (
        SELECT required.relation_name
        FROM required_relations required
        WHERE has_table_privilege(
            'authenticated',
            format('public.%I',required.relation_name),
            'INSERT,UPDATE,DELETE'
        )
    ) writable

    UNION ALL

    SELECT
        'unsafe_legacy_finance_routine_execution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authenticated_executable_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(routine.proname ORDER BY routine.proname),
                '[]'::jsonb
            )
        )
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname IN (
          'post_financial_event','post_pending_financial_events',
          'process_financial_events_queue'
      )
      AND has_function_privilege('authenticated',routine.oid,'EXECUTE')

    UNION ALL

    SELECT
        'unsupported_hold_event_scope',
        'DEFERRED',
        jsonb_build_object(
            'event_count',count(*),
            'companies',count(DISTINCT event.company_id),
            'event_contracts',count(DISTINCT (
                event.event_type::text,event.source_table,event.system_event_key
            ))
        )
    FROM public.financial_events event
    WHERE event.status::text = 'HOLD'
      AND NOT (
          event.event_type::text = 'STOCK_OPENING'
          AND event.source_table = 'opening_stock_documents'
          AND event.system_event_key = 'STOCK_OPENING'
      )

    UNION ALL

    SELECT
        'stock_fifo_gl_reconciliation_scope',
        CASE WHEN count(*) FILTER (
            WHERE abs(COALESCE(fifo.amount,0)-COALESCE(ledger.amount,0)) > 0.01
        ) = 0 THEN 'PASS' ELSE 'DEFERRED' END,
        jsonb_build_object(
            'company_count',count(*) FILTER (
                WHERE abs(COALESCE(fifo.amount,0)-COALESCE(ledger.amount,0)) > 0.01
            ),
            'fifo_value',COALESCE(sum(COALESCE(fifo.amount,0)),0),
            'inventory_gl_value',COALESCE(sum(COALESCE(ledger.amount,0)),0),
            'absolute_difference',COALESCE(sum(
                abs(COALESCE(fifo.amount,0)-COALESCE(ledger.amount,0))
            ),0)
        )
    FROM public.companies company
    LEFT JOIN fifo_value fifo ON fifo.company_id = company.id
    LEFT JOIN inventory_gl_value ledger ON ledger.company_id = company.id
    WHERE company.status = 'ACTIVE'

    UNION ALL

    SELECT
        'finance_pilot_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(SELECT count(*) FROM public.companies
                WHERE status='ACTIVE'),
            'accounting_periods',(SELECT count(*) FROM public.accounting_periods),
            'open_periods',(SELECT count(*) FROM public.accounting_periods
                WHERE status IN ('OPEN','REOPENED')),
            'posted_journals',(SELECT count(*) FROM public.finance_journals
                WHERE status='POSTED'),
            'posted_lines',(SELECT count(*)
                FROM public.finance_journal_lines line
                JOIN public.finance_journals journal
                  ON journal.company_id=line.company_id
                 AND journal.id=line.journal_id
                WHERE journal.status='POSTED'),
            'reversal_journals',(SELECT count(*) FROM public.finance_journals
                WHERE journal_type='REVERSAL'),
            'hold_events',(SELECT count(*) FROM public.financial_events
                WHERE status::text='HOLD'),
            'posting_queue_runs',(SELECT count(*)
                FROM public.finance_posting_queue_runs),
            'reconciliation_documents',(SELECT count(*)
                FROM public.finance_reconciliation_documents)
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
        WHEN 'DEFERRED' THEN 6
        ELSE 7
    END,
    check_name;
