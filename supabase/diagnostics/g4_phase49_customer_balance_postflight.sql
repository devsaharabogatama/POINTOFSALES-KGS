-- G4 phase 49 postflight: Customer Balance ledger/correction foundation.
-- SELECT-only. Run the entire file after migration 20260805090000.

WITH expected_tables(table_name) AS (
    VALUES
        ('customer_balance_company_policies'),
        ('customer_balance_ledger_entries'),
        ('customer_balance_correction_requests'),
        ('customer_balance_audit')
), expected_routines(schema_name,routine_name) AS (
    VALUES
        ('public','get_customer_balance_statement'),
        ('public','request_customer_balance_correction'),
        ('public','review_customer_balance_correction'),
        ('private','resolve_customer_balance_account'),
        ('private','provision_customer_balance_company')
), customer_ledger AS (
    SELECT
        customer.company_id,customer.id AS customer_id,
        customer.current_balance,
        COALESCE(sum(CASE entry.direction WHEN 'CREDIT' THEN entry.amount
                         ELSE -entry.amount END),0) AS ledger_balance
    FROM public.customers customer
    LEFT JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=customer.company_id
     AND entry.customer_id=customer.id
    WHERE NOT customer.is_system_customer
    GROUP BY customer.company_id,customer.id,customer.current_balance
), sale_core AS (
    SELECT pg_get_functiondef(procedure.oid) AS definition
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='private'
      AND procedure.proname='post_pos_sale_core'
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260805090000'

    UNION ALL
    SELECT 'required_customer_balance_tables',
        CASE WHEN count(*) FILTER(WHERE to_regclass('public.'||table_name) IS NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE to_regclass('public.'||table_name) IS NULL),
        jsonb_build_object('missing',COALESCE(jsonb_agg(table_name ORDER BY table_name) FILTER(WHERE to_regclass('public.'||table_name) IS NULL),'[]'::JSONB),'expected',count(*))
    FROM expected_tables

    UNION ALL
    SELECT 'required_customer_balance_routines',
        CASE WHEN count(*) FILTER(WHERE state.routine_name IS NULL)=0 THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE state.routine_name IS NULL),
        jsonb_build_object('missing',COALESCE(jsonb_agg(expected.schema_name||'.'||expected.routine_name ORDER BY expected.schema_name,expected.routine_name) FILTER(WHERE state.routine_name IS NULL),'[]'::JSONB),'expected',count(*))
    FROM expected_routines expected
    LEFT JOIN LATERAL (
        SELECT procedure.proname AS routine_name
        FROM pg_proc procedure
        JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
        WHERE namespace.nspname=expected.schema_name
          AND procedure.proname=expected.routine_name LIMIT 1
    ) state ON TRUE

    UNION ALL
    SELECT 'company_policy_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    WHERE NOT EXISTS(SELECT 1 FROM public.customer_balance_company_policies policy WHERE policy.company_id=company.id)

    UNION ALL
    SELECT 'company_internal_method_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    WHERE NOT EXISTS(
        SELECT 1 FROM public.payment_methods method
        WHERE method.company_id=company.id
          AND method.method_type='CUSTOMER_BALANCE'
          AND method.is_system_method
          AND method.settlement_route='INTERNAL_LIABILITY'
    )

    UNION ALL
    SELECT 'duplicate_company_internal_method',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('duplicate_companies',count(*))
    FROM (
        SELECT company_id FROM public.payment_methods
        WHERE method_type='CUSTOMER_BALANCE'
        GROUP BY company_id HAVING count(*)<>1
    ) duplicate_company

    UNION ALL
    SELECT 'policy_feature_lifecycle_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.customer_balance_company_policies policy
    LEFT JOIN public.company_features feature
      ON feature.company_id=policy.company_id
     AND feature.feature_code='customer_balance_enabled'
    WHERE (COALESCE(feature.is_enabled,FALSE) AND policy.lifecycle_state<>'ACTIVE')
       OR (NOT COALESCE(feature.is_enabled,FALSE)
           AND policy.lifecycle_state='ACTIVE')
       OR (policy.lifecycle_state='WIND_DOWN' AND NOT EXISTS(
            SELECT 1 FROM public.customers customer
            WHERE customer.company_id=policy.company_id
              AND customer.current_balance>0
       ))

    UNION ALL
    SELECT 'customer_balance_cache_ledger_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('customer_count',count(*))
    FROM customer_ledger WHERE current_balance<>ledger_balance

    UNION ALL
    SELECT 'negative_or_walk_in_customer_balance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.customers
    WHERE current_balance<0 OR (is_system_customer AND current_balance<>0)

    UNION ALL
    SELECT 'approved_correction_final_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('request_count',count(*))
    FROM public.customer_balance_correction_requests request
    LEFT JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=request.company_id
     AND entry.id=request.ledger_entry_id
    LEFT JOIN public.financial_events event
      ON event.id=request.financial_event_id
    WHERE request.status='APPROVED'
      AND (entry.id IS NULL OR event.id IS NULL OR event.status<>'HOLD')

    UNION ALL
    SELECT 'customer_balance_history_immutable_triggers',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,
        abs(2-count(*))::BIGINT,
        jsonb_build_object('trigger_rows',count(*),'expected',2)
    FROM pg_trigger trigger
    JOIN pg_class relation ON relation.oid=trigger.tgrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND trigger.tgname IN (
        'g4_customer_balance_ledger_immutable',
        'g4_customer_balance_audit_immutable'
      ) AND NOT trigger.tgisinternal

    UNION ALL
    SELECT 'browser_customer_balance_write_boundary',
        CASE WHEN NOT bool_or(has_table_privilege('authenticated','public.'||table_name,'INSERT,UPDATE,DELETE')) THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE has_table_privilege('authenticated','public.'||table_name,'INSERT,UPDATE,DELETE')),
        jsonb_build_object('direct_write',bool_or(has_table_privilege('authenticated','public.'||table_name,'INSERT,UPDATE,DELETE')))
    FROM expected_tables

    UNION ALL
    SELECT 'browser_customer_balance_rpc_boundary',
        CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
        abs(3-count(*))::BIGINT,
        jsonb_build_object('authenticated_rpc_rows',count(*),'expected',3)
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND procedure.proname IN (
        'get_customer_balance_statement',
        'request_customer_balance_correction',
        'review_customer_balance_correction'
      ) AND has_function_privilege('authenticated',procedure.oid,'EXECUTE')

    UNION ALL
    SELECT 'canonical_sale_customer_balance_remains_closed',
        CASE WHEN count(*)=1 AND bool_and(definition LIKE '%DEFERRED_PAYMENT_METHOD_NOT_ENABLED%') THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 AND bool_and(definition LIKE '%DEFERRED_PAYMENT_METHOD_NOT_ENABLED%') THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*),'runtime_closed',COALESCE(bool_or(definition LIKE '%DEFERRED_PAYMENT_METHOD_NOT_ENABLED%'),FALSE))
    FROM sale_core

    UNION ALL
    SELECT 'customer_balance_runtime_inventory','INFO',0,
        jsonb_build_object(
            'policies',(SELECT count(*) FROM public.customer_balance_company_policies),
            'active_policies',(SELECT count(*) FROM public.customer_balance_company_policies WHERE lifecycle_state='ACTIVE'),
            'wind_down_policies',(SELECT count(*) FROM public.customer_balance_company_policies WHERE lifecycle_state='WIND_DOWN'),
            'internal_methods',(SELECT count(*) FROM public.payment_methods WHERE method_type='CUSTOMER_BALANCE'),
            'correction_requests',(SELECT count(*) FROM public.customer_balance_correction_requests),
            'ledger_entries',(SELECT count(*) FROM public.customer_balance_ledger_entries),
            'balance_total',(SELECT COALESCE(sum(current_balance),0) FROM public.customers)
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
