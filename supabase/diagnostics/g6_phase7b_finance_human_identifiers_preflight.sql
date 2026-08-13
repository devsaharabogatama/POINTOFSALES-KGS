-- G6 corrective phase 7B preflight: human-readable Finance identifiers.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH required_versions(version) AS (
    VALUES ('20260811090000')
), checks AS (
    SELECT
        'g6_phase7b_dependency'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
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
      ON migration.version = required.version

    UNION ALL

    SELECT
        'canonical_finance_identifier_schema_state','SETUP',
        jsonb_build_object(
            'journal_display_no_exists',EXISTS(
                SELECT 1 FROM information_schema.columns
                WHERE table_schema='public' AND table_name='finance_journals'
                  AND column_name='display_no'
            ),
            'queue_display_no_exists',EXISTS(
                SELECT 1 FROM information_schema.columns
                WHERE table_schema='public'
                  AND table_name='finance_posting_queue_runs'
                  AND column_name='display_no'
            ),
            'exception_display_no_exists',EXISTS(
                SELECT 1 FROM information_schema.columns
                WHERE table_schema='public'
                  AND table_name='finance_posting_exceptions'
                  AND column_name='display_no'
            ),
            'reconciliation_no_exists',EXISTS(
                SELECT 1 FROM information_schema.columns
                WHERE table_schema='public'
                  AND table_name='finance_reconciliation_documents'
                  AND column_name='reconciliation_no'
            ),
            'counter_table_exists',
                to_regclass('private.finance_document_number_counters')
                    IS NOT NULL
        )

    UNION ALL

    SELECT
        'legacy_random_journal_number_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count',count(*))
    FROM public.finance_journals journal
    WHERE journal.journal_no ~* '^(G6-|REV-)[0-9a-f]{16,}$'

    UNION ALL

    SELECT
        'legacy_random_queue_number_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('row_count',count(*))
    FROM public.finance_posting_queue_runs run
    WHERE run.queue_no ~* '^FQ-[0-9]{8}-[0-9a-f]{8}$'

    UNION ALL

    SELECT
        'finance_identifier_source_inventory','INFO',
        jsonb_build_object(
            'journals',(SELECT count(*) FROM public.finance_journals),
            'reversal_journals',(
                SELECT count(*) FROM public.finance_journals
                WHERE journal_type='REVERSAL'
            ),
            'queue_runs',(
                SELECT count(*) FROM public.finance_posting_queue_runs
            ),
            'posting_exceptions',(
                SELECT count(*) FROM public.finance_posting_exceptions
            ),
            'reconciliation_documents',(
                SELECT count(*) FROM public.finance_reconciliation_documents
            )
        )

    UNION ALL

    SELECT
        'browser_direct_finance_identifier_write_boundary',
        CASE WHEN NOT has_table_privilege(
                'authenticated','public.finance_journals','INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_posting_queue_runs','INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_posting_exceptions','INSERT,UPDATE,DELETE'
            ) AND NOT has_table_privilege(
                'authenticated','public.finance_reconciliation_documents','INSERT,UPDATE,DELETE'
            ) THEN 'PASS' ELSE 'BLOCKER' END,
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
SELECT check_name,status,details
FROM checks
ORDER BY CASE status
    WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2 WHEN 'PASS' THEN 3 ELSE 4
END,check_name;
