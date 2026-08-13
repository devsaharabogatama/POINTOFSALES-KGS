-- G6 corrective phase 2 focused contract resolution.
-- Preconditions established by the phase-2 preflight:
-- accounting_periods and journal_lines exist with the listed legacy columns.
-- SAFETY: one SELECT statement, aggregate metadata/counts only, no mutation.

WITH period_status_inventory AS (
    SELECT status::TEXT AS status,count(*) AS row_count
    FROM public.accounting_periods
    GROUP BY status::TEXT
), period_overlap AS (
    SELECT left_period.id,right_period.id AS right_id
    FROM public.accounting_periods left_period
    JOIN public.accounting_periods right_period
     ON right_period.company_id = left_period.company_id
     AND right_period.id > left_period.id
     AND CASE
             WHEN left_period.start_date IS NOT NULL
              AND left_period.end_date >= left_period.start_date
             THEN daterange(
                 left_period.start_date,left_period.end_date,'[]'
             )
             ELSE 'empty'::daterange
         END
         && CASE
                WHEN right_period.start_date IS NOT NULL
                 AND right_period.end_date >= right_period.start_date
                THEN daterange(
                    right_period.start_date,right_period.end_date,'[]'
                )
                ELSE 'empty'::daterange
            END
), routine_references AS (
    SELECT
        routine.proname,
        routine.prosrc ILIKE '%accounting_periods%' AS references_periods,
        routine.prosrc ILIKE '%journal_lines%' AS references_journal_lines
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname IN ('public','private')
      AND routine.prokind = 'f'
      AND (
          routine.prosrc ILIKE '%accounting_periods%'
          OR routine.prosrc ILIKE '%journal_lines%'
      )
), checks AS (
    SELECT
        'accounting_period_row_shape'::TEXT AS check_name,
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM public.accounting_periods
    WHERE company_id IS NULL
       OR period_year < 2000 OR period_year > 9999
       OR period_month < 1 OR period_month > 12
       OR start_date IS NULL OR end_date IS NULL
       OR end_date < start_date
       OR CASE
              WHEN period_year BETWEEN 2000 AND 9999
               AND period_month BETWEEN 1 AND 12
              THEN start_date <> make_date(period_year,period_month,1)
                OR end_date <> (
                    make_date(period_year,period_month,1)
                    + INTERVAL '1 month' - INTERVAL '1 day'
                )::DATE
              ELSE FALSE
          END

    UNION ALL

    SELECT
        'accounting_period_overlap',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('overlap_pairs',count(*))
    FROM period_overlap

    UNION ALL

    SELECT
        'duplicate_company_period_month',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,period_year,period_month
        FROM public.accounting_periods
        GROUP BY company_id,period_year,period_month
        HAVING count(*) > 1
    ) duplicate_groups

    UNION ALL

    SELECT
        'accounting_period_status_contract',
        CASE WHEN count(*) FILTER (
            WHERE status NOT IN ('OPEN','LOCKED','REOPENED')
        ) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'status_rows',COALESCE(
                jsonb_object_agg(status,row_count ORDER BY status),
                '{}'::jsonb
            ),
            'noncanonical_status_rows',COALESCE(sum(row_count) FILTER (
                WHERE status NOT IN ('OPEN','LOCKED','REOPENED')
            ),0)
        )
    FROM period_status_inventory

    UNION ALL

    SELECT
        'accounting_period_lifecycle_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.accounting_periods
    WHERE (
            status::TEXT IN ('LOCKED','CLOSED')
            AND (closed_by IS NULL OR closed_at IS NULL)
          )
       OR (
            status::TEXT = 'REOPENED'
            AND (
                reopened_by IS NULL OR reopened_at IS NULL
                OR btrim(COALESCE(reopen_reason,'')) = ''
            )
          )

    UNION ALL

    SELECT
        'rejected_journal_lines_data',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object('row_count',count(*))
    FROM public.journal_lines

    UNION ALL

    SELECT
        'browser_period_journal_write_boundary',
        CASE WHEN
            NOT has_table_privilege(
                'authenticated','public.accounting_periods',
                'INSERT,UPDATE,DELETE'
            )
            AND NOT has_table_privilege(
                'authenticated','public.journal_lines',
                'INSERT,UPDATE,DELETE'
            )
        THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'accounting_periods_write',has_table_privilege(
                'authenticated','public.accounting_periods',
                'INSERT,UPDATE,DELETE'
            ),
            'journal_lines_write',has_table_privilege(
                'authenticated','public.journal_lines',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'accounting_period_inventory',
        'INFO',
        jsonb_build_object(
            'rows',(SELECT count(*) FROM public.accounting_periods),
            'companies',(
                SELECT count(DISTINCT company_id)
                FROM public.accounting_periods
            ),
            'status_rows',COALESCE(
                (SELECT jsonb_object_agg(
                     status,row_count ORDER BY status
                 ) FROM period_status_inventory),
                '{}'::jsonb
            )
        )

    UNION ALL

    SELECT
        'period_journal_column_contract',
        'INFO',
        COALESCE(
            jsonb_object_agg(
                table_name || '.' || column_name,
                jsonb_build_object(
                    'data_type',data_type,
                    'udt_name',udt_name,
                    'nullable',is_nullable,
                    'default',column_default
                ) ORDER BY table_name,ordinal_position
            ),
            '{}'::jsonb
        )
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('accounting_periods','journal_lines')

    UNION ALL

    SELECT
        'period_journal_constraint_contract',
        'INFO',
        jsonb_build_object(
            'constraints',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'table',relation.relname,
                        'name',constraint_state.conname,
                        'type',constraint_state.contype,
                        'validated',constraint_state.convalidated,
                        'definition',pg_get_constraintdef(
                            constraint_state.oid,TRUE
                        )
                    ) ORDER BY relation.relname,constraint_state.conname
                ),
                '[]'::jsonb
            )
        )
    FROM pg_constraint constraint_state
    JOIN pg_class relation ON relation.oid = constraint_state.conrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN ('accounting_periods','journal_lines')

    UNION ALL

    SELECT
        'period_journal_index_contract',
        'INFO',
        jsonb_build_object(
            'indexes',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'table',tablename,
                        'name',indexname,
                        'definition',indexdef
                    ) ORDER BY tablename,indexname
                ),
                '[]'::jsonb
            )
        )
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename IN ('accounting_periods','journal_lines')

    UNION ALL

    SELECT
        'period_journal_policy_contract',
        'INFO',
        jsonb_build_object(
            'policies',COALESCE(
                jsonb_agg(
                    jsonb_build_object(
                        'table',tablename,
                        'name',policyname,
                        'command',cmd,
                        'roles',roles,
                        'using',qual,
                        'with_check',with_check
                    ) ORDER BY tablename,policyname
                ),
                '[]'::jsonb
            )
        )
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN ('accounting_periods','journal_lines')

    UNION ALL

    SELECT
        'period_journal_routine_reference_inventory',
        'INFO',
        jsonb_build_object(
            'accounting_period_routines',COALESCE(
                jsonb_agg(DISTINCT proname ORDER BY proname)
                    FILTER (WHERE references_periods),
                '[]'::jsonb
            ),
            'journal_line_routines',COALESCE(
                jsonb_agg(DISTINCT proname ORDER BY proname)
                    FILTER (WHERE references_journal_lines),
                '[]'::jsonb
            )
        )
    FROM routine_references
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'PASS' THEN 3
        ELSE 4
    END,
    check_name;
