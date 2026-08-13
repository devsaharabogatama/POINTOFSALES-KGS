-- SLD-R2 postflight: delivery-fee total, snapshot, and Finance foundation.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH required_versions(version) AS (
    VALUES('20260811140000'),('20260811143000')
), expected_columns(column_name) AS (
    VALUES('delivery_fee_amount'),('delivery_fee_invoice_display_mode')
), expected_routines(schema_name,routine_name) AS (
    VALUES
        ('public','save_pos_sale_draft'),
        ('private','build_sales_invoice_snapshot'),
        ('private','trg_sld_r2_capture_posted_delivery_fee'),
        ('private','trg_sld_r2_sale_event_delivery_fee'),
        ('private','provision_sld_r2_delivery_revenue')
), active_company AS (
    SELECT id FROM public.companies WHERE status='ACTIVE'
), posted_reconciliation AS (
    SELECT sale.company_id,sale.id,sale.grand_total_after_rounding,
        sale.sisa_piutang,
        COALESCE(sum(payment.amount) FILTER(WHERE NOT payment.is_reversal),0)
            AS payment_amount
    FROM public.sales_headers sale
    LEFT JOIN public.sales_payments payment
      ON payment.company_id=sale.company_id AND payment.sales_id=sale.id
    WHERE sale.document_status='POSTED'
    GROUP BY sale.company_id,sale.id,sale.grand_total_after_rounding,
        sale.sisa_piutang
), checks AS (
    SELECT 'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) FILTER(WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*) FILTER(WHERE migration.version IS NULL) AS violation_rows,
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(required.version ORDER BY required.version)
                FILTER(WHERE migration.version IS NULL),'[]'::JSONB)) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL
    SELECT 'required_delivery_fee_columns',
        CASE WHEN count(*) FILTER(WHERE actual.column_name IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE actual.column_name IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(expected.column_name ORDER BY expected.column_name)
                FILTER(WHERE actual.column_name IS NULL),'[]'::JSONB))
    FROM expected_columns expected
    LEFT JOIN information_schema.columns actual
      ON actual.table_schema='public' AND actual.table_name='sales_headers'
     AND actual.column_name=expected.column_name

    UNION ALL
    SELECT 'required_delivery_fee_routines',
        CASE WHEN count(*) FILTER(WHERE procedure.oid IS NULL)=0
             THEN 'PASS' ELSE 'FAIL' END,
        count(*) FILTER(WHERE procedure.oid IS NULL),
        jsonb_build_object('expected',count(*),'missing',COALESCE(
            jsonb_agg(expected.schema_name||'.'||expected.routine_name
                ORDER BY expected.schema_name,expected.routine_name)
                FILTER(WHERE procedure.oid IS NULL),'[]'::JSONB))
    FROM expected_routines expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname=expected.schema_name
    LEFT JOIN pg_proc procedure
      ON procedure.pronamespace=namespace.oid
     AND procedure.proname=expected.routine_name

    UNION ALL
    SELECT 'shared_draft_post_reprice_contract',
        CASE WHEN count(*)=2 AND count(*) FILTER(
            WHERE procedure.proname='reprice_pos_sale_draft'
              AND lower(pg_get_functiondef(procedure.oid))
                    LIKE '%deliveryfeeamount%'
        )=1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*)=2 AND count(*) FILTER(
            WHERE procedure.proname='reprice_pos_sale_draft'
              AND lower(pg_get_functiondef(procedure.oid))
                    LIKE '%deliveryfeeamount%'
        )=1 THEN 0 ELSE 1 END,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='private'
      AND procedure.proname IN(
        'reprice_pos_sale_draft','reprice_pos_sale_draft_sld_r2_core'
      )

    UNION ALL
    SELECT 'delivery_fee_constraint_contract',
        CASE WHEN count(*)=3 THEN 'PASS' ELSE 'FAIL' END,
        3-count(*),jsonb_build_object('constraint_rows',count(*),'expected',3)
    FROM pg_constraint constraint_state
    WHERE constraint_state.conrelid='public.sales_headers'::regclass
      AND constraint_state.conname IN(
        'sales_headers_delivery_fee_nonnegative',
        'sales_headers_delivery_fee_display_mode_check',
        'sales_headers_delivery_fee_fulfillment_check'
      )

    UNION ALL
    SELECT 'invalid_delivery_fee_sale_shape',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.sales_headers
    WHERE delivery_fee_amount<0
       OR delivery_fee_invoice_display_mode NOT IN(
            'SHOW_SEPARATE','HIDE_BREAKDOWN'
       )
       OR (delivery_fee_amount<>0 AND fulfillment_mode<>'DELIVERY')

    UNION ALL
    SELECT 'posted_sale_payment_receivable_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('sale_count',count(*))
    FROM posted_reconciliation
    WHERE abs(payment_amount+COALESCE(sisa_piutang,0)
        -grand_total_after_rounding)>0.01

    UNION ALL
    SELECT 'new_delivery_invoice_snapshot_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers sale
    LEFT JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    WHERE sale.document_status='POSTED' AND sale.delivery_fee_amount>0
      AND (
        invoice.id IS NULL
        OR (invoice.snapshot_payload->'totals'->>'deliveryFee')::NUMERIC
            IS DISTINCT FROM sale.delivery_fee_amount
        OR invoice.snapshot_payload->'totals'
            ->>'deliveryFeeInvoiceDisplayMode'
            IS DISTINCT FROM sale.delivery_fee_invoice_display_mode
      )

    UNION ALL
    SELECT 'new_delivery_sale_event_snapshot_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('event_count',count(*))
    FROM public.sales_headers sale
    JOIN public.financial_events event
      ON event.company_id=sale.company_id
     AND event.source_table='sales_headers' AND event.source_id=sale.id
     AND event.system_event_key='SALE_POSTED'
    WHERE sale.document_status='POSTED' AND sale.delivery_fee_amount>0
      AND COALESCE((event.amounts->>'deliveryFee')::NUMERIC,-1)
          IS DISTINCT FROM sale.delivery_fee_amount

    UNION ALL
    SELECT 'delivery_revenue_finance_catalog',
        CASE WHEN account_function.function_key IS NOT NULL
               AND event.system_key IS NOT NULL THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN account_function.function_key IS NOT NULL
               AND event.system_key IS NOT NULL THEN 0 ELSE 1 END,
        jsonb_build_object(
            'account_function_exists',account_function.function_key IS NOT NULL,
            'sale_event_references_function',COALESCE(
                'DELIVERY_FEE_REVENUE'=ANY(
                    event.required_account_functions
                    ||event.conditional_account_functions
                    ||event.optional_account_functions
                ),FALSE)
        )
    FROM (SELECT 1) anchor
    LEFT JOIN public.account_functions account_function
      ON account_function.function_key='DELIVERY_FEE_REVENUE'
     AND account_function.is_active
    LEFT JOIN public.system_events event
      ON event.system_key='SALE_POSTED'
     AND 'DELIVERY_FEE_REVENUE'=ANY(
        event.required_account_functions||event.conditional_account_functions
        ||event.optional_account_functions
     )

    UNION ALL
    SELECT 'active_company_delivery_revenue_mapping',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*),
        jsonb_build_object('company_count',count(*))
    FROM active_company company
    WHERE NOT EXISTS(
        SELECT 1 FROM public.chart_of_accounts account
        JOIN public.company_account_function_fallbacks fallback
          ON fallback.company_id=account.company_id
         AND fallback.account_id=account.id
         AND fallback.account_function_key='DELIVERY_FEE_REVENUE'
         AND fallback.status='ACTIVE'
        WHERE account.company_id=company.id AND account.is_active
          AND account.is_postable
          AND account.system_function_key='DELIVERY_FEE_REVENUE'
    )

    UNION ALL
    SELECT 'browser_delivery_fee_write_boundary',
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
        ) AND has_function_privilege(
            'authenticated','public.save_pos_sale_draft(jsonb)','EXECUTE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
        ) AND has_function_privilege(
            'authenticated','public.save_pos_sale_draft(jsonb)','EXECUTE'
        ) THEN 0 ELSE 1 END,
        jsonb_build_object(
            'direct_sale_write',has_table_privilege(
                'authenticated','public.sales_headers','INSERT,UPDATE,DELETE'
            ),
            'guarded_draft_execute',has_function_privilege(
                'authenticated','public.save_pos_sale_draft(jsonb)','EXECUTE'
            )
        )

    UNION ALL
    SELECT 'legacy_history_compatibility','INFO',0,jsonb_build_object(
        'legacy_zero_fee_sales',count(*) FILTER(
            WHERE sale.delivery_fee_amount=0
        ),
        'legacy_invoice_snapshots_without_fee',count(*) FILTER(
            WHERE NOT COALESCE(invoice.snapshot_payload->'totals'
                ?'deliveryFee',FALSE)
        ),
        'policy','Immutable historical snapshots are intentionally not rewritten'
    )
    FROM public.sales_headers sale
    LEFT JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    WHERE sale.document_status='POSTED'

    UNION ALL
    SELECT 'delivery_fee_posting_runtime','DEFERRED',0,jsonb_build_object(
        'reason','G6 atomic posting currently supports Stock Opening only; Sale Events remain HOLD',
        'approved_sale_rule_sets',count(DISTINCT rule_set.id),
        'delivery_fee_rule_lines',count(*) FILTER(
            WHERE line.account_function_key='DELIVERY_FEE_REVENUE'
        )
    )
    FROM public.posting_rule_sets rule_set
    JOIN public.transaction_categories category
      ON category.company_id=rule_set.company_id
     AND category.id=rule_set.transaction_category_id
     AND category.system_key='SALE_POSTED'
    LEFT JOIN public.posting_rule_lines line
      ON line.company_id=rule_set.company_id
     AND line.rule_set_id=rule_set.id
    WHERE rule_set.status='APPROVED'
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2
    WHEN 'DEFERRED' THEN 3 ELSE 4 END,check_name;
