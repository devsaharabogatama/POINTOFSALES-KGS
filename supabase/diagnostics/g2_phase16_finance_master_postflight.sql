-- G2 phase 16 postflight: Transaction Category and minimum COA foundation.
-- Expected: every row PASS with violation_rows = 0.

WITH expected_tables(table_name) AS (
    VALUES
        ('account_functions'),('system_events'),('chart_of_accounts'),
        ('transaction_categories'),('transaction_account_rules'),
        ('company_account_function_fallbacks'),
        ('finance_posting_exceptions'),('finance_master_audit')
), tenant_tables(table_name) AS (
    VALUES
        ('chart_of_accounts'),('transaction_categories'),
        ('transaction_account_rules'),
        ('company_account_function_fallbacks'),
        ('finance_posting_exceptions'),('finance_master_audit')
), expected_columns(table_name,column_name) AS (
    VALUES
        ('financial_events','system_event_key'),
        ('financial_events','transaction_category_id'),
        ('financial_events','transaction_rule_version'),
        ('journal_entries','account_id'),
        ('journal_entries','account_code_snapshot'),
        ('journal_entries','account_name_snapshot'),
        ('journal_entries','system_event_key'),
        ('journal_entries','transaction_category_id'),
        ('journal_entries','transaction_rule_version')
), expected_triggers(trigger_name) AS (
    VALUES
        ('g2_provision_minimum_coa'),
        ('g2_touch_chart_of_accounts'),
        ('g2_touch_transaction_categories'),
        ('g2_guard_transaction_account_rules'),
        ('g2_guard_company_account_fallbacks'),
        ('g2_guard_transaction_category_history'),
        ('g2_guard_chart_of_account_history')
), expected_routines(routine_signature) AS (
    VALUES
        ('private.provision_g2_minimum_coa(uuid)'),
        ('private.trg_g2_provision_minimum_coa()'),
        ('private.trg_g2_guard_finance_mapping()'),
        ('private.trg_g2_guard_finance_master_history()'),
        ('public.save_transaction_category(uuid,bigint,text,text,text,text,boolean)'),
        ('public.save_transaction_account_rule(uuid,uuid,text,uuid,timestamp with time zone,timestamp with time zone,text)')
), event_function_keys AS (
    SELECT unnest(
        se.required_account_functions
        || se.conditional_account_functions
        || se.optional_account_functions
    ) AS function_key
    FROM public.system_events se
), checks AS (
    SELECT
        'migration_ledger'::text AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*) - 1)::bigint AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722150000'

    UNION ALL

    SELECT
        'canonical_tables',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE to_regclass('public.' || table_name) IS NULL
        ),
        jsonb_build_object('expected',count(*))
    FROM expected_tables

    UNION ALL

    SELECT
        'tenant_company_id_contract',
        CASE WHEN count(*) FILTER (
            WHERE c.column_name IS NULL OR c.is_nullable <> 'NO'
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE c.column_name IS NULL OR c.is_nullable <> 'NO'
        ),
        jsonb_build_object('expected',count(*))
    FROM tenant_tables t
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = t.table_name
     AND c.column_name = 'company_id'

    UNION ALL

    SELECT
        'event_journal_snapshot_columns',
        CASE WHEN count(*) FILTER (WHERE c.column_name IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE c.column_name IS NULL),
        jsonb_build_object('expected',count(*))
    FROM expected_columns e
    LEFT JOIN information_schema.columns c
      ON c.table_schema = 'public'
     AND c.table_name = e.table_name
     AND c.column_name = e.column_name

    UNION ALL

    SELECT
        'system_registry_seed',
        CASE WHEN (SELECT count(*) FROM public.account_functions) >= 37
               AND (SELECT count(*) FROM public.system_events) = 26
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN (SELECT count(*) FROM public.account_functions) >= 37
                   AND (SELECT count(*) FROM public.system_events) = 26
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'account_functions',(SELECT count(*) FROM public.account_functions),
            'system_events',(SELECT count(*) FROM public.system_events)
        )

    UNION ALL

    SELECT
        'system_event_unknown_account_function',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM event_function_keys ef
    LEFT JOIN public.account_functions af
      ON af.function_key = ef.function_key
    WHERE af.function_key IS NULL

    UNION ALL

    SELECT
        'active_company_minimum_coa',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND (
          SELECT count(*) FROM public.chart_of_accounts coa
          WHERE coa.company_id = c.id AND coa.is_system_account
      ) < 36

    UNION ALL

    SELECT
        'coa_function_compatibility',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.chart_of_accounts coa
    JOIN public.account_functions af
      ON af.function_key = coa.system_function_key
    WHERE NOT (coa.account_type = ANY(af.compatible_account_types))

    UNION ALL

    SELECT
        'rls_and_policy',
        CASE WHEN count(*) FILTER (
            WHERE NOT c.relrowsecurity OR COALESCE(p.policy_count,0) = 0
        ) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (
            WHERE NOT c.relrowsecurity OR COALESCE(p.policy_count,0) = 0
        ),
        jsonb_build_object('expected',count(*))
    FROM expected_tables e
    JOIN pg_class c ON c.oid = to_regclass('public.' || e.table_name)
    LEFT JOIN (
        SELECT tablename,count(*) AS policy_count
        FROM pg_policies WHERE schemaname = 'public'
        GROUP BY tablename
    ) p ON p.tablename = e.table_name

    UNION ALL

    SELECT
        'required_triggers',
        CASE WHEN count(*) FILTER (WHERE t.oid IS NULL) = 0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER (WHERE t.oid IS NULL),
        jsonb_build_object('expected',count(*))
    FROM expected_triggers e
    LEFT JOIN pg_trigger t ON t.tgname = e.trigger_name AND NOT t.tgisinternal

    UNION ALL

    SELECT
        'security_definer_search_path',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM expected_routines e
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(e.routine_signature)
    WHERE p.oid IS NULL
       OR NOT p.prosecdef
       OR NOT COALESCE(p.proconfig,ARRAY[]::text[])::text[]
              @> ARRAY['search_path=public, pg_temp']::text[]

    UNION ALL

    SELECT
        'browser_write_boundary',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('table_count',count(*))
    FROM expected_tables e
    WHERE has_table_privilege(
        'authenticated','public.' || e.table_name,'INSERT,UPDATE,DELETE'
    )

    UNION ALL

    SELECT
        'rpc_execute_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_transaction_category(uuid,bigint,text,text,text,text,boolean)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.save_transaction_account_rule(uuid,uuid,text,uuid,timestamp with time zone,timestamp with time zone,text)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.save_transaction_category(uuid,bigint,text,text,text,text,boolean)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_transaction_category(uuid,bigint,text,text,text,text,boolean)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.save_transaction_category(uuid,bigint,text,text,text,text,boolean)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        '{}'::jsonb

    UNION ALL

    SELECT
        'finance_worker_browser_boundary',
        CASE WHEN NOT has_function_privilege(
            'authenticated','public.process_financial_events_queue()','EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_function_privilege(
            'authenticated','public.process_financial_events_queue()','EXECUTE'
        ) THEN 1 ELSE 0 END,
        '{}'::jsonb
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
