-- G2 phase 28 postflight: private Tax resolver/calculator boundary.
-- Expected result: every row PASS with violation_rows = 0.

WITH required_routines(signature,security_definer) AS (
    VALUES
        (
            'private.resolve_product_tax_rule(uuid,uuid,text,timestamp with time zone)',
            TRUE
        ),
        (
            'private.calculate_tax_group(jsonb,numeric,text,text,text)',
            FALSE
        )
), routine_catalog AS (
    SELECT
        required.signature,
        required.security_definer,
        p.oid,
        p.prosecdef,
        p.proconfig
    FROM required_routines required
    LEFT JOIN pg_proc p ON p.oid = to_regprocedure(required.signature)
), checkout_routines AS (
    SELECT pg_get_functiondef(p.oid) AS definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'create_sales_transaction',
          'private_create_sales_transaction_g1_legacy'
      )
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260723070000'

    UNION ALL

    SELECT
        'required_private_routines',
        count(*) FILTER(WHERE oid IS NULL),
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(signature ORDER BY signature)
                    FILTER(WHERE oid IS NULL),
                '[]'::JSONB
            )
        )
    FROM routine_catalog

    UNION ALL

    SELECT
        'routine_security_contract',
        count(*) FILTER(
            WHERE oid IS NULL
               OR prosecdef IS DISTINCT FROM security_definer
               OR NOT COALESCE(proconfig,ARRAY[]::TEXT[])::TEXT[]
                   @> ARRAY['search_path=public, pg_temp']::TEXT[]
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM routine_catalog

    UNION ALL

    SELECT
        'browser_private_routine_execute',
        count(*) FILTER(
            WHERE oid IS NOT NULL AND (
                has_function_privilege('anon',oid,'EXECUTE')
                OR has_function_privilege('authenticated',oid,'EXECUTE')
            )
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM routine_catalog

    UNION ALL

    SELECT
        'service_role_private_routine_execute',
        count(*) FILTER(
            WHERE oid IS NULL
               OR NOT has_function_privilege('service_role',oid,'EXECUTE')
        ),
        jsonb_build_object('routine_rows',count(*))
    FROM routine_catalog

    UNION ALL

    SELECT
        'public_tax_calculation_rpc',
        count(*),
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
          'resolve_product_tax_rule','calculate_tax_group'
      )

    UNION ALL

    SELECT
        'checkout_tax_cutover_remains_disabled',
        count(*) FILTER(
            WHERE definition ~* 'tax_(rule|amount|base|rounding)'
        ),
        jsonb_build_object(
            'checkout_routines',count(*),
            'tax_integrated_routines',count(*) FILTER(
                WHERE definition ~* 'tax_(rule|amount|base|rounding)'
            )
        )
    FROM checkout_routines
)
SELECT
    check_name,
    CASE WHEN violation_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    violation_rows,
    details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
