-- G6 phase 6C postflight: statements, pending analysis, reconciliation.
-- SAFETY: one aggregate SELECT only; no routine execution or mutation.

WITH expected_tables(name) AS (VALUES
    ('finance_reconciliation_documents'),
    ('finance_reconciliation_allocations'),
    ('finance_reconciliation_audit')
), expected_routines(name) AS (VALUES
    ('get_finance_income_statement'),('get_finance_balance_sheet'),
    ('get_finance_pending_analysis'),('get_finance_reconciliation_summary')
), expected_reports(code) AS (VALUES
    ('TRIAL_BALANCE'),('GENERAL_LEDGER'),('INCOME_STATEMENT'),
    ('BALANCE_SHEET'),('PENDING_ANALYSIS'),('RECONCILIATION_SUMMARY')
), checks AS (
    SELECT 'migration_ledger'::TEXT check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
        abs(count(*)-1) violation_rows,
        jsonb_build_object('ledger_rows',count(*)) details
    FROM private.kgs_schema_migrations WHERE version='20260810230000'

    UNION ALL
    SELECT 'required_reconciliation_tables',
        CASE WHEN count(relation.oid)=count(*) THEN 'PASS' ELSE 'FAIL' END,
        count(*)-count(relation.oid),jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(expected.name ORDER BY expected.name)
                FILTER(WHERE relation.oid IS NULL),'[]'::JSONB)
        )
    FROM expected_tables expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname='public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace=namespace.oid AND relation.relname=expected.name
     AND relation.relkind IN('r','p')

    UNION ALL
    SELECT 'required_statement_routines',
        CASE WHEN count(routine.oid)=count(*) THEN 'PASS' ELSE 'FAIL' END,
        count(*)-count(routine.oid),jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(expected.name ORDER BY expected.name)
                FILTER(WHERE routine.oid IS NULL),'[]'::JSONB)
        )
    FROM expected_routines expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname='public'
    LEFT JOIN pg_proc routine
      ON routine.pronamespace=namespace.oid AND routine.proname=expected.name

    UNION ALL
    SELECT 'active_company_report_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT company.id
        FROM public.companies company
        CROSS JOIN expected_reports expected
        LEFT JOIN public.finance_report_definitions definition
          ON definition.company_id=company.id
         AND definition.report_code=expected.code AND definition.is_active
        LEFT JOIN public.finance_report_versions version
          ON version.company_id=definition.company_id
         AND version.report_definition_id=definition.id
         AND version.status='ACTIVE' AND version.effective_to IS NULL
        WHERE company.status='ACTIVE'
        GROUP BY company.id
        HAVING count(definition.id)<>6 OR count(version.id)<>6
    ) invalid

    UNION ALL
    SELECT 'required_statement_line_metadata',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('invalid_company_count',count(*),'expected_per_company',14)
    FROM (
        SELECT company.id
        FROM public.companies company
        LEFT JOIN public.finance_report_lines line ON line.company_id=company.id
        LEFT JOIN public.finance_report_versions version
          ON version.company_id=line.company_id AND version.id=line.report_version_id
         AND version.status='ACTIVE' AND version.effective_to IS NULL
        LEFT JOIN public.finance_report_definitions definition
          ON definition.company_id=version.company_id
         AND definition.id=version.report_definition_id
         AND definition.report_code IN(
            'INCOME_STATEMENT','BALANCE_SHEET',
            'PENDING_ANALYSIS','RECONCILIATION_SUMMARY'
         )
        WHERE company.status='ACTIVE'
        GROUP BY company.id
        HAVING count(line.id) FILTER(WHERE definition.id IS NOT NULL)<>14
    ) invalid

    UNION ALL
    SELECT 'reconciliation_rls',
        CASE WHEN count(*)=3 AND count(*) FILTER(WHERE relation.relrowsecurity)=3
             THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) FILTER(WHERE relation.relrowsecurity)-3),
        jsonb_build_object('table_rows',count(*),
            'rls_rows',count(*) FILTER(WHERE relation.relrowsecurity))
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname IN(SELECT name FROM expected_tables)

    UNION ALL
    SELECT 'browser_reconciliation_write_boundary',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('writable_relations',COALESCE(
            jsonb_agg(relation.relname ORDER BY relation.relname),'[]'::JSONB))
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname IN(SELECT name FROM expected_tables)
      AND has_table_privilege('authenticated',relation.oid,'INSERT,UPDATE,DELETE')

    UNION ALL
    SELECT 'statement_rpc_boundary',
        CASE WHEN count(*)=4 AND count(*) FILTER(
            WHERE NOT has_function_privilege('authenticated',routine.oid,'EXECUTE')
               OR has_function_privilege('anon',routine.oid,'EXECUTE')
        )=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(
            WHERE NOT has_function_privilege('authenticated',routine.oid,'EXECUTE')
               OR has_function_privilege('anon',routine.oid,'EXECUTE')
        ),jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='public'
      AND routine.proname IN(SELECT name FROM expected_routines)

    UNION ALL
    SELECT 'posted_only_statement_contract',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-2),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='public'
      AND routine.proname IN(
          'get_finance_income_statement','get_finance_balance_sheet'
      )
      AND pg_get_functiondef(routine.oid) ILIKE '%status=''POSTED''%'
      AND pg_get_functiondef(routine.oid) ILIKE '%FINANCE_REPORT_ROLE_REQUIRED%'

    UNION ALL
    SELECT 'pending_analysis_separation_contract',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='public'
      AND routine.proname='get_finance_pending_analysis'
      AND pg_get_functiondef(routine.oid) ILIKE '%status::text<>''POSTED''%'
      AND pg_get_functiondef(routine.oid) ILIKE '%BELUM MASUK LAPORAN KEUANGAN%'
      AND pg_get_functiondef(routine.oid) ILIKE '%financialStatementIncluded%'

    UNION ALL
    SELECT 'reconciliation_no_auto_adjustment_contract',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-1),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='public'
      AND routine.proname='get_finance_reconciliation_summary'
      AND pg_get_functiondef(routine.oid) ILIKE '%CURRENT_ONLY%'
      AND pg_get_functiondef(routine.oid) ILIKE '%autoAdjustment%'
      AND pg_get_functiondef(routine.oid) ILIKE '%HISTORICAL_SUBLEDGER_SNAPSHOT_UNAVAILABLE%'

    UNION ALL
    SELECT 'reconciliation_history_triggers',
        CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-5),
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_state
    WHERE trigger_state.tgname IN(
        'g6_guard_reconciliation_document',
        'g6_guard_reconciliation_allocation',
        'g6_audit_reconciliation_document',
        'g6_audit_reconciliation_allocation',
        'g6_guard_reconciliation_audit'
    ) AND NOT trigger_state.tgisinternal AND trigger_state.tgenabled<>'D'

    UNION ALL
    SELECT 'reconciliation_report_version_reference',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,abs(count(*)-2),
        jsonb_build_object('constraint_rows',count(*),'expected',2)
    FROM pg_constraint constraint_state
    WHERE constraint_state.conname IN(
        'finance_report_versions_company_definition_id_unique',
        'fk_finance_reconciliation_version'
    )
      AND constraint_state.contype IN('u','f')

    UNION ALL
    SELECT 'migration_zero_finance_effect',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('reconciliation_rows',count(*))
    FROM public.finance_reconciliation_documents

    UNION ALL
    SELECT 'phase6c_runtime_inventory','INFO',0,jsonb_build_object(
        'report_definitions',(SELECT count(*) FROM public.finance_report_definitions),
        'active_versions',(SELECT count(*) FROM public.finance_report_versions
            WHERE status='ACTIVE' AND effective_to IS NULL),
        'posted_journals',(SELECT count(*) FROM public.finance_journals
            WHERE status='POSTED'),
        'hold_events',(SELECT count(*) FROM public.financial_events
            WHERE status::TEXT='HOLD'),
        'reconciliation_documents',(SELECT count(*)
            FROM public.finance_reconciliation_documents)
    )
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
