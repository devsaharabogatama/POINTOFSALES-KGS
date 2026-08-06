-- G4 phase 51 preflight: Sale overpayment -> Customer Balance credit readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts only; no Customer, receipt, or payment detail.
-- - Does not change checkout, create balance, or enable a Company feature.

WITH required_versions(version) AS (
    VALUES ('20260805090000'),('20260805100000')
), expected_payment_columns(column_name) AS (
    VALUES
        ('overpayment_disposition'),
        ('customer_balance_credit_amount'),
        ('customer_balance_ledger_entry_id')
), enabled_companies AS (
    SELECT company.id AS company_id
    FROM public.companies company
    JOIN public.company_features feature
      ON feature.company_id=company.id
     AND feature.feature_code='customer_balance_enabled'
     AND feature.is_enabled
    JOIN public.customer_balance_company_policies policy
      ON policy.company_id=company.id
     AND policy.lifecycle_state='ACTIVE'
    WHERE company.status='ACTIVE'
), customer_ledger AS (
    SELECT
        customer.company_id,
        customer.id AS customer_id,
        customer.current_balance,
        COALESCE(sum(
            CASE entry.direction WHEN 'CREDIT' THEN entry.amount
                                 ELSE -entry.amount END
        ),0) AS ledger_balance
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
), source_constraint AS (
    SELECT pg_get_constraintdef(constraint_row.oid) AS definition
    FROM pg_constraint constraint_row
    JOIN pg_class relation ON relation.oid=constraint_row.conrelid
    JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
    WHERE namespace.nspname='public'
      AND relation.relname='customer_balance_ledger_entries'
      AND constraint_row.conname='customer_balance_ledger_source_check'
), enabled_company_functions AS (
    SELECT company.company_id,function_key
    FROM enabled_companies company
    CROSS JOIN (VALUES
        ('CUSTOMER_BALANCE_LIABILITY'::TEXT),
        ('CASH_DRAWER'::TEXT),
        ('BANK'::TEXT)
    ) required(function_key)
), checks AS (
    SELECT
        'g4_phase51_dependencies'::TEXT AS check_name,
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
        'customer_balance_sale_credit_snapshot_state',
        CASE WHEN count(*) FILTER(WHERE column_state.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_columns',count(*),
            'missing_columns',COALESCE(
                jsonb_agg(expected.column_name ORDER BY expected.column_name)
                    FILTER(WHERE column_state.column_name IS NULL),
                '[]'::JSONB
            )
        )
    FROM expected_payment_columns expected
    LEFT JOIN information_schema.columns column_state
      ON column_state.table_schema='public'
     AND column_state.table_name='sales_payments'
     AND column_state.column_name=expected.column_name

    UNION ALL

    SELECT
        'customer_balance_ledger_sale_source_contract',
        CASE WHEN count(*)=1
                  AND bool_and(definition LIKE '%SALE_OVERPAYMENT%')
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'constraint_rows',count(*),
            'sale_overpayment_supported',COALESCE(bool_or(
                definition LIKE '%SALE_OVERPAYMENT%'
            ),FALSE)
        )
    FROM source_constraint

    UNION ALL

    SELECT
        'canonical_sale_balance_credit_runtime',
        CASE WHEN count(*)=1
                  AND bool_and(definition LIKE '%SALE_OVERPAYMENT%')
                  AND bool_and(definition LIKE '%customer_balance_ledger_entries%')
                  AND bool_and(definition LIKE '%customer_balance_credit_amount%')
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'sale_overpayment_source',COALESCE(bool_or(
                definition LIKE '%SALE_OVERPAYMENT%'
            ),FALSE),
            'ledger_write_present',COALESCE(bool_or(
                definition LIKE '%customer_balance_ledger_entries%'
            ),FALSE),
            'credit_snapshot_present',COALESCE(bool_or(
                definition LIKE '%customer_balance_credit_amount%'
            ),FALSE)
        )
    FROM sale_core

    UNION ALL

    SELECT
        'customer_balance_cache_ledger_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('customer_count',count(*))
    FROM customer_ledger
    WHERE current_balance<>ledger_balance

    UNION ALL

    SELECT
        'negative_or_walk_in_customer_balance',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.customers customer
    WHERE customer.current_balance<0
       OR (customer.is_system_customer AND customer.current_balance<>0)

    UNION ALL

    SELECT
        'enabled_company_customer_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM enabled_companies company
    WHERE NOT EXISTS(
        SELECT 1 FROM public.customers customer
        WHERE customer.company_id=company.company_id
          AND customer.is_active
          AND NOT customer.is_system_customer
    )

    UNION ALL

    SELECT
        'enabled_company_sale_credit_account_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'missing_company_function_rows',count(*),
            'companies_affected',count(DISTINCT required.company_id)
        )
    FROM enabled_company_functions required
    WHERE NOT EXISTS(
        SELECT 1
        FROM public.chart_of_accounts account
        WHERE account.company_id=required.company_id
          AND account.system_function_key=required.function_key
          AND account.is_active AND account.is_postable
    )
      AND NOT EXISTS(
        SELECT 1
        FROM public.company_account_function_fallbacks fallback
        JOIN public.chart_of_accounts account
          ON account.company_id=fallback.company_id
         AND account.id=fallback.account_id
         AND account.is_active AND account.is_postable
        WHERE fallback.company_id=required.company_id
          AND fallback.account_function_key=required.function_key
          AND fallback.status='ACTIVE'
          AND fallback.effective_from<=clock_timestamp()
          AND (
              fallback.effective_to IS NULL
              OR fallback.effective_to>clock_timestamp()
          )
    )

    UNION ALL

    SELECT
        'enabled_company_receipt_category_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM enabled_companies company
    WHERE NOT EXISTS(
        SELECT 1 FROM public.transaction_categories category
        WHERE category.company_id=company.company_id
          AND category.system_key='CUSTOMER_BALANCE_RECEIPT'
          AND category.is_active
    )

    UNION ALL

    SELECT
        'historical_noncash_overpayment',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'payment_rows',count(*),
            'companies',count(DISTINCT payment.company_id),
            'overpayment_total',COALESCE(sum(payment.change_amount),0)
        )
    FROM public.sales_payments payment
    WHERE payment.payment_method_type_snapshot IS DISTINCT FROM 'CASH'
      AND payment.change_amount>0
      AND NOT payment.is_reversal

    UNION ALL

    SELECT
        'historical_cash_change_inventory',
        'INFO',
        jsonb_build_object(
            'payment_rows',count(*),
            'companies',count(DISTINCT payment.company_id),
            'returned_change_total',COALESCE(sum(payment.change_amount),0)
        )
    FROM public.sales_payments payment
    WHERE payment.payment_method_type_snapshot='CASH'
      AND payment.change_amount>0
      AND NOT payment.is_reversal

    UNION ALL

    SELECT
        'posted_sale_payment_tender_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_payments payment
    JOIN public.sales_headers sale
      ON sale.company_id=payment.company_id
     AND sale.id=payment.sales_id
    WHERE sale.document_status='POSTED'
      AND NOT payment.is_reversal
      AND (
          payment.amount<=0
          OR payment.tendered_amount IS NULL
          OR payment.tendered_amount<payment.amount
          OR payment.change_amount<0
      )

    UNION ALL

    SELECT
        'posted_sale_customer_identity_readiness',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers sale
    LEFT JOIN public.customers customer
      ON customer.company_id=sale.company_id
     AND customer.id=sale.customer_id
    WHERE sale.document_status='POSTED'
      AND (
          customer.id IS NULL
          OR customer.company_id IS DISTINCT FROM sale.company_id
      )

    UNION ALL

    SELECT
        'browser_direct_sale_balance_write_boundary',
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.customer_balance_ledger_entries',
            'INSERT,UPDATE,DELETE'
        ) AND NOT has_column_privilege(
            'authenticated','public.customers','current_balance','UPDATE'
        ) THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'ledger_write',has_table_privilege(
                'authenticated','public.customer_balance_ledger_entries',
                'INSERT,UPDATE,DELETE'
            ),
            'balance_update',has_column_privilege(
                'authenticated','public.customers','current_balance','UPDATE'
            )
        )

    UNION ALL

    SELECT
        'sale_overpayment_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'posted_sales',(
                SELECT count(*) FROM public.sales_headers
                WHERE document_status='POSTED'
            ),
            'payment_rows',(
                SELECT count(*) FROM public.sales_payments
                WHERE NOT is_reversal
            ),
            'cash_payment_rows',(
                SELECT count(*) FROM public.sales_payments
                WHERE payment_method_type_snapshot='CASH' AND NOT is_reversal
            ),
            'transfer_payment_rows',(
                SELECT count(*) FROM public.sales_payments
                WHERE payment_method_type_snapshot='TRANSFER' AND NOT is_reversal
            ),
            'enabled_companies',(SELECT count(*) FROM enabled_companies),
            'customers_with_balance',(
                SELECT count(*) FROM public.customers
                WHERE current_balance>0 AND NOT is_system_customer
            )
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'PASS' THEN 3
        WHEN 'SETUP' THEN 4
        ELSE 5
    END,
    check_name;
