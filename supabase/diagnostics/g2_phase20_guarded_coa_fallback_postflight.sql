-- G2 phase 20 postflight: guarded COA and explicit Company fallback.
-- Expected: 8 PASS rows with violation_rows = 0.

WITH expected_public_routines(signature) AS (
    VALUES
        ('public.save_chart_of_account(uuid,bigint,text,text,text,text,uuid,text,boolean,boolean,boolean,boolean)'),
        ('public.save_company_account_function_fallback(uuid,text,uuid,timestamp with time zone,timestamp with time zone,text)')
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*) - 1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722230000'

    UNION ALL

    SELECT
        'guarded_public_routines',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 2)::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM expected_public_routines expected
    JOIN pg_proc p ON p.oid = to_regprocedure(expected.signature)
    WHERE p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]

    UNION ALL

    SELECT
        'guarded_public_routine_privileges',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 2)::BIGINT,
        jsonb_build_object('safe_routine_rows',count(*))
    FROM expected_public_routines expected
    JOIN pg_proc p ON p.oid = to_regprocedure(expected.signature)
    WHERE NOT has_function_privilege('anon',p.oid,'EXECUTE')
      AND has_function_privilege('authenticated',p.oid,'EXECUTE')
      AND has_function_privilege('service_role',p.oid,'EXECUTE')

    UNION ALL

    SELECT
        'coa_structure_guard_function',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_guard_chart_of_account_structure'
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]
      AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')

    UNION ALL

    SELECT
        'coa_structure_guard_trigger',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger
    WHERE tgrelid = 'public.chart_of_accounts'::regclass
      AND tgname = 'g2_guard_chart_of_account_structure'
      AND NOT tgisinternal

    UNION ALL

    SELECT
        'finance_history_guard_extended',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_guard_finance_master_history'
      AND pg_get_functiondef(p.oid) LIKE '%ACCOUNT_FUNCTION_LOCKED_BY_HISTORY%'

    UNION ALL

    SELECT
        'direct_finance_master_write_closed',
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.chart_of_accounts','INSERT,UPDATE,DELETE'
        ) AND NOT has_table_privilege(
            'authenticated','public.company_account_function_fallbacks',
            'INSERT,UPDATE,DELETE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_table_privilege(
            'authenticated','public.chart_of_accounts','INSERT,UPDATE,DELETE'
        ) OR has_table_privilege(
            'authenticated','public.company_account_function_fallbacks',
            'INSERT,UPDATE,DELETE'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'coa_direct_write',has_table_privilege(
                'authenticated','public.chart_of_accounts',
                'INSERT,UPDATE,DELETE'
            ),
            'fallback_direct_write',has_table_privilege(
                'authenticated','public.company_account_function_fallbacks',
                'INSERT,UPDATE,DELETE'
            )
        )

    UNION ALL

    SELECT
        'finance_master_rls_preserved',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 2)::BIGINT,
        jsonb_build_object('rls_table_rows',count(*))
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
          'chart_of_accounts','company_account_function_fallbacks'
      )
      AND c.relrowsecurity
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
