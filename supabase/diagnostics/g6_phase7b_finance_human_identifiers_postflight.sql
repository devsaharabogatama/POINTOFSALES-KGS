-- G6 corrective phase 7B postflight: Finance display identifier closure.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*)-1) AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260811100000'

    UNION ALL

    SELECT 'required_display_columns',
        CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-3),jsonb_build_object('column_rows',count(*),'expected',3)
    FROM information_schema.columns
    WHERE table_schema='public' AND column_name='display_no'
      AND table_name IN(
          'finance_journals','finance_posting_queue_runs',
          'finance_posting_exceptions'
      ) AND is_nullable='NO'

    UNION ALL

    SELECT 'invalid_finance_display_number',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM (
        SELECT id FROM public.finance_journals
        WHERE display_no !~ '^(JUR|JRB)/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
        UNION ALL
        SELECT id FROM public.finance_posting_queue_runs
        WHERE display_no !~ '^PST/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
        UNION ALL
        SELECT id FROM public.finance_posting_exceptions
        WHERE display_no !~ '^EXC/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
        UNION ALL
        SELECT id FROM public.finance_reconciliation_documents
        WHERE reconciliation_no !~ '^REC/[0-9]{4}/[0-9]{2}/[0-9]{6}$'
    ) invalid

    UNION ALL

    SELECT 'duplicate_company_finance_display_number',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,display_no FROM public.finance_journals
        GROUP BY company_id,display_no HAVING count(*)>1
        UNION ALL
        SELECT company_id,display_no FROM public.finance_posting_queue_runs
        GROUP BY company_id,display_no HAVING count(*)>1
        UNION ALL
        SELECT company_id,display_no FROM public.finance_posting_exceptions
        GROUP BY company_id,display_no HAVING count(*)>1
        UNION ALL
        SELECT company_id,reconciliation_no
        FROM public.finance_reconciliation_documents
        GROUP BY company_id,reconciliation_no HAVING count(*)>1
    ) duplicate_group

    UNION ALL

    SELECT 'required_display_number_triggers',
        CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*)-4),jsonb_build_object('trigger_rows',count(*),'expected',4)
    FROM pg_trigger trigger_state
    WHERE trigger_state.tgname IN(
        'a_g6_assign_finance_journal_display_no',
        'a_g6_assign_finance_queue_display_no',
        'a_g6_assign_finance_exception_display_no',
        'a_g6_assign_finance_reconciliation_no'
    ) AND trigger_state.tgenabled <> 'D'

    UNION ALL

    SELECT 'counter_not_behind_display_number',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('counter_groups',count(*))
    FROM (
        SELECT
            source.company_id,source.prefix,source.period_year,
            source.period_month,max(source.sequence_no) AS required_value
        FROM (
            SELECT company_id,split_part(display_no,'/',1) prefix,
                split_part(display_no,'/',2)::INTEGER period_year,
                split_part(display_no,'/',3)::INTEGER period_month,
                split_part(display_no,'/',4)::BIGINT sequence_no
            FROM public.finance_journals
            UNION ALL
            SELECT company_id,split_part(display_no,'/',1),
                split_part(display_no,'/',2)::INTEGER,
                split_part(display_no,'/',3)::INTEGER,
                split_part(display_no,'/',4)::BIGINT
            FROM public.finance_posting_queue_runs
            UNION ALL
            SELECT company_id,split_part(display_no,'/',1),
                split_part(display_no,'/',2)::INTEGER,
                split_part(display_no,'/',3)::INTEGER,
                split_part(display_no,'/',4)::BIGINT
            FROM public.finance_posting_exceptions
            UNION ALL
            SELECT company_id,split_part(reconciliation_no,'/',1),
                split_part(reconciliation_no,'/',2)::INTEGER,
                split_part(reconciliation_no,'/',3)::INTEGER,
                split_part(reconciliation_no,'/',4)::BIGINT
            FROM public.finance_reconciliation_documents
        ) source
        GROUP BY source.company_id,source.prefix,source.period_year,
            source.period_month
    ) required
    LEFT JOIN private.finance_document_number_counters counter
      ON counter.company_id=required.company_id
     AND counter.document_prefix=required.prefix
     AND counter.period_year=required.period_year
     AND counter.period_month=required.period_month
    WHERE counter.last_value IS NULL
       OR counter.last_value<required.required_value

    UNION ALL

    SELECT 'browser_finance_identifier_write_boundary',
        CASE WHEN NOT has_table_privilege(
                'authenticated','public.finance_journals',
                'INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_posting_queue_runs',
                'INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_posting_exceptions',
                'INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_reconciliation_documents',
                'INSERT,UPDATE,DELETE'
            ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege(
                'authenticated','public.finance_journals',
                'INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_posting_queue_runs',
                'INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_posting_exceptions',
                'INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_reconciliation_documents',
                'INSERT,UPDATE,DELETE'
            ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'journal_write',has_table_privilege(
                'authenticated','public.finance_journals',
                'INSERT,UPDATE,DELETE'
            ),
            'queue_write',has_table_privilege(
                'authenticated','public.finance_posting_queue_runs',
                'INSERT,UPDATE,DELETE'
            ),
            'exception_write',has_table_privilege(
                'authenticated','public.finance_posting_exceptions',
                'INSERT,UPDATE,DELETE'
            ),
            'reconciliation_write',has_table_privilege(
                'authenticated','public.finance_reconciliation_documents',
                'INSERT,UPDATE,DELETE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
