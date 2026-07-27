-- G2 phase 36 postflight: automatic hidden technical codes.
-- SELECT-only. Expected: all rows PASS with violation_rows = 0.

WITH target_triggers(trigger_name) AS (
    VALUES
        ('g2_automatic_product_category_code'),
        ('g2_automatic_uom_code'),
        ('g2_automatic_warehouse_code'),
        ('g2_automatic_supplier_code'),
        ('g2_automatic_customer_category_code'),
        ('g2_automatic_pricelist_code'),
        ('g2_automatic_payment_method_code'),
        ('g2_automatic_transaction_category_code')
), wrapper_signatures(signature) AS (
    VALUES
        ('save_supplier(uuid,bigint,text,text,text,text,text,text,text,text,text,boolean)'),
        ('save_customer_category(uuid,bigint,text,boolean)'),
        ('save_reusable_pricelist_with_rules(uuid,bigint,text,text,integer,boolean,boolean,uuid[],timestamp with time zone,timestamp with time zone,boolean,text,jsonb)'),
        ('save_payment_method(uuid,bigint,text,text,text,boolean,boolean,uuid[],text,boolean,text,text,numeric,numeric,text,text,timestamp with time zone,timestamp with time zone,boolean)'),
        ('save_transaction_category(uuid,bigint,text,text,text,boolean)')
), normalized_master AS (
    SELECT 'PRODUCT_CATEGORY'::TEXT AS entity_type,company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g')) AS normalized_name,
        category_code AS technical_code
    FROM public.product_categories
    UNION ALL
    SELECT 'UOM',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g')),code FROM public.uoms
    UNION ALL
    SELECT 'WAREHOUSE',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g')),code
    FROM public.warehouses
    UNION ALL
    SELECT 'SUPPLIER',company_id,
        lower(regexp_replace(btrim(supplier_name),'\s+',' ','g')),supplier_code
    FROM public.suppliers
    UNION ALL
    SELECT 'CUSTOMER_CATEGORY',company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g')),category_code
    FROM public.customer_categories
    UNION ALL
    SELECT 'PRICELIST',company_id,
        lower(regexp_replace(btrim(name),'\s+',' ','g')),code
    FROM public.pricelists
    UNION ALL
    SELECT 'PAYMENT_METHOD',company_id,
        lower(regexp_replace(btrim(payment_method_name),'\s+',' ','g')),
        payment_method_code
    FROM public.payment_methods
    UNION ALL
    SELECT 'TRANSACTION_CATEGORY',company_id,
        lower(regexp_replace(btrim(category_name),'\s+',' ','g')),category_code
    FROM public.transaction_categories
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        abs(count(*)-1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations WHERE version='20260724010000'

    UNION ALL

    SELECT 'counter_table',CASE WHEN to_regclass(
        'private.master_code_counters'
    ) IS NULL THEN 1 ELSE 0 END,
    jsonb_build_object(
        'exists',to_regclass('private.master_code_counters') IS NOT NULL
    )

    UNION ALL

    SELECT 'private_allocator_routines',
        abs(count(*)-4),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='private'
      AND p.proname IN (
          'allocate_master_code','resolve_or_allocate_master_code',
          'reserve_master_code','trg_g2_automatic_master_code'
      )
      AND p.prosecdef
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]

    UNION ALL

    SELECT 'required_automatic_code_triggers',
        count(*) FILTER (WHERE tg.oid IS NULL),
        jsonb_build_object(
            'trigger_rows',count(tg.oid),
            'missing',COALESCE(
                jsonb_agg(t.trigger_name ORDER BY t.trigger_name)
                    FILTER (WHERE tg.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM target_triggers t
    LEFT JOIN pg_trigger tg
      ON tg.tgname=t.trigger_name AND NOT tg.tgisinternal

    UNION ALL

    SELECT 'guarded_wrapper_overloads',
        count(*) FILTER (WHERE p.oid IS NULL),
        jsonb_build_object(
            'wrapper_rows',count(p.oid),
            'missing',COALESCE(
                jsonb_agg(w.signature ORDER BY w.signature)
                    FILTER (WHERE p.oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM wrapper_signatures w
    LEFT JOIN pg_proc p
      ON p.oid=to_regprocedure('public.'||w.signature)

    UNION ALL

    SELECT 'automatic_code_privilege_boundary',
        count(*),
        jsonb_build_object('violation_rows',count(*))
    FROM (
        SELECT p.oid
        FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
        WHERE n.nspname='private'
          AND p.proname IN (
              'allocate_master_code','resolve_or_allocate_master_code',
              'reserve_master_code','trg_g2_automatic_master_code'
          )
          AND (
              has_function_privilege('anon',p.oid,'EXECUTE')
              OR has_function_privilege('authenticated',p.oid,'EXECUTE')
          )
        UNION ALL
        SELECT p.oid
        FROM wrapper_signatures w
        JOIN pg_proc p ON p.oid=to_regprocedure('public.'||w.signature)
        WHERE has_function_privilege('anon',p.oid,'EXECUTE')
           OR NOT has_function_privilege('authenticated',p.oid,'EXECUTE')
    ) violations

    UNION ALL

    SELECT 'blank_target_identity',count(*),
        jsonb_build_object('row_count',count(*))
    FROM normalized_master
    WHERE normalized_name='' OR btrim(COALESCE(technical_code,''))=''

    UNION ALL

    SELECT 'duplicate_normalized_target_name',count(*),
        jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT entity_type,company_id,normalized_name
        FROM normalized_master
        GROUP BY entity_type,company_id,normalized_name
        HAVING count(*)>1
    ) duplicates

    UNION ALL

    SELECT 'invalid_counter_value',count(*),
        jsonb_build_object('row_count',count(*))
    FROM private.master_code_counters
    WHERE last_value<=0

    UNION ALL

    SELECT 'counter_without_company',count(*),
        jsonb_build_object('row_count',count(*))
    FROM private.master_code_counters mc
    LEFT JOIN public.companies c ON c.id=mc.company_id
    WHERE c.id IS NULL

    UNION ALL

    SELECT 'existing_master_inventory','0'::BIGINT,
        jsonb_build_object(
            'target_rows',(SELECT count(*) FROM normalized_master),
            'counter_rows',(SELECT count(*) FROM private.master_code_counters)
        )
)
SELECT check_name,
    CASE WHEN violation_rows=0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows>0 THEN 1 ELSE 2 END,check_name;
