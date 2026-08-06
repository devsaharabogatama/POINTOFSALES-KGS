-- G4 phase 54 preflight: mandatory full Customer Balance usage at POS.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only and never exposes Customer identity/history.

WITH required_versions(version) AS (
    VALUES ('20260805090000'),('20260805130000')
), active_scope AS (
    SELECT
        company.id AS company_id,
        COALESCE(feature.is_enabled,FALSE) AS feature_enabled,
        policy.lifecycle_state,
        count(method.id) FILTER (
            WHERE method.method_type='CUSTOMER_BALANCE'
        ) AS method_rows,
        count(method.id) FILTER (
            WHERE method.method_type='CUSTOMER_BALANCE'
              AND method.is_active
              AND method.is_system_method
              AND method.settlement_route='INTERNAL_LIABILITY'
              AND method.available_all_stores
        ) AS eligible_method_rows
    FROM public.companies company
    LEFT JOIN public.company_features feature
      ON feature.company_id=company.id
     AND feature.feature_code='customer_balance_enabled'
    LEFT JOIN public.customer_balance_company_policies policy
      ON policy.company_id=company.id
    LEFT JOIN public.payment_methods method
      ON method.company_id=company.id
     AND method.method_type='CUSTOMER_BALANCE'
    WHERE company.status='ACTIVE'
    GROUP BY company.id,feature.is_enabled,policy.lifecycle_state
), ledger_balance AS (
    SELECT
        entry.company_id,
        entry.customer_id,
        COALESCE(sum(
            CASE entry.direction
                WHEN 'CREDIT' THEN entry.amount
                ELSE -entry.amount
            END
        ),0)::NUMERIC(20,4) AS ledger_total,
        max(entry.balance_after) FILTER (
            WHERE entry.created_at=(
                SELECT max(latest.created_at)
                FROM public.customer_balance_ledger_entries latest
                WHERE latest.company_id=entry.company_id
                  AND latest.customer_id=entry.customer_id
            )
        ) AS latest_balance
    FROM public.customer_balance_ledger_entries entry
    GROUP BY entry.company_id,entry.customer_id
), positive_customers AS (
    SELECT customer.company_id,customer.id,customer.current_balance
    FROM public.customers customer
    WHERE customer.current_balance>0
), core_runtime AS (
    SELECT COALESCE(string_agg(pg_get_functiondef(routine.oid),'\n'),'') AS body
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE namespace.nspname='private'
      AND routine.proname IN (
          'post_pos_sale_core','post_pos_sale_online_core'
      )
), ledger_source_constraint AS (
    SELECT COALESCE(string_agg(pg_get_constraintdef(constraint_row.oid),' '),'')
        AS definition
    FROM pg_constraint constraint_row
    JOIN pg_class table_row ON table_row.oid=constraint_row.conrelid
    JOIN pg_namespace namespace ON namespace.oid=table_row.relnamespace
    WHERE namespace.nspname='public'
      AND table_row.relname='customer_balance_ledger_entries'
      AND constraint_row.conname='customer_balance_ledger_source_check'
), checks AS (
    SELECT
        'g4_phase54_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER(WHERE migration.version IS NULL),
                '[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'active_company_balance_policy_readiness',
        CASE WHEN count(*) FILTER(
            WHERE feature_enabled
              AND (
                  lifecycle_state IS NULL
                  OR lifecycle_state NOT IN ('ACTIVE','WIND_DOWN')
              )
        )=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'active_companies',count(*),
            'enabled_companies',count(*) FILTER(WHERE feature_enabled),
            'active_policies',count(*) FILTER(WHERE lifecycle_state='ACTIVE'),
            'wind_down_policies',count(*) FILTER(
                WHERE lifecycle_state='WIND_DOWN'
            )
        )
    FROM active_scope

    UNION ALL

    SELECT
        'customer_balance_internal_method_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM active_scope
    WHERE (feature_enabled OR lifecycle_state='WIND_DOWN')
      AND (method_rows<>1 OR eligible_method_rows<>1)

    UNION ALL

    SELECT
        'customer_balance_cache_ledger_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('customer_count',count(*))
    FROM public.customers customer
    LEFT JOIN ledger_balance ledger
      ON ledger.company_id=customer.company_id
     AND ledger.customer_id=customer.id
    WHERE customer.current_balance
          <> COALESCE(ledger.ledger_total,0)::NUMERIC(20,4)
       OR COALESCE(ledger.latest_balance,customer.current_balance)
          <> customer.current_balance

    UNION ALL

    SELECT
        'invalid_customer_balance_holder',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.customers customer
    WHERE customer.current_balance<0
       OR (customer.current_balance>0 AND customer.is_system_customer)

    UNION ALL

    SELECT
        'positive_balance_customer_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM positive_customers balance
    JOIN public.customers customer
      ON customer.company_id=balance.company_id AND customer.id=balance.id
    LEFT JOIN active_scope scope ON scope.company_id=balance.company_id
    WHERE customer.is_system_customer
       OR NOT customer.is_active
       OR scope.lifecycle_state IS NULL
       OR scope.lifecycle_state NOT IN ('ACTIVE','WIND_DOWN')

    UNION ALL

    SELECT
        'customer_balance_usage_category_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT DISTINCT balance.company_id
        FROM positive_customers balance
        WHERE NOT EXISTS (
            SELECT 1 FROM public.transaction_categories category
            WHERE category.company_id=balance.company_id
              AND category.system_key='CUSTOMER_BALANCE_USAGE'
              AND category.is_active
        )
    ) missing_category

    UNION ALL

    SELECT
        'customer_balance_usage_account_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'companies_affected',count(DISTINCT balance.company_id),
            'missing_company_function_rows',count(*)
        )
    FROM positive_customers balance
    CROSS JOIN (VALUES
        ('CUSTOMER_BALANCE_LIABILITY'),('CUSTOMER_RECEIVABLE')
    ) required(function_key)
    WHERE NOT EXISTS (
        SELECT 1 FROM public.chart_of_accounts account
        WHERE account.company_id=balance.company_id
          AND account.system_function_key=required.function_key
          AND account.is_active
          AND account.is_postable
    )
      AND NOT EXISTS (
        SELECT 1
        FROM public.company_account_function_fallbacks fallback
        JOIN public.chart_of_accounts account
          ON account.company_id=fallback.company_id
         AND account.id=fallback.account_id
        WHERE fallback.company_id=balance.company_id
          AND fallback.account_function_key=required.function_key
          AND fallback.status='ACTIVE'
          AND fallback.effective_from<=clock_timestamp()
          AND (
              fallback.effective_to IS NULL
              OR fallback.effective_to>clock_timestamp()
          )
          AND account.is_active
          AND account.is_postable
    )

    UNION ALL

    SELECT
        'existing_balance_usage_ledger_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.customer_balance_ledger_entries entry
    WHERE entry.direction='DEBIT'
      AND entry.source_type<>'MANUAL_CORRECTION'

    UNION ALL

    SELECT
        'historical_customer_balance_tender',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'payment_rows',count(*),
            'companies',count(DISTINCT payment.company_id)
        )
    FROM public.sales_payments payment
    WHERE NOT payment.is_reversal
      AND payment.payment_method_type_snapshot='CUSTOMER_BALANCE'

    UNION ALL

    SELECT
        'customer_balance_ledger_sale_usage_contract',
        CASE WHEN definition~'SALE_PAYMENT' THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'sale_payment_source_supported',definition~'SALE_PAYMENT'
        )
    FROM ledger_source_constraint

    UNION ALL

    SELECT
        'canonical_balance_tender_runtime',
        CASE WHEN body~'CUSTOMER_BALANCE_USAGE'
                   AND body~'INSUFFICIENT_CUSTOMER_BALANCE'
                   AND body!~'DEFERRED_PAYMENT_METHOD_NOT_ENABLED'
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'usage_event_present',body~'CUSTOMER_BALANCE_USAGE',
            'full_balance_guard_present',body~'INSUFFICIENT_CUSTOMER_BALANCE',
            'deferred_method_guard_present',
                body~'DEFERRED_PAYMENT_METHOD_NOT_ENABLED'
        )
    FROM core_runtime

    UNION ALL

    SELECT
        'customer_balance_tender_snapshot_state',
        CASE WHEN count(*) FILTER(
            WHERE column_name IN (
                'customer_balance_usage_amount',
                'customer_balance_usage_ledger_entry_id'
            )
        )=2 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'missing_columns',ARRAY(
                SELECT expected.column_name
                FROM (VALUES
                    ('customer_balance_usage_amount'),
                    ('customer_balance_usage_ledger_entry_id')
                ) expected(column_name)
                WHERE NOT EXISTS (
                    SELECT 1 FROM information_schema.columns actual
                    WHERE actual.table_schema='public'
                      AND actual.table_name='sales_payments'
                      AND actual.column_name=expected.column_name
                )
            )
        )
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sales_payments'

    UNION ALL

    SELECT
        'browser_direct_customer_balance_write_boundary',
        'INFO',
        jsonb_build_object(
            'ledger_insert',has_table_privilege(
                'authenticated','public.customer_balance_ledger_entries',
                'INSERT'
            ),
            'customer_update',has_table_privilege(
                'authenticated','public.customers','UPDATE'
            ),
            'sales_payment_insert',has_table_privilege(
                'authenticated','public.sales_payments','INSERT'
            )
        )

    UNION ALL

    SELECT
        'customer_balance_tender_inventory',
        'INFO',
        jsonb_build_object(
            'positive_balance_customers',count(*),
            'companies',count(DISTINCT company_id),
            'balance_total',COALESCE(sum(current_balance),0)
        )
    FROM positive_customers
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'SETUP' THEN 3
        WHEN 'PASS' THEN 4
        ELSE 5
    END,
    check_name;
