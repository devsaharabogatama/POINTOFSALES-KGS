-- G6 corrective phase 6C preflight: statements, pending analysis, reconciliation.
--
-- SAFETY:
-- - one aggregate SELECT only;
-- - no report RPC or queue routine execution;
-- - no DDL, DML, lock, TEMP object, event, journal, or reconciliation mutation;
-- - no business names, document numbers, account names, or payload values.

WITH required_versions(version) AS (
    VALUES ('20260810210000'),('20260810220000')
), expected_routines(routine_name) AS (
    VALUES
        ('get_finance_income_statement'),
        ('get_finance_balance_sheet'),
        ('get_finance_pending_analysis'),
        ('get_finance_reconciliation_summary')
), expected_reconciliation_relations(relation_name) AS (
    VALUES
        ('finance_reconciliation_documents'),
        ('finance_reconciliation_allocations')
), expected_report_codes(report_code) AS (
    VALUES
        ('INCOME_STATEMENT'),('BALANCE_SHEET'),
        ('PENDING_ANALYSIS'),('RECONCILIATION_SUMMARY')
), posted_balance AS (
    SELECT
        journal.company_id,
        COALESCE(sum(line.debit),0)::NUMERIC(24,4) debit_total,
        COALESCE(sum(line.credit),0)::NUMERIC(24,4) credit_total
    FROM public.finance_journals journal
    JOIN public.finance_journal_lines line
      ON line.company_id=journal.company_id AND line.journal_id=journal.id
    WHERE journal.status='POSTED'
    GROUP BY journal.company_id
), statement_balance AS (
    SELECT
        company.id company_id,
        COALESCE(sum(CASE WHEN account.account_type='ASSET'
            THEN line.debit-line.credit ELSE 0 END),0)::NUMERIC(24,4) assets,
        COALESCE(sum(CASE WHEN account.account_type='LIABILITY'
            THEN line.credit-line.debit ELSE 0 END),0)::NUMERIC(24,4) liabilities,
        COALESCE(sum(CASE WHEN account.account_type='EQUITY'
            THEN line.credit-line.debit ELSE 0 END),0)::NUMERIC(24,4) equity,
        COALESCE(sum(CASE WHEN account.account_type IN('REVENUE','OTHER_INCOME')
            THEN line.credit-line.debit ELSE 0 END),0)::NUMERIC(24,4) income,
        COALESCE(sum(CASE WHEN account.account_type IN('COGS','EXPENSE','OTHER_EXPENSE')
            THEN line.debit-line.credit ELSE 0 END),0)::NUMERIC(24,4) expense
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id=company.id AND journal.status='POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id=journal.company_id AND line.journal_id=journal.id
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id=line.company_id AND account.id=line.account_id
    WHERE company.status='ACTIVE'
    GROUP BY company.id
), fifo_value AS (
    SELECT company.id company_id,
        COALESCE(sum(batch.qty_remaining*batch.cogs_unit),0)::NUMERIC(24,4) amount
    FROM public.companies company
    LEFT JOIN public.product_batches batch
      ON batch.company_id=company.id AND batch.qty_remaining>0
    WHERE company.status='ACTIVE'
    GROUP BY company.id
), inventory_gl AS (
    SELECT company.id company_id,
        COALESCE(sum(line.debit-line.credit),0)::NUMERIC(24,4) amount
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id=company.id AND journal.status='POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id=journal.company_id AND line.journal_id=journal.id
     AND line.account_function_key_snapshot='INVENTORY_ASSET'
    WHERE company.status='ACTIVE'
    GROUP BY company.id
), checks AS (
    SELECT 'g6_phase6c_dependencies'::TEXT check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
                FILTER (WHERE migration.version IS NULL),'[]'::JSONB)
        ) details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL
    SELECT 'posted_journal_fixture_readiness',
        CASE WHEN count(*)>0 AND COALESCE(sum(line_count),0)>=2
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'posted_journals',count(*),
            'posted_lines',COALESCE(sum(line_count),0),
            'companies',count(DISTINCT company_id)
        )
    FROM (
        SELECT journal.id,journal.company_id,count(line.id) line_count
        FROM public.finance_journals journal
        LEFT JOIN public.finance_journal_lines line
          ON line.company_id=journal.company_id AND line.journal_id=journal.id
        WHERE journal.status='POSTED'
        GROUP BY journal.id,journal.company_id
    ) fixture

    UNION ALL
    SELECT 'posted_company_trial_balance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM posted_balance WHERE debit_total<>credit_total OR debit_total<=0

    UNION ALL
    SELECT 'active_company_timezone_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    LEFT JOIN pg_timezone_names timezone_state ON timezone_state.name=company.timezone
    WHERE company.status='ACTIVE'
      AND (btrim(COALESCE(company.timezone,''))='' OR timezone_state.name IS NULL)

    UNION ALL
    SELECT 'statement_report_definition_state',
        CASE WHEN count(definition.id)=count(*) THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(expected.report_code ORDER BY expected.report_code)
                FILTER (WHERE definition.id IS NULL),'[]'::JSONB)
        )
    FROM expected_report_codes expected
    LEFT JOIN public.companies company ON company.status='ACTIVE'
    LEFT JOIN public.finance_report_definitions definition
      ON definition.company_id=company.id
     AND definition.report_code=expected.report_code
     AND definition.is_active

    UNION ALL
    SELECT 'statement_report_routine_state',
        CASE WHEN count(routine.oid)=count(*) THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                FILTER (WHERE routine.oid IS NULL),'[]'::JSONB)
        )
    FROM expected_routines expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname='public'
    LEFT JOIN pg_proc routine
      ON routine.pronamespace=namespace.oid AND routine.proname=expected.routine_name

    UNION ALL
    SELECT 'canonical_reconciliation_relation_state',
        CASE WHEN count(relation.oid)=count(*) THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                FILTER (WHERE relation.oid IS NULL),'[]'::JSONB)
        )
    FROM expected_reconciliation_relations expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname='public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace=namespace.oid
     AND relation.relname=expected.relation_name
     AND relation.relkind IN('r','p')

    UNION ALL
    SELECT 'balance_sheet_equation_baseline',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM statement_balance
    WHERE round(assets-(liabilities+equity+(income-expense)),4)<>0

    UNION ALL
    SELECT 'nonzero_profit_loss_fixture_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object('company_count',count(*))
    FROM statement_balance WHERE income=0 AND expense=0

    UNION ALL
    SELECT 'active_finance_queue',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('run_count',count(*))
    FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')

    UNION ALL
    SELECT 'unsupported_hold_event_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'DEFERRED' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies',count(DISTINCT company_id),
            'event_contracts',count(DISTINCT (
                system_event_key,event_type::TEXT,source_table
            ))
        )
    FROM public.financial_events WHERE status::TEXT='HOLD'

    UNION ALL
    SELECT 'posting_exception_baseline',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('open_rows',count(*))
    FROM public.finance_posting_exceptions WHERE status<>'RESOLVED'

    UNION ALL
    SELECT 'unsafe_legacy_report_execution',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'executable_rows',count(*),
            'routine_names',COALESCE(jsonb_agg(DISTINCT routine.proname
                ORDER BY routine.proname),'[]'::JSONB)
        )
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='public'
      AND routine.proname IN(
          'get_income_statement_report','get_balance_sheet_report',
          'get_trial_balance_report','get_general_ledger_report'
      )
      AND has_function_privilege('authenticated',routine.oid,'EXECUTE')

    UNION ALL
    SELECT 'browser_direct_statement_write_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'writable_relations',COALESCE(jsonb_agg(relation.relname
                ORDER BY relation.relname),'[]'::JSONB)
        )
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname IN(
          'finance_report_definitions','finance_report_versions',
          'finance_report_lines','finance_report_exports',
          'finance_reconciliation_documents','finance_reconciliation_allocations',
          'finance_journals','finance_journal_lines','financial_events'
      )
      AND has_table_privilege('authenticated',relation.oid,'INSERT,UPDATE,DELETE')

    UNION ALL
    SELECT 'stock_fifo_gl_reconciliation_scope',
        CASE WHEN count(*) FILTER (WHERE fifo.amount<>ledger.amount)=0
             THEN 'PASS' ELSE 'DEFERRED' END,
        jsonb_build_object(
            'company_count',count(*) FILTER (WHERE fifo.amount<>ledger.amount),
            'fifo_value',COALESCE(sum(fifo.amount),0),
            'inventory_gl_value',COALESCE(sum(ledger.amount),0),
            'absolute_difference',COALESCE(sum(abs(fifo.amount-ledger.amount)),0)
        )
    FROM fifo_value fifo JOIN inventory_gl ledger USING(company_id)

    UNION ALL
    SELECT 'statement_runtime_inventory','INFO',jsonb_build_object(
        'active_companies',(SELECT count(*) FROM public.companies WHERE status='ACTIVE'),
        'posted_journals',(SELECT count(*) FROM public.finance_journals WHERE status='POSTED'),
        'posted_lines',(SELECT count(*) FROM public.finance_journal_lines line
            JOIN public.finance_journals journal
              ON journal.company_id=line.company_id AND journal.id=line.journal_id
            WHERE journal.status='POSTED'),
        'hold_events',(SELECT count(*) FROM public.financial_events WHERE status::TEXT='HOLD'),
        'report_definitions',(SELECT count(*) FROM public.finance_report_definitions),
        'report_versions',(SELECT count(*) FROM public.finance_report_versions)
    )
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'REVIEW' THEN 2
    WHEN 'SETUP' THEN 3 WHEN 'DEFERRED' THEN 4 WHEN 'PASS' THEN 5 ELSE 6 END,
    check_name;
