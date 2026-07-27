-- G1 phase 5D postflight. SELECT-only. Expected result: 31 PASS rows.

WITH expected_tables(table_name) AS (
    VALUES
        ('cash_advances'), ('bank_deposits'), ('financial_events'),
        ('journal_entries'), ('pos_reconciliations')
), policy_counts AS (
    SELECT tablename,count(*)::integer AS policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
    GROUP BY tablename
), table_checks AS (
    SELECT
        'table_policy:' || e.table_name AS check_name,
        CASE
            WHEN c.oid IS NOT NULL
             AND c.relrowsecurity
             AND COALESCE(pc.policy_count,0) = 1
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists',c.oid IS NOT NULL,
            'rls_enabled',COALESCE(c.relrowsecurity,FALSE),
            'expected_policies',1,
            'actual_policies',COALESCE(pc.policy_count,0)
        ) AS details
    FROM expected_tables e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = e.table_name
    LEFT JOIN policy_counts pc ON pc.tablename = e.table_name
), privilege_checks AS (
    SELECT
        'privilege:' || table_name AS check_name,
        CASE
            WHEN has_table_privilege('authenticated','public.' || table_name,'SELECT')
             AND NOT has_table_privilege('authenticated','public.' || table_name,'INSERT')
             AND NOT has_table_privilege('authenticated','public.' || table_name,'UPDATE')
             AND NOT has_table_privilege('authenticated','public.' || table_name,'DELETE')
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'select',has_table_privilege('authenticated','public.' || table_name,'SELECT'),
            'insert',has_table_privilege('authenticated','public.' || table_name,'INSERT'),
            'update',has_table_privilege('authenticated','public.' || table_name,'UPDATE'),
            'delete',has_table_privilege('authenticated','public.' || table_name,'DELETE')
        ) AS details
    FROM expected_tables
), expected_constraints(table_name,constraint_name,expected_type) AS (
    VALUES
        ('cashier_sessions','uq_cashier_sessions_company_store_id','u'),
        ('financial_events','uq_financial_events_company_id_id','u'),
        ('sales_headers','uq_sales_headers_company_store_id','u'),
        ('cash_advances','fk_cash_advances_company_store_session','f'),
        ('bank_deposits','fk_bank_deposits_company_store_session','f'),
        ('financial_events','fk_financial_events_company_store_root_sales','f'),
        ('financial_events','fk_financial_events_company_store','f'),
        ('journal_entries','fk_journal_entries_company_event','f'),
        ('journal_entries','fk_journal_entries_company_reversal_event','f'),
        ('journal_entries','fk_journal_entries_company_store','f'),
        ('pos_reconciliations','fk_pos_reconciliations_company_sales','f')
), constraint_checks AS (
    SELECT
        'constraint:' || e.constraint_name AS check_name,
        CASE
            WHEN c.oid IS NOT NULL
             AND c.contype::text = e.expected_type
             AND c.convalidated
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'table',e.table_name,
            'exists',c.oid IS NOT NULL,
            'type',c.contype,
            'validated',COALESCE(c.convalidated,FALSE)
        ) AS details
    FROM expected_constraints e
    LEFT JOIN pg_namespace n ON n.nspname = 'public'
    LEFT JOIN pg_class rel ON rel.relnamespace = n.oid AND rel.relname = e.table_name
    LEFT JOIN pg_constraint c ON c.conrelid = rel.oid AND c.conname = e.constraint_name
), expected_not_null(table_name,column_name) AS (
    VALUES
        ('cash_advances','company_id'),
        ('cash_advances','store_id'),
        ('bank_deposits','company_id'),
        ('bank_deposits','store_id'),
        ('financial_events','company_id'),
        ('journal_entries','company_id'),
        ('pos_reconciliations','company_id')
), not_null_checks AS (
    SELECT
        'not_null:' || e.table_name || '.' || e.column_name AS check_name,
        CASE WHEN c.is_nullable = 'NO' THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('is_nullable',c.is_nullable) AS details
    FROM expected_not_null e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name
), function_check AS (
    SELECT
        'function:private_finance_company_visible'::text AS check_name,
        CASE
            WHEN p.oid IS NOT NULL
             AND p.prosecdef
             AND p.provolatile = 's'
             AND COALESCE(p.proconfig,ARRAY[]::text[])::text[]
                 @> ARRAY['search_path=public, pg_temp']::text[]
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'exists',p.oid IS NOT NULL,
            'security_definer',COALESCE(p.prosecdef,FALSE),
            'volatility',p.provolatile,
            'config',COALESCE(to_jsonb(p.proconfig),'[]'::jsonb)
        ) AS details
    FROM (VALUES (to_regprocedure(
        'public.private_finance_company_visible(uuid)'
    ))) expected(oid)
    LEFT JOIN pg_proc p ON p.oid = expected.oid
), worker_check AS (
    SELECT
        'worker_service_role_only'::text AS check_name,
        CASE
            WHEN NOT has_function_privilege(
                'authenticated','public.process_financial_events_queue()','EXECUTE'
            )
             AND has_function_privilege(
                'service_role','public.process_financial_events_queue()','EXECUTE'
            )
            THEN 'PASS' ELSE 'FAIL'
        END AS status,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated','public.process_financial_events_queue()','EXECUTE'
            ),
            'service_role_execute',has_function_privilege(
                'service_role','public.process_financial_events_queue()','EXECUTE'
            )
        ) AS details
), ledger_check AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        jsonb_build_object('row_count',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260721120000'
)
SELECT check_name,status,details
FROM (
    SELECT * FROM table_checks
    UNION ALL SELECT * FROM privilege_checks
    UNION ALL SELECT * FROM constraint_checks
    UNION ALL SELECT * FROM not_null_checks
    UNION ALL SELECT * FROM function_check
    UNION ALL SELECT * FROM worker_check
    UNION ALL SELECT * FROM ledger_check
) checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
