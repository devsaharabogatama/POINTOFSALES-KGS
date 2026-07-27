-- G2 phase 13 Pricelist default guard postflight. SELECT-only.
-- Expected: 6 PASS rows with violation_rows = 0.

WITH checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations WHERE version = '20260722080000'

    UNION ALL

    SELECT 'active_company_default_global',count(*),
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT c.id FROM public.companies c
        LEFT JOIN public.pricelists p ON p.company_id=c.id
          AND p.scope='GLOBAL' AND p.is_default AND p.is_active
        WHERE c.status='ACTIVE' GROUP BY c.id HAVING count(p.id)<>1
    ) invalid

    UNION ALL

    SELECT 'required_triggers_missing',2-count(*),
        jsonb_build_object('trigger_count',count(*))
    FROM pg_trigger t
    JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND NOT t.tgisinternal
      AND t.tgname IN (
        'g2_require_default_global_pricelist',
        'g2_guard_company_activation_pricelist'
      )

    UNION ALL

    SELECT 'guard_function_search_path',count(*),
        jsonb_build_object('routine_count',count(*))
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE (
        (n.nspname='private' AND p.proname IN (
        'trg_g2_require_default_global_pricelist',
        'trg_g2_guard_company_activation_pricelist',
        'private_save_pricelist_with_rules_g2_legacy'
        )) OR (n.nspname='public' AND p.proname='save_pricelist_with_rules')
      )
      AND p.prosecdef
      AND NOT COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]

    UNION ALL

    SELECT 'browser_guard_execute_privilege',count(*),
        jsonb_build_object('routine_count',count(*))
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='private'
      AND p.proname IN (
        'trg_g2_require_default_global_pricelist',
        'trg_g2_guard_company_activation_pricelist',
        'private_save_pricelist_with_rules_g2_legacy'
      )
      AND (
        has_function_privilege('anon',p.oid,'EXECUTE')
        OR has_function_privilege('authenticated',p.oid,'EXECUTE')
      )

    UNION ALL

    SELECT 'public_rpc_privilege',(
        CASE WHEN has_function_privilege(
            'anon',
            'public.save_pricelist_with_rules(uuid,bigint,text,text,text,uuid,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
            'EXECUTE'
        ) THEN 1 ELSE 0 END
        + CASE WHEN NOT has_function_privilege(
            'authenticated',
            'public.save_pricelist_with_rules(uuid,bigint,text,text,text,uuid,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
            'EXECUTE'
        ) THEN 1 ELSE 0 END
    )::BIGINT,jsonb_build_object('expected','anon denied; authenticated allowed')
)
SELECT check_name,
    CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows>0 THEN 1 ELSE 2 END,check_name;
