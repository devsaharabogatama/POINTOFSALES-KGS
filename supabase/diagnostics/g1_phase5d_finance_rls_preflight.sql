-- G1 phase 5D preflight: Finance tenant, balance, and privilege boundary.
-- SELECT-only. Every row must PASS with violation_rows = 0.

WITH checks AS (
    SELECT
        'finance_tables_without_rls'::text AS check_name,
        count(*)::bigint AS violation_rows
    FROM (VALUES
        ('cash_advances'), ('bank_deposits'), ('financial_events'),
        ('journal_entries'), ('pos_reconciliations')
    ) e(table_name)
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c
      ON c.relnamespace = n.oid
     AND c.relname = e.table_name
     AND c.relkind IN ('r','p')
    WHERE c.oid IS NULL OR NOT c.relrowsecurity

    UNION ALL

    SELECT 'finance_scope_nulls', count(*)
    FROM (
        SELECT id FROM public.cash_advances
        WHERE company_id IS NULL OR store_id IS NULL
        UNION ALL
        SELECT id FROM public.bank_deposits
        WHERE company_id IS NULL OR store_id IS NULL
        UNION ALL
        SELECT id FROM public.financial_events WHERE company_id IS NULL
        UNION ALL
        SELECT id FROM public.journal_entries WHERE company_id IS NULL
        UNION ALL
        SELECT id FROM public.pos_reconciliations WHERE company_id IS NULL
    ) missing_scope

    UNION ALL

    SELECT 'finance_tenant_mismatch', count(*)
    FROM (
        SELECT c.id
        FROM public.cash_advances c
        JOIN public.cashier_sessions s ON s.id = c.session_id
        WHERE c.company_id IS DISTINCT FROM s.company_id
           OR c.store_id IS DISTINCT FROM s.store_id

        UNION ALL

        SELECT d.id
        FROM public.bank_deposits d
        JOIN public.cashier_sessions s ON s.id = d.session_id
        WHERE d.company_id IS DISTINCT FROM s.company_id
           OR d.store_id IS DISTINCT FROM s.store_id

        UNION ALL

        SELECT e.id
        FROM public.financial_events e
        JOIN public.sales_headers s ON s.id = e.root_sales_id
        WHERE e.company_id IS DISTINCT FROM s.company_id
           OR e.store_id IS DISTINCT FROM s.store_id

        UNION ALL

        SELECT e.id
        FROM public.financial_events e
        JOIN public.stores s ON s.id = e.store_id
        WHERE e.company_id IS DISTINCT FROM s.company_id

        UNION ALL

        SELECT j.id
        FROM public.journal_entries j
        JOIN public.financial_events e ON e.id = j.financial_event_id
        WHERE j.company_id IS DISTINCT FROM e.company_id

        UNION ALL

        SELECT j.id
        FROM public.journal_entries j
        JOIN public.financial_events e ON e.id = j.reversal_of_event_id
        WHERE j.company_id IS DISTINCT FROM e.company_id

        UNION ALL

        SELECT j.id
        FROM public.journal_entries j
        JOIN public.stores s ON s.id = j.store_id
        WHERE j.company_id IS DISTINCT FROM s.company_id

        UNION ALL

        SELECT r.id
        FROM public.pos_reconciliations r
        JOIN public.sales_headers s ON s.id = r.sales_id
        WHERE r.company_id IS DISTINCT FROM s.company_id
    ) mismatches

    UNION ALL

    SELECT 'unbalanced_journal_groups', count(*)
    FROM (
        SELECT company_id,entry_group_id
        FROM public.journal_entries
        GROUP BY company_id,entry_group_id
        HAVING COALESCE(sum(debit),0) <> COALESCE(sum(kredit),0)
    ) unbalanced

    UNION ALL

    SELECT
        'authenticated_worker_execute',
        CASE WHEN has_function_privilege(
            'authenticated','public.process_financial_events_queue()','EXECUTE'
        ) THEN 1 ELSE 0 END
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
