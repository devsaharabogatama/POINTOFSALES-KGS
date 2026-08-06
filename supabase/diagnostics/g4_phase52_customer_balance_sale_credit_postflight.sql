-- G4 phase 52 postflight: Customer Balance Sale overpayment credit.
-- SAFETY: SELECT-only aggregate verification.

WITH expected_columns(column_name) AS (
    VALUES ('overpayment_disposition'),('customer_balance_credit_amount'),
           ('customer_balance_ledger_entry_id')
), expected_routines(schema_name,routine_name) AS (
    VALUES ('private','post_pos_sale_core'),
           ('private','post_pos_sale_online_core'),
           ('private','calculate_cashier_session_expected_cash'),
           ('public','post_pos_sale'),
           ('private','trg_g4_customer_balance_source_integrity')
), core_definition AS (
    SELECT pg_get_functiondef(procedure.oid) AS definition
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='private'
      AND procedure.proname='post_pos_sale_core'
), wrapper_definition AS (
    SELECT pg_get_functiondef(procedure.oid) AS definition
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public' AND procedure.proname='post_pos_sale'
      AND pg_get_function_identity_arguments(procedure.oid)
          ='p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid'
), customer_ledger AS (
    SELECT customer.company_id,customer.id,customer.current_balance,
        COALESCE(sum(CASE entry.direction WHEN 'CREDIT' THEN entry.amount
                     ELSE -entry.amount END),0) AS ledger_balance
    FROM public.customers customer
    LEFT JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=customer.company_id AND entry.customer_id=customer.id
    WHERE NOT customer.is_system_customer
    GROUP BY customer.company_id,customer.id,customer.current_balance
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*) FILTER(WHERE FALSE)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations WHERE version='20260805130000'

    UNION ALL
    SELECT 'required_payment_columns',
        CASE WHEN count(*) FILTER(WHERE actual.column_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE actual.column_name IS NULL),
        jsonb_build_object('missing',COALESCE(jsonb_agg(expected.column_name)
            FILTER(WHERE actual.column_name IS NULL),'[]'::JSONB))
    FROM expected_columns expected
    LEFT JOIN information_schema.columns actual
      ON actual.table_schema='public' AND actual.table_name='sales_payments'
     AND actual.column_name=expected.column_name

    UNION ALL
    SELECT 'required_sale_credit_routines',
        CASE WHEN count(*) FILTER(WHERE procedure.oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE procedure.oid IS NULL),
        jsonb_build_object('missing',COALESCE(jsonb_agg(
            expected.schema_name||'.'||expected.routine_name
        ) FILTER(WHERE procedure.oid IS NULL),'[]'::JSONB))
    FROM expected_routines expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname=expected.schema_name
    LEFT JOIN pg_proc procedure ON procedure.pronamespace=namespace.oid
      AND procedure.proname=expected.routine_name

    UNION ALL
    SELECT 'cashier_expected_cash_credit_runtime',
        CASE WHEN count(*)=1 AND bool_and(
            pg_get_functiondef(procedure.oid)
                LIKE '%customer_balance_credit_amount%'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 AND bool_and(
            pg_get_functiondef(procedure.oid)
                LIKE '%customer_balance_credit_amount%'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='private'
      AND procedure.proname='calculate_cashier_session_expected_cash'

    UNION ALL
    SELECT 'sale_credit_atomic_runtime',
        CASE WHEN count(*)=1 AND bool_and(
            definition LIKE '%SALE_OVERPAYMENT%'
            AND definition LIKE '%customer_balance_ledger_entries%'
            AND definition LIKE '%FOR UPDATE%'
            AND definition LIKE '%OFFLINE_CUSTOMER_BALANCE_CREDIT_NOT_ENABLED%'
            AND definition LIKE '%customer_balance_credit_amount%'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 AND bool_and(
            definition LIKE '%SALE_OVERPAYMENT%'
            AND definition LIKE '%customer_balance_ledger_entries%'
            AND definition LIKE '%FOR UPDATE%'
            AND definition LIKE '%OFFLINE_CUSTOMER_BALANCE_CREDIT_NOT_ENABLED%'
            AND definition LIKE '%customer_balance_credit_amount%'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM core_definition

    UNION ALL
    SELECT 'receipt_credit_snapshot_runtime',
        CASE WHEN count(*)=1 AND bool_and(
            definition LIKE '%customerBalanceCreditAmount%'
            AND definition LIKE '%overpaymentDisposition%'
            AND definition LIKE '%clientPaymentKey%'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 AND bool_and(
            definition LIKE '%customerBalanceCreditAmount%'
            AND definition LIKE '%overpaymentDisposition%'
            AND definition LIKE '%clientPaymentKey%'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM wrapper_definition

    UNION ALL
    SELECT 'ledger_sale_source_contract',
        CASE WHEN count(*)=1 AND bool_and(
            pg_get_constraintdef(constraint_row.oid) LIKE '%SALE_OVERPAYMENT%'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1 AND bool_and(
            pg_get_constraintdef(constraint_row.oid) LIKE '%SALE_OVERPAYMENT%'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid=
        'public.customer_balance_ledger_entries'::regclass
      AND constraint_row.conname='customer_balance_ledger_source_check'

    UNION ALL
    SELECT 'ledger_source_integrity_trigger',
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END,
        abs(1-count(*)),jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid=
        'public.customer_balance_ledger_entries'::regclass
      AND trigger_row.tgname='g4_customer_balance_source_integrity'
      AND NOT trigger_row.tgisinternal

    UNION ALL
    SELECT 'customer_balance_cache_ledger_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('customer_count',count(*))
    FROM customer_ledger WHERE current_balance<>ledger_balance

    UNION ALL
    SELECT 'sale_credit_payment_ledger_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments payment
    LEFT JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=payment.company_id
     AND entry.id=payment.customer_balance_ledger_entry_id
    WHERE payment.overpayment_disposition='CUSTOMER_BALANCE'
      AND (entry.id IS NULL OR entry.source_type<>'SALE_OVERPAYMENT'
           OR entry.source_id<>payment.id
           OR entry.amount<>payment.customer_balance_credit_amount
           OR payment.change_amount<>0)

    UNION ALL
    SELECT 'noncredit_payment_link_absent',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments
    WHERE overpayment_disposition IS DISTINCT FROM 'CUSTOMER_BALANCE'
      AND (customer_balance_credit_amount<>0
           OR customer_balance_ledger_entry_id IS NOT NULL)

    UNION ALL
    SELECT 'sale_credit_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.customer_balance_ledger_entries entry
    LEFT JOIN public.financial_events event
      ON event.company_id=entry.company_id
     AND event.id=entry.financial_event_id
    WHERE entry.source_type='SALE_OVERPAYMENT'
      AND (event.id IS NULL
           OR event.event_type::TEXT<>'CUSTOMER_BALANCE_ADJUSTMENT'
           OR event.source_table<>'sales_payments'
           OR event.source_id<>entry.source_id
           OR event.status::TEXT<>'HOLD')

    UNION ALL
    SELECT 'browser_direct_balance_write_boundary',
        CASE WHEN NOT has_table_privilege('authenticated',
            'public.customer_balance_ledger_entries','INSERT,UPDATE,DELETE')
          AND NOT has_column_privilege('authenticated','public.customers',
            'current_balance','UPDATE') THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege('authenticated',
            'public.customer_balance_ledger_entries','INSERT,UPDATE,DELETE')
          AND NOT has_column_privilege('authenticated','public.customers',
            'current_balance','UPDATE') THEN 0 ELSE 1 END,
        jsonb_build_object('ledger_write',has_table_privilege('authenticated',
            'public.customer_balance_ledger_entries','INSERT,UPDATE,DELETE'),
            'balance_update',has_column_privilege('authenticated',
            'public.customers','current_balance','UPDATE'))

    UNION ALL
    SELECT 'sale_credit_runtime_inventory','INFO',0,
        jsonb_build_object(
            'credited_payments',count(*) FILTER(WHERE
                overpayment_disposition='CUSTOMER_BALANCE'),
            'returned_payments',count(*) FILTER(WHERE
                overpayment_disposition='RETURNED'),
            'legacy_disposition_rows',count(*) FILTER(WHERE
                overpayment_disposition IS NULL),
            'credited_amount',COALESCE(sum(customer_balance_credit_amount),0)
        )
    FROM public.sales_payments WHERE NOT is_reversal
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
