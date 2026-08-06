-- G4 phase 48 preflight: Customer Balance ledger/runtime readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Customer names, contacts, or business rows.
-- - Does not enable Customer Balance, change a balance, or open checkout usage.

WITH required_versions(version) AS (
    VALUES ('20260804160000')
), expected_tables(table_name) AS (
    VALUES
        ('customer_balance_company_policies'),
        ('customer_balance_ledger_entries'),
        ('customer_balance_correction_requests'),
        ('customer_balance_audit')
), expected_routines(schema_name,routine_name) AS (
    VALUES
        ('public','get_customer_balance_statement'),
        ('public','request_customer_balance_correction'),
        ('public','review_customer_balance_correction')
), required_system_events(system_key) AS (
    VALUES
        ('CUSTOMER_BALANCE_RECEIPT'),
        ('CUSTOMER_BALANCE_USAGE')
), active_companies AS (
    SELECT company.id AS company_id
    FROM public.companies company
    WHERE company.status='ACTIVE'
), balance_feature AS (
    SELECT
        company.company_id,
        COALESCE(feature.is_enabled,FALSE) AS is_enabled,
        feature.config
    FROM active_companies company
    LEFT JOIN public.company_features feature
      ON feature.company_id=company.company_id
     AND feature.feature_code='customer_balance_enabled'
), customer_inventory AS (
    SELECT
        count(*) AS customer_rows,
        count(DISTINCT customer.company_id) AS companies,
        count(*) FILTER (
            WHERE customer.is_active AND NOT customer.is_system_customer
        ) AS active_regular_customers,
        count(*) FILTER (WHERE customer.current_balance<>0) AS balance_rows,
        count(DISTINCT customer.company_id) FILTER (
            WHERE customer.current_balance<>0
        ) AS balance_companies,
        COALESCE(sum(customer.current_balance) FILTER (
            WHERE customer.current_balance<>0
        ),0) AS balance_total
    FROM public.customers customer
), balance_payment_inventory AS (
    SELECT
        count(payment.id) AS payment_rows,
        count(DISTINCT payment.company_id) AS companies,
        COALESCE(sum(payment.amount),0) AS payment_total
    FROM public.sales_payments payment
    WHERE payment.payment_method::TEXT='Customer_Balance'
       OR payment.payment_method_type_snapshot='CUSTOMER_BALANCE'
), company_required_category AS (
    SELECT company.company_id,event.system_key
    FROM active_companies company
    CROSS JOIN required_system_events event
), sale_core AS (
    SELECT pg_get_functiondef(procedure.oid) AS definition
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='private'
      AND procedure.proname='post_pos_sale_core'
), checks AS (
    SELECT
        'g4_phase48_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'customer_balance_feature_catalog',
        CASE WHEN count(*)=1 AND bool_and(feature.is_active)
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'catalog_rows',count(*),
            'active_rows',count(*) FILTER (WHERE feature.is_active)
        )
    FROM public.platform_features feature
    WHERE feature.feature_code='customer_balance_enabled'

    UNION ALL

    SELECT
        'customer_balance_entitlement_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',count(*),
            'enabled_companies',count(*) FILTER (WHERE is_enabled),
            'disabled_companies',count(*) FILTER (WHERE NOT is_enabled)
        )
    FROM balance_feature

    UNION ALL

    SELECT
        'enabled_entitlement_without_canonical_foundation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'enabled_companies',count(*),
            'missing_table_count',(
                SELECT count(*) FROM expected_tables expected
                WHERE to_regclass('public.'||expected.table_name) IS NULL
            )
        )
    FROM balance_feature feature
    WHERE feature.is_enabled
      AND EXISTS (
          SELECT 1 FROM expected_tables expected
          WHERE to_regclass('public.'||expected.table_name) IS NULL
      )

    UNION ALL

    SELECT
        'canonical_customer_balance_schema_state',
        CASE WHEN count(*) FILTER (
            WHERE to_regclass('public.'||expected.table_name) IS NULL
        )=0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_tables',count(*),
            'missing_tables',COALESCE(
                jsonb_agg(expected.table_name ORDER BY expected.table_name)
                    FILTER (
                        WHERE to_regclass('public.'||expected.table_name) IS NULL
                    ),
                '[]'::JSONB
            )
        )
    FROM expected_tables expected

    UNION ALL

    SELECT
        'canonical_customer_balance_routine_state',
        CASE WHEN count(*) FILTER (WHERE state.routine_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_routines',count(*),
            'missing_routines',COALESCE(
                jsonb_agg(
                    expected.schema_name||'.'||expected.routine_name
                    ORDER BY expected.schema_name,expected.routine_name
                ) FILTER (WHERE state.routine_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_routines expected
    LEFT JOIN LATERAL (
        SELECT procedure.proname AS routine_name
        FROM pg_proc procedure
        JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
        WHERE namespace.nspname=expected.schema_name
          AND procedure.proname=expected.routine_name
        LIMIT 1
    ) state ON TRUE

    UNION ALL

    SELECT
        'customer_balance_current_cache_inventory',
        'INFO',
        jsonb_build_object(
            'customers',customer_rows,
            'companies',companies,
            'active_regular_customers',active_regular_customers,
            'customers_with_balance',balance_rows,
            'companies_with_balance',balance_companies,
            'balance_total',balance_total
        )
    FROM customer_inventory

    UNION ALL

    SELECT
        'legacy_balance_without_canonical_ledger',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'customer_count',count(*),
            'companies',count(DISTINCT customer.company_id),
            'balance_total',COALESCE(sum(customer.current_balance),0)
        )
    FROM public.customers customer
    WHERE customer.current_balance<>0

    UNION ALL

    SELECT
        'negative_customer_balance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.customers customer
    WHERE customer.current_balance<0

    UNION ALL

    SELECT
        'walk_in_customer_with_balance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.customers customer
    WHERE customer.is_system_customer
      AND customer.current_balance<>0

    UNION ALL

    SELECT
        'customer_balance_payment_history',
        CASE WHEN payment_rows=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'payment_rows',payment_rows,
            'companies',companies,
            'payment_total',payment_total
        )
    FROM balance_payment_inventory

    UNION ALL

    SELECT
        'invalid_customer_balance_payment_reference',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments payment
    LEFT JOIN public.sales_headers sale
      ON sale.company_id=payment.company_id
     AND sale.id=payment.sales_id
    LEFT JOIN public.customers customer
      ON customer.company_id=sale.company_id
     AND customer.id=sale.customer_id
    WHERE (
        payment.payment_method::TEXT='Customer_Balance'
        OR payment.payment_method_type_snapshot='CUSTOMER_BALANCE'
    )
      AND (
          sale.id IS NULL
          OR customer.id IS NULL
          OR customer.is_system_customer
          OR payment.amount<=0
      )

    UNION ALL

    SELECT
        'customer_balance_payment_method_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.payment_methods method
    WHERE method.method_type='CUSTOMER_BALANCE'
      AND (
          NOT method.is_system_method
          OR method.settlement_route<>'INTERNAL_LIABILITY'
          OR method.fee_enabled
          OR method.clearing_account_function IS NOT NULL
          OR method.bank_account_function IS NOT NULL
      )

    UNION ALL

    SELECT
        'customer_balance_payment_method_inventory',
        'INFO',
        jsonb_build_object(
            'rows',count(*),
            'active_rows',count(*) FILTER (WHERE method.is_active),
            'companies',count(DISTINCT method.company_id)
        )
    FROM public.payment_methods method
    WHERE method.method_type='CUSTOMER_BALANCE'

    UNION ALL

    SELECT
        'active_company_internal_method_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object('companies_to_provision',count(*))
    FROM active_companies company
    WHERE NOT EXISTS (
        SELECT 1 FROM public.payment_methods method
        WHERE method.company_id=company.company_id
          AND method.method_type='CUSTOMER_BALANCE'
          AND method.is_system_method
    )

    UNION ALL

    SELECT
        'customer_balance_transaction_category_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('missing_company_event_rows',count(*))
    FROM company_required_category required
    WHERE NOT EXISTS (
        SELECT 1 FROM public.transaction_categories category
        WHERE category.company_id=required.company_id
          AND category.system_key=required.system_key
          AND category.is_active
    )

    UNION ALL

    SELECT
        'customer_balance_account_function_catalog',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('function_rows',count(*))
    FROM public.account_functions function_catalog
    WHERE function_catalog.function_key='CUSTOMER_BALANCE_LIABILITY'
      AND function_catalog.is_active

    UNION ALL

    SELECT
        'canonical_sale_customer_balance_boundary',
        CASE WHEN count(*)=1
                  AND bool_and(definition LIKE '%CUSTOMER_BALANCE%')
                  AND bool_and(
                      definition LIKE '%DEFERRED_PAYMENT_METHOD_NOT_ENABLED%'
                  )
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'customer_balance_referenced',COALESCE(bool_or(
                definition LIKE '%CUSTOMER_BALANCE%'
            ),FALSE),
            'runtime_closed',COALESCE(bool_or(
                definition LIKE '%DEFERRED_PAYMENT_METHOD_NOT_ENABLED%'
            ),FALSE)
        )
    FROM sale_core

    UNION ALL

    SELECT
        'direct_customer_balance_write_privilege',
        CASE WHEN NOT has_column_privilege(
            'authenticated','public.customers','current_balance','UPDATE'
        ) THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authenticated_current_balance_update',has_column_privilege(
                'authenticated','public.customers','current_balance','UPDATE'
            ),
            'customers_table_update',has_table_privilege(
                'authenticated','public.customers','UPDATE'
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'BACKFILL' THEN 2
        WHEN 'REVIEW' THEN 3
        WHEN 'PASS' THEN 4
        WHEN 'SETUP' THEN 5
        ELSE 6
    END,
    check_name;

