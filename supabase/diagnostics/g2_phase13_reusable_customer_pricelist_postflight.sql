-- G2 phase 13 reusable Customer Pricelist postflight. SELECT-only.

WITH checks AS (
    SELECT 'migration_ledger'::text AS check_name,
        count(*) = 1 AS passed,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722100000'

    UNION ALL
    SELECT 'customer_pricelist_column',count(*) = 1,
        jsonb_build_object('column_rows',count(*))
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='customers'
      AND column_name='default_pricelist_id' AND is_nullable='YES'

    UNION ALL
    SELECT 'customer_pricelist_fk',count(*) = 1,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint
    WHERE conrelid='public.customers'::regclass
      AND conname='fk_customers_company_default_pricelist'
      AND convalidated

    UNION ALL
    SELECT 'reusable_pricelist_constraint',count(*) = 1,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint
    WHERE conrelid='public.pricelists'::regclass
      AND conname='pricelists_reusable_customer_scope_check'
      AND convalidated

    UNION ALL
    SELECT 'assignment_lifecycle_triggers',count(*) = 2,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger
    WHERE NOT tgisinternal AND tgname IN (
        'g2_guard_customer_pricelist_assignment',
        'g2_guard_assigned_pricelist_lifecycle'
    )

    UNION ALL
    SELECT 'guarded_rpc_privileges',
        has_function_privilege(
            'authenticated',
            'public.save_reusable_pricelist_with_rules(uuid,bigint,text,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
            'EXECUTE'
        ) AND has_function_privilege(
            'authenticated',
            'public.save_customer_with_pricelist(uuid,bigint,text,text,uuid,text,text,text,text,numeric,integer,text,boolean,uuid,uuid)',
            'EXECUTE'
        ),
        jsonb_build_object('expected','both authenticated RPCs executable')

    UNION ALL
    SELECT 'legacy_pricelist_rpc_closed',NOT has_function_privilege(
        'authenticated',
        'public.save_pricelist_with_rules(uuid,bigint,text,text,text,uuid,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)',
        'EXECUTE'
    ),jsonb_build_object('expected','legacy RPC not executable')

    UNION ALL
    SELECT 'legacy_header_customer_reference_empty',count(*) = 0,
        jsonb_build_object('row_count',count(*))
    FROM public.pricelists WHERE customer_id IS NOT NULL

    UNION ALL
    SELECT 'system_customer_assignment_empty',count(*) = 0,
        jsonb_build_object('row_count',count(*))
    FROM public.customers
    WHERE is_system_customer AND default_pricelist_id IS NOT NULL

    UNION ALL
    SELECT 'invalid_customer_pricelist_assignment',count(*) = 0,
        jsonb_build_object('row_count',count(*))
    FROM public.customers c
    LEFT JOIN public.pricelists p
      ON p.company_id=c.company_id AND p.id=c.default_pricelist_id
    WHERE c.default_pricelist_id IS NOT NULL
      AND (p.id IS NULL OR p.scope<>'CUSTOMER' OR NOT p.is_active)

    UNION ALL
    SELECT 'active_company_global_default_invariant',count(*) = 0,
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT c.id
        FROM public.companies c
        LEFT JOIN public.pricelists p
          ON p.company_id=c.id AND p.scope='GLOBAL'
         AND p.is_default AND p.is_active
        WHERE c.status='ACTIVE'
        GROUP BY c.id HAVING count(p.id)<>1
    ) invalid

    UNION ALL
    SELECT 'direct_browser_writes_closed',
        NOT has_table_privilege('authenticated','public.customers','UPDATE')
        AND NOT has_table_privilege('authenticated','public.pricelists','UPDATE'),
        jsonb_build_object('expected','guarded RPC only')
)
SELECT check_name,
    CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS status,
    details
FROM checks
ORDER BY CASE WHEN passed THEN 2 ELSE 1 END,check_name;
