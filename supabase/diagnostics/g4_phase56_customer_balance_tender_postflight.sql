-- G4 phase 56 postflight: Customer Balance online tender foundation.
-- SAFETY: SELECT-only; aggregate contract checks and no business identity.

WITH checks AS (
    SELECT 'migration_ledger'::text AS check_name,
        CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END AS status,
        CASE WHEN count(*)=1 THEN 0 ELSE 1 END::bigint AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version='20260805160000'

    UNION ALL
    SELECT 'required_payment_snapshot_columns',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,2-count(*),
        jsonb_build_object('column_rows',count(*),'expected',2)
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sales_payments'
      AND column_name IN(
          'customer_balance_usage_amount',
          'customer_balance_usage_ledger_entry_id'
      )

    UNION ALL
    SELECT 'required_balance_tender_routines',
        CASE WHEN count(*)=5 THEN 'PASS' ELSE 'FAIL' END,5-count(*),
        jsonb_build_object('routine_rows',count(*),'expected',5)
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
    WHERE (namespace.nspname,routine.proname,
           pg_get_function_identity_arguments(routine.oid)) IN (
        ('public','post_pos_sale','p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid'),
        ('private','post_pos_sale_core','p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid'),
        ('private','post_pos_sale_balance_credit_core','p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid'),
        ('private','post_pos_sale_online_core','p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid'),
        ('private','post_pos_sale_phase52_public_core','p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid')
    )

    UNION ALL
    SELECT 'customer_balance_online_runtime_contract',
        CASE WHEN count(*)=3
                  AND string_agg(definition,E'\n')
                      ~'FULL_CUSTOMER_BALANCE_USAGE_REQUIRED'
                  AND string_agg(definition,E'\n')
                      ~'CUSTOMER_BALANCE_EXCEEDS_SALE_TOTAL'
                  AND string_agg(definition,E'\n')~'SALE_PAYMENT'
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=3
                  AND string_agg(definition,E'\n')
                      ~'FULL_CUSTOMER_BALANCE_USAGE_REQUIRED'
                  AND string_agg(definition,E'\n')
                      ~'CUSTOMER_BALANCE_EXCEEDS_SALE_TOTAL'
                  AND string_agg(definition,E'\n')~'SALE_PAYMENT'
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM (
        SELECT pg_get_functiondef(routine.oid) AS definition
        FROM pg_proc routine
        JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
        WHERE namespace.nspname IN('public','private')
          AND routine.proname IN(
              'post_pos_sale','post_pos_sale_core',
              'post_pos_sale_phase52_public_core'
          )
          AND pg_get_function_identity_arguments(routine.oid)=
              'p_sales_id uuid, p_master_version bigint, p_posting_idempotency_key uuid'
    ) runtime

    UNION ALL
    SELECT 'online_core_deferred_method_guard',
        CASE WHEN definition~'KETUL_OFFSET'
                  AND definition~'DEFERRED_PAYMENT_METHOD_NOT_ENABLED'
                  AND definition!~'CUSTOMER_BALANCE'',''KETUL_OFFSET'
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN definition~'KETUL_OFFSET'
                  AND definition~'DEFERRED_PAYMENT_METHOD_NOT_ENABLED'
                  AND definition!~'CUSTOMER_BALANCE'',''KETUL_OFFSET'
             THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',CASE WHEN definition IS NULL THEN 0 ELSE 1 END)
    FROM (SELECT pg_get_functiondef(
        'private.post_pos_sale_online_core(uuid,bigint,uuid)'::regprocedure
    ) AS definition) source

    UNION ALL
    SELECT 'customer_balance_ledger_sale_payment_source',
        CASE WHEN count(*)=1
                  AND bool_and(pg_get_constraintdef(constraint_row.oid)~'SALE_PAYMENT')
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=1
                  AND bool_and(pg_get_constraintdef(constraint_row.oid)~'SALE_PAYMENT')
             THEN 0 ELSE 1 END,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid=
          'public.customer_balance_ledger_entries'::regclass
      AND constraint_row.conname='customer_balance_ledger_source_check'

    UNION ALL
    SELECT 'customer_balance_payment_snapshot_shape',
        CASE WHEN count(*)=2 THEN 'PASS' ELSE 'FAIL' END,2-count(*),
        jsonb_build_object('constraint_rows',count(*),'expected',2)
    FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid='public.sales_payments'::regclass
      AND constraint_row.conname IN(
          'sales_payments_customer_balance_usage_shape',
          'fk_sales_payments_customer_balance_usage_ledger'
      )

    UNION ALL
    SELECT 'customer_balance_usage_payment_ledger_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments payment
    LEFT JOIN public.customer_balance_ledger_entries entry
      ON entry.company_id=payment.company_id
     AND entry.id=payment.customer_balance_usage_ledger_entry_id
    WHERE payment.customer_balance_usage_amount>0
      AND (entry.id IS NULL OR entry.direction<>'DEBIT'
           OR entry.source_type<>'SALE_PAYMENT'
           OR entry.source_id<>payment.id OR entry.amount<>payment.amount)

    UNION ALL
    SELECT 'customer_balance_usage_financial_event_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.customer_balance_ledger_entries entry
    LEFT JOIN public.financial_events event
      ON event.company_id=entry.company_id AND event.id=entry.financial_event_id
    WHERE entry.source_type='SALE_PAYMENT'
      AND (event.id IS NULL OR event.source_table<>'sales_payments'
           OR event.source_id<>entry.source_id
           OR event.system_event_key<>'CUSTOMER_BALANCE_USAGE')

    UNION ALL
    SELECT 'customer_balance_cache_ledger_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('customer_count',count(*))
    FROM public.customers customer
    WHERE customer.current_balance<>COALESCE((
        SELECT sum(CASE WHEN entry.direction='CREDIT'
                        THEN entry.amount ELSE -entry.amount END)
        FROM public.customer_balance_ledger_entries entry
        WHERE entry.company_id=customer.company_id
          AND entry.customer_id=customer.id
    ),0)

    UNION ALL
    SELECT 'negative_or_walk_in_customer_balance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.customers customer
    WHERE customer.current_balance<0
       OR (customer.is_system_customer AND customer.current_balance<>0)

    UNION ALL
    SELECT 'browser_balance_tender_boundary',
        CASE WHEN NOT has_table_privilege(
                       'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
                   )
                  AND NOT has_table_privilege(
                       'authenticated','public.customer_balance_ledger_entries','INSERT,UPDATE,DELETE'
                   )
                  AND has_function_privilege(
                       'authenticated','public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
                   )
                  AND NOT has_function_privilege(
                       'authenticated','private.post_pos_sale_core(uuid,bigint,uuid)','EXECUTE'
                   )
             THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege(
                       'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
                   )
                  AND NOT has_table_privilege(
                       'authenticated','public.customer_balance_ledger_entries','INSERT,UPDATE,DELETE'
                   )
                  AND has_function_privilege(
                       'authenticated','public.post_pos_sale(uuid,bigint,uuid)','EXECUTE'
                   )
                  AND NOT has_function_privilege(
                       'authenticated','private.post_pos_sale_core(uuid,bigint,uuid)','EXECUTE'
                   )
             THEN 0 ELSE 1 END,
        jsonb_build_object(
            'payment_write',has_table_privilege(
                'authenticated','public.sales_payments','INSERT,UPDATE,DELETE'
            ),
            'ledger_write',has_table_privilege(
                'authenticated','public.customer_balance_ledger_entries','INSERT,UPDATE,DELETE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
         check_name;
