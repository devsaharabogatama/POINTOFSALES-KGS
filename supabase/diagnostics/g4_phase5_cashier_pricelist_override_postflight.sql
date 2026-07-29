-- G4 phase 5 Cashier Pricelist override postflight.
-- SAFETY: SELECT-only.

WITH checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260729100000'

    UNION ALL

    SELECT
        'guarded_pricelist_wrappers',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        (2 - count(*))::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (
          p.oid = to_regprocedure(
              'public.save_pos_sale_draft_with_pricelist(jsonb)'
          )
          OR p.oid = to_regprocedure(
              'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)'
          )
      )

    UNION ALL

    SELECT
        'browser_pricelist_wrapper_boundary',
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_pos_sale_draft_with_pricelist(jsonb)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.save_pos_sale_draft_with_pricelist(jsonb)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            has_function_privilege(
                'authenticated',
                'public.save_pos_sale_draft_with_pricelist(jsonb)',
                'EXECUTE'
            )
            AND has_function_privilege(
                'authenticated',
                'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.save_pos_sale_draft_with_pricelist(jsonb)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object(
            'authenticated_save',has_function_privilege(
                'authenticated',
                'public.save_pos_sale_draft_with_pricelist(jsonb)',
                'EXECUTE'
            ),
            'authenticated_post',has_function_privilege(
                'authenticated',
                'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)',
                'EXECUTE'
            ),
            'anon_save',has_function_privilege(
                'anon',
                'public.save_pos_sale_draft_with_pricelist(jsonb)',
                'EXECUTE'
            ),
            'anon_post',has_function_privilege(
                'anon',
                'public.post_pos_sale_with_pricelist(uuid,bigint,uuid)',
                'EXECUTE'
            )
        )

    UNION ALL

    SELECT
        'private_price_resolver_boundary',
        CASE WHEN
            NOT has_function_privilege(
                'authenticated',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
                'EXECUTE'
            )
        THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN
            NOT has_function_privilege(
                'authenticated',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
                'EXECUTE'
            )
            AND NOT has_function_privilege(
                'anon',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
                'EXECUTE'
            )
        THEN 0 ELSE 1 END,
        jsonb_build_object(
            'authenticated_execute',has_function_privilege(
                'authenticated',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
                'EXECUTE'
            ),
            'anon_execute',has_function_privilege(
                'anon',
                'private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamptz)',
                'EXECUTE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY check_name;
