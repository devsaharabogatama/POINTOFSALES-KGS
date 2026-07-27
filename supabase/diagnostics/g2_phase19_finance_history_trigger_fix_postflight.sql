-- G2 phase 19 postflight: Finance history trigger branch isolation.
-- Expected: 5 PASS rows with violation_rows = 0.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*) - 1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722210000'

    UNION ALL

    SELECT
        'history_guard_function_contract',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_guard_finance_master_history'
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]
      AND pg_get_functiondef(p.oid) LIKE
          '%IF TG_TABLE_NAME = ''transaction_categories'' THEN%'
      AND pg_get_functiondef(p.oid) LIKE
          '%ELSIF TG_TABLE_NAME = ''chart_of_accounts'' THEN%'

    UNION ALL

    SELECT
        'history_guard_trigger_bindings',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 2)::BIGINT,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger t
    JOIN pg_proc p ON p.oid = t.tgfoid
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE NOT t.tgisinternal
      AND n.nspname = 'private'
      AND p.proname = 'trg_g2_guard_finance_master_history'
      AND t.tgrelid IN (
          'public.transaction_categories'::regclass,
          'public.chart_of_accounts'::regclass
      )

    UNION ALL

    SELECT
        'history_guard_execute_boundary',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('safe_routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname = 'trg_g2_guard_finance_master_history'
      AND NOT has_function_privilege('anon',p.oid,'EXECUTE')
      AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
      AND has_function_privilege('service_role',p.oid,'EXECUTE')

    UNION ALL

    SELECT
        'required_category_coverage_preserved',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('company_count',count(*))
    FROM public.companies c
    WHERE c.status = 'ACTIVE'
      AND (
          SELECT count(*)
          FROM public.transaction_categories tc
          WHERE tc.company_id = c.id
            AND tc.is_system_default
            AND tc.is_active
      ) <> 26
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
