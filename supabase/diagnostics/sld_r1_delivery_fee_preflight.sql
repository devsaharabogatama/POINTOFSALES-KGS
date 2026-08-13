-- SLD-R1 preflight: final-checkout Delivery and delivery-fee readiness.
--
-- SAFETY:
-- - SELECT-only; no DDL, DML, TEMP table, function side effect, or grants.
-- - Returns aggregate counts and catalog metadata only.

WITH required_versions(version) AS (
    VALUES ('20260810200000'), ('20260811130000')
), expected_sale_columns(column_name) AS (
    VALUES
        ('delivery_fee_amount'),
        ('delivery_fee_invoice_display_mode')
), expected_routines(schema_name,routine_name) AS (
    VALUES
        ('private','post_pos_sale_online_core'),
        ('private','post_pos_sale_core'),
        ('public','save_pos_sale_draft'),
        ('public','submit_pos_offline_sale'),
        ('public','process_pos_offline_sale_submission'),
        ('private','build_sales_invoice_snapshot'),
        ('public','save_sales_return_draft'),
        ('public','post_sales_return')
), runtime_routines AS (
    SELECT
        namespace.nspname AS schema_name,
        procedure.proname AS routine_name,
        pg_get_functiondef(procedure.oid) AS definition
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    JOIN expected_routines expected
      ON expected.schema_name=namespace.nspname
     AND expected.routine_name=procedure.proname
), posted_sale_payment AS (
    SELECT
        sale.company_id,
        sale.id AS sales_id,
        sale.grand_total_after_rounding,
        sale.sisa_piutang,
        COALESCE(sum(payment.amount) FILTER (
            WHERE NOT payment.is_reversal
        ),0) AS payment_amount
    FROM public.sales_headers sale
    LEFT JOIN public.sales_payments payment
      ON payment.company_id=sale.company_id
     AND payment.sales_id=sale.id
    WHERE sale.document_status='POSTED'
    GROUP BY
        sale.company_id,sale.id,sale.grand_total_after_rounding,
        sale.sisa_piutang
), active_companies AS (
    SELECT id FROM public.companies WHERE status='ACTIVE'
), sale_event_status AS (
    SELECT status,count(*) AS status_count
    FROM public.financial_events
    WHERE system_event_key='SALE_POSTED'
    GROUP BY status
), checks AS (
    SELECT
        'sld_r1_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(required.version ORDER BY required.version)
                FILTER (WHERE migration.version IS NULL),'[]'::JSONB)
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version=required.version

    UNION ALL

    SELECT
        'required_delivery_fee_runtime_routines',
        CASE WHEN count(*) FILTER (WHERE runtime.routine_name IS NULL)=0
             THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(jsonb_agg(
                expected.schema_name||'.'||expected.routine_name
                ORDER BY expected.schema_name,expected.routine_name
            ) FILTER (WHERE runtime.routine_name IS NULL),'[]'::JSONB)
        )
    FROM expected_routines expected
    LEFT JOIN runtime_routines runtime
      ON runtime.schema_name=expected.schema_name
     AND runtime.routine_name=expected.routine_name

    UNION ALL

    SELECT
        'canonical_delivery_fee_schema_state',
        CASE WHEN count(*) FILTER (WHERE actual.column_name IS NULL)=0
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected_columns',count(*),
            'missing_columns',COALESCE(jsonb_agg(expected.column_name
                ORDER BY expected.column_name)
                FILTER (WHERE actual.column_name IS NULL),'[]'::JSONB)
        )
    FROM expected_sale_columns expected
    LEFT JOIN information_schema.columns actual
      ON actual.table_schema='public'
     AND actual.table_name='sales_headers'
     AND actual.column_name=expected.column_name

    UNION ALL

    SELECT
        'canonical_delivery_fee_runtime_state',
        CASE WHEN count(*) FILTER (
            WHERE lower(definition) LIKE '%delivery_fee%'
               OR lower(definition) LIKE '%deliveryfee%'
        ) >= 6 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'routine_rows',count(*),
            'routines_referencing_delivery_fee',count(*) FILTER (
                WHERE lower(definition) LIKE '%delivery_fee%'
                   OR lower(definition) LIKE '%deliveryfee%'
            )
        )
    FROM runtime_routines

    UNION ALL

    SELECT
        'posted_sale_payment_receivable_reconciliation',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM posted_sale_payment
    WHERE abs(
        payment_amount+COALESCE(sisa_piutang,0)-grand_total_after_rounding
    )>0.01

    UNION ALL

    SELECT
        'invalid_existing_posted_sale_total',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers
    WHERE document_status='POSTED'
      AND (
          grand_total_after_rounding<0
          OR subtotal<0
          OR item_discount<0
          OR global_discount<0
          OR paid_amount<0
          OR sisa_piutang<0
      )

    UNION ALL

    SELECT
        'posted_sale_invoice_snapshot_coverage',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('sale_count',count(*))
    FROM public.sales_headers sale
    LEFT JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    WHERE sale.document_status='POSTED' AND invoice.id IS NULL

    UNION ALL

    SELECT
        'existing_delivery_document_contract',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.sales_delivery_documents delivery
    JOIN public.sales_headers sale
      ON sale.company_id=delivery.company_id AND sale.id=delivery.sales_id
    WHERE sale.fulfillment_mode<>'DELIVERY'
       OR btrim(delivery.recipient_name)=''
       OR btrim(delivery.recipient_phone)=''
       OR btrim(delivery.delivery_address)=''
       OR jsonb_typeof(delivery.snapshot_payload)<>'object'

    UNION ALL

    SELECT
        'nonterminal_offline_sale_submission',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'submission_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.pos_offline_sale_submissions
    WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')

    UNION ALL

    SELECT
        'active_company_delivery_revenue_account_candidate',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM active_companies company
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.chart_of_accounts account
        WHERE account.company_id=company.id
          AND account.is_active
          AND account.is_postable
          AND account.account_type IN ('REVENUE','OTHER_INCOME')
    )

    UNION ALL

    SELECT
        'delivery_fee_finance_catalog_state',
        CASE WHEN account_function.function_key IS NOT NULL
               AND event.system_key IS NOT NULL
               AND 'DELIVERY_FEE_REVENUE'=ANY(
                   event.required_account_functions
                   ||event.conditional_account_functions
                   ||event.optional_account_functions
               )
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'account_function_exists',account_function.function_key IS NOT NULL,
            'sale_event_exists',event.system_key IS NOT NULL,
            'sale_event_references_function',COALESCE(
                'DELIVERY_FEE_REVENUE'=ANY(
                    event.required_account_functions
                    ||event.conditional_account_functions
                    ||event.optional_account_functions
                ),FALSE
            )
        )
    FROM (SELECT 1) anchor
    LEFT JOIN public.account_functions account_function
      ON account_function.function_key='DELIVERY_FEE_REVENUE'
     AND account_function.is_active
    LEFT JOIN public.system_events event
      ON event.system_key='SALE_POSTED' AND event.is_active

    UNION ALL

    SELECT
        'delivery_fee_posting_rule_state',
        CASE WHEN count(*) FILTER (
            WHERE line.account_function_key='DELIVERY_FEE_REVENUE'
        )>0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'approved_sale_rule_sets',count(DISTINCT rule_set.id),
            'delivery_fee_rule_lines',count(*) FILTER (
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
      AND rule_set.effective_from<=CURRENT_DATE
      AND (rule_set.effective_to IS NULL OR rule_set.effective_to>CURRENT_DATE)

    UNION ALL

    SELECT
        'sales_tax_delivery_fee_decision_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'enabled_companies',count(*),
            'decision','No implicit delivery-fee tax; explicit Tax Rule required'
        )
    FROM public.company_features feature
    JOIN active_companies company ON company.id=feature.company_id
    WHERE feature.feature_code='tax_sales_enabled' AND feature.is_enabled

    UNION ALL

    SELECT
        'sales_return_delivery_fee_decision_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
        jsonb_build_object(
            'posted_return_count',count(*),
            'delivery_sale_return_count',count(*) FILTER (
                WHERE sale.fulfillment_mode='DELIVERY'
            ),
            'decision','Partial Product Return does not auto-refund delivery fee'
        )
    FROM public.sales_return_documents return_document
    JOIN public.sales_headers sale
      ON sale.company_id=return_document.company_id
     AND sale.id=return_document.source_sales_id
    WHERE return_document.status='POSTED'

    UNION ALL

    SELECT
        'legacy_delivery_fee_zero_backfill_scope',
        CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'posted_sales',count(*),
            'delivery_sales',count(*) FILTER (
                WHERE sale.fulfillment_mode='DELIVERY'
            ),
            'invoice_snapshots_without_delivery_fee',count(*) FILTER (
                WHERE NOT COALESCE(
                    invoice.snapshot_payload->'totals' ? 'deliveryFee',FALSE
                )
            )
        )
    FROM public.sales_headers sale
    JOIN public.sales_invoice_snapshots invoice
      ON invoice.company_id=sale.company_id AND invoice.sales_id=sale.id
    WHERE sale.document_status='POSTED'
      AND NOT COALESCE(
          invoice.snapshot_payload->'totals' ? 'deliveryFee',FALSE
      )

    UNION ALL

    SELECT
        'legacy_sale_event_delivery_fee_inventory',
        'INFO',
        jsonb_build_object(
            'sale_event_rows',count(*),
            'events_without_delivery_fee',count(*) FILTER (
                WHERE NOT COALESCE(financial.amounts ? 'deliveryFee',FALSE)
            ),
            'statuses',(SELECT COALESCE(
                jsonb_object_agg(status,status_count),'{}'::JSONB
            ) FROM sale_event_status)
        )
    FROM public.financial_events financial
    WHERE financial.system_event_key='SALE_POSTED'

    UNION ALL

    SELECT
        'delivery_fee_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(SELECT count(*) FROM active_companies),
            'posted_sales',(SELECT count(*) FROM public.sales_headers
                WHERE document_status='POSTED'),
            'delivery_sales',(SELECT count(*) FROM public.sales_headers
                WHERE document_status='POSTED'
                  AND fulfillment_mode='DELIVERY'),
            'invoice_snapshots',(SELECT count(*)
                FROM public.sales_invoice_snapshots),
            'delivery_documents',(SELECT count(*)
                FROM public.sales_delivery_documents),
            'posted_returns',(SELECT count(*)
                FROM public.sales_return_documents WHERE status='POSTED'),
            'offline_submissions',(SELECT count(*)
                FROM public.pos_offline_sale_submissions)
        )
)
SELECT check_name,status,details
FROM checks
ORDER BY
    CASE status
        WHEN 'BLOCKER' THEN 1
        WHEN 'REVIEW' THEN 2
        WHEN 'BACKFILL' THEN 3
        WHEN 'SETUP' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    check_name;
