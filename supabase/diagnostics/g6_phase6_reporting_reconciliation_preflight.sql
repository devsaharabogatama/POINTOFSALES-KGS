-- G6 corrective phase 6 preflight: Finance reports and reconciliation.
--
-- SAFETY:
-- - one SELECT statement only;
-- - aggregate counts/amounts and catalog metadata only;
-- - no document number, account name, counterparty, or payload output;
-- - no DDL, DML, lock, TEMP object, or routine execution;
-- - does not process HOLD, create queue runs, or build report cache.

WITH required_versions(version) AS (
    VALUES
        ('20260810180000'),
        ('20260810210000')
), expected_report_relations(relation_name) AS (
    VALUES
        ('finance_report_definitions'),
        ('finance_report_versions'),
        ('finance_report_lines'),
        ('finance_report_exports')
), expected_reconciliation_relations(relation_name) AS (
    VALUES
        ('finance_reconciliation_documents'),
        ('finance_reconciliation_allocations')
), expected_report_routines(routine_name) AS (
    VALUES
        ('get_finance_trial_balance'),
        ('get_finance_general_ledger'),
        ('get_finance_income_statement'),
        ('get_finance_balance_sheet'),
        ('get_finance_pending_analysis'),
        ('get_finance_reconciliation_summary')
), posted_journal_totals AS (
    SELECT
        journal.company_id,
        journal.id AS journal_id,
        journal.total_debit AS header_debit,
        journal.total_credit AS header_credit,
        count(line.id) AS line_count,
        COALESCE(sum(line.debit),0) AS line_debit,
        COALESCE(sum(line.credit),0) AS line_credit
    FROM public.finance_journals journal
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id = journal.company_id
     AND line.journal_id = journal.id
    WHERE journal.status = 'POSTED'
    GROUP BY
        journal.company_id,journal.id,
        journal.total_debit,journal.total_credit
), company_trial_balance AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(line.debit),0) AS debit_total,
        COALESCE(sum(line.credit),0) AS credit_total
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id = company.id
     AND journal.status = 'POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id = journal.company_id
     AND line.journal_id = journal.id
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), fifo_valuation AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(
            batch.qty_remaining * batch.cogs_unit
        ),0)::NUMERIC(24,4) AS fifo_value
    FROM public.companies company
    LEFT JOIN public.product_batches batch
      ON batch.company_id = company.id
     AND batch.qty_remaining > 0
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), inventory_gl AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(line.debit - line.credit),0)::NUMERIC(24,4)
            AS inventory_gl_value
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id = company.id
     AND journal.status = 'POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id = journal.company_id
     AND line.journal_id = journal.id
     AND line.account_function_key_snapshot = 'INVENTORY_ASSET'
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), stock_reconciliation AS (
    SELECT
        fifo.company_id,
        fifo.fifo_value,
        inventory.inventory_gl_value,
        round(fifo.fifo_value - inventory.inventory_gl_value,4)
            AS difference
    FROM fifo_valuation fifo
    JOIN inventory_gl inventory ON inventory.company_id = fifo.company_id
), validated_supplier_invoice AS (
    SELECT
        invoice.company_id,
        invoice.id AS invoice_id,
        invoice.grand_total,
        COALESCE(sum(allocation.allocated_amount) FILTER (
            WHERE payment.status = 'VALIDATED'
        ),0) AS paid_amount
    FROM public.supplier_invoice_documents invoice
    LEFT JOIN public.supplier_payment_allocations allocation
      ON allocation.company_id = invoice.company_id
     AND allocation.invoice_id = invoice.id
    LEFT JOIN public.supplier_payment_documents payment
      ON payment.company_id = allocation.company_id
     AND payment.id = allocation.document_id
    WHERE invoice.status = 'VALIDATED'
    GROUP BY invoice.company_id,invoice.id,invoice.grand_total
), ap_subledger AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(
            greatest(invoice.grand_total - invoice.paid_amount,0)
        ),0)::NUMERIC(24,4) AS open_ap_amount
    FROM public.companies company
    LEFT JOIN validated_supplier_invoice invoice
      ON invoice.company_id = company.id
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), ap_gl AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(line.credit - line.debit),0)::NUMERIC(24,4)
            AS ap_gl_amount
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id = company.id
     AND journal.status = 'POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id = journal.company_id
     AND line.journal_id = journal.id
     AND line.account_function_key_snapshot = 'SUPPLIER_AP_FINAL'
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), ap_reconciliation AS (
    SELECT
        subledger.company_id,subledger.open_ap_amount,ledger.ap_gl_amount,
        round(subledger.open_ap_amount - ledger.ap_gl_amount,4) AS difference
    FROM ap_subledger subledger
    JOIN ap_gl ledger ON ledger.company_id = subledger.company_id
), customer_balance_subledger AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(customer.current_balance),0)::NUMERIC(24,4)
            AS customer_balance_amount
    FROM public.companies company
    LEFT JOIN public.customers customer
      ON customer.company_id = company.id
     AND NOT customer.is_system_customer
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), customer_balance_gl AS (
    SELECT
        company.id AS company_id,
        COALESCE(sum(line.credit - line.debit),0)::NUMERIC(24,4)
            AS customer_balance_gl_amount
    FROM public.companies company
    LEFT JOIN public.finance_journals journal
      ON journal.company_id = company.id
     AND journal.status = 'POSTED'
    LEFT JOIN public.finance_journal_lines line
      ON line.company_id = journal.company_id
     AND line.journal_id = journal.id
     AND line.account_function_key_snapshot = 'CUSTOMER_BALANCE_LIABILITY'
    WHERE company.status = 'ACTIVE'
    GROUP BY company.id
), customer_balance_reconciliation AS (
    SELECT
        subledger.company_id,subledger.customer_balance_amount,
        ledger.customer_balance_gl_amount,
        round(
            subledger.customer_balance_amount
                - ledger.customer_balance_gl_amount,4
        ) AS difference
    FROM customer_balance_subledger subledger
    JOIN customer_balance_gl ledger
      ON ledger.company_id = subledger.company_id
), checks AS (
    SELECT
        'g6_phase6_dependencies'::TEXT AS check_name,
        CASE WHEN count(*) FILTER (WHERE migration.version IS NULL) = 0
             THEN 'PASS' ELSE 'BLOCKER' END AS status,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(required.version ORDER BY required.version)
                    FILTER (WHERE migration.version IS NULL),'[]'::JSONB
            )
        ) AS details
    FROM required_versions required
    LEFT JOIN private.kgs_schema_migrations migration
      ON migration.version = required.version

    UNION ALL

    SELECT
        'active_company_timezone_readiness',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM public.companies company
    LEFT JOIN pg_timezone_names timezone_state
      ON timezone_state.name = company.timezone
    WHERE company.status = 'ACTIVE'
      AND (
          btrim(COALESCE(company.timezone,'')) = ''
          OR timezone_state.name IS NULL
      )

    UNION ALL

    SELECT
        'canonical_report_schema_state',
        CASE WHEN count(relation.oid) = count(*)
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                    FILTER (WHERE relation.oid IS NULL),'[]'::JSONB
            )
        )
    FROM expected_report_relations expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.relation_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_reconciliation_schema_state',
        CASE WHEN count(relation.oid) = count(*)
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.relation_name ORDER BY expected.relation_name)
                    FILTER (WHERE relation.oid IS NULL),'[]'::JSONB
            )
        )
    FROM expected_reconciliation_relations expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_class relation
      ON relation.relnamespace = namespace.oid
     AND relation.relname = expected.relation_name
     AND relation.relkind IN ('r','p')

    UNION ALL

    SELECT
        'canonical_report_routine_state',
        CASE WHEN count(routine.oid) = count(*)
             THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'expected',count(*),
            'missing',COALESCE(
                jsonb_agg(expected.routine_name ORDER BY expected.routine_name)
                    FILTER (WHERE routine.oid IS NULL),'[]'::JSONB
            )
        )
    FROM expected_report_routines expected
    LEFT JOIN pg_namespace namespace ON namespace.nspname = 'public'
    LEFT JOIN pg_proc routine
      ON routine.pronamespace = namespace.oid
     AND routine.proname = expected.routine_name

    UNION ALL

    SELECT
        'unsafe_legacy_report_routine_execution',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'authenticated_executable_rows',count(*),
            'routine_names',COALESCE(
                jsonb_agg(DISTINCT routine.proname ORDER BY routine.proname),
                '[]'::JSONB
            )
        )
    FROM pg_proc routine
    JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
    WHERE namespace.nspname = 'public'
      AND routine.proname IN (
          'get_general_ledger_report','get_trial_balance_report',
          'get_income_statement_report','get_balance_sheet_report',
          'get_account_journal_lines'
      )
      AND has_function_privilege('authenticated',routine.oid,'EXECUTE')

    UNION ALL

    SELECT
        'browser_direct_finance_runtime_write',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object(
            'writable_relations',COALESCE(
                jsonb_agg(relation.relname ORDER BY relation.relname),
                '[]'::JSONB
            )
        )
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname IN (
          'finance_journals','finance_journal_lines',
          'finance_posting_queue_runs','finance_posting_queue_items',
          'finance_posting_exceptions'
      )
      AND has_table_privilege(
          'authenticated',relation.oid,'INSERT,UPDATE,DELETE'
      )

    UNION ALL

    SELECT
        'posted_journal_balance_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM posted_journal_totals total
    WHERE total.line_count < 2
       OR total.line_debit <= 0
       OR total.line_debit <> total.line_credit
       OR total.header_debit <> total.line_debit
       OR total.header_credit <> total.line_credit

    UNION ALL

    SELECT
        'company_trial_balance_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM company_trial_balance balance
    WHERE balance.debit_total <> balance.credit_total

    UNION ALL

    SELECT
        'posted_line_tenant_dimension_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.finance_journal_lines line
    JOIN public.finance_journals journal
      ON journal.company_id = line.company_id
     AND journal.id = line.journal_id
     AND journal.status = 'POSTED'
    LEFT JOIN public.chart_of_accounts account
      ON account.company_id = line.company_id AND account.id = line.account_id
    LEFT JOIN public.stores store
      ON store.company_id = line.company_id AND store.id = line.store_id
    LEFT JOIN public.warehouses warehouse
      ON warehouse.company_id = line.company_id
     AND warehouse.id = line.warehouse_id
    LEFT JOIN public.customers customer
      ON customer.company_id = line.company_id
     AND customer.id = line.customer_id
    LEFT JOIN public.suppliers supplier
      ON supplier.company_id = line.company_id
     AND supplier.id = line.supplier_id
    WHERE account.id IS NULL
       OR (line.store_id IS NOT NULL AND store.id IS NULL)
       OR (line.warehouse_id IS NOT NULL AND warehouse.id IS NULL)
       OR (line.customer_id IS NOT NULL AND customer.id IS NULL)
       OR (line.supplier_id IS NOT NULL AND supplier.id IS NULL)

    UNION ALL

    SELECT
        'accounting_period_overlap',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('overlap_pairs',count(*))
    FROM public.accounting_periods left_period
    JOIN public.accounting_periods right_period
      ON right_period.company_id = left_period.company_id
     AND right_period.id > left_period.id
     AND daterange(
         left_period.start_date,left_period.end_date,'[]'
     ) && daterange(
         right_period.start_date,right_period.end_date,'[]'
     )

    UNION ALL

    SELECT
        'posted_journal_period_date_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('journal_count',count(*))
    FROM public.finance_journals journal
    JOIN public.accounting_periods period
      ON period.company_id = journal.company_id
     AND period.id = journal.accounting_period_id
    WHERE journal.status = 'POSTED'
      AND journal.accounting_date NOT BETWEEN period.start_date AND period.end_date

    UNION ALL

    SELECT
        'active_posting_queue_integrity',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('company_count',count(*))
    FROM (
        SELECT company_id
        FROM public.finance_posting_queue_runs
        WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')
        GROUP BY company_id
        HAVING count(*) > 1
    ) duplicate_active

    UNION ALL

    SELECT
        'supported_historical_hold_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'event_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.financial_events event
    WHERE event.status::TEXT = 'HOLD'
      AND event.system_event_key = 'STOCK_OPENING'
      AND event.event_type::TEXT = 'STOCK_OPENING'
      AND event.source_table = 'opening_stock_documents'

    UNION ALL

    SELECT
        'unsupported_financial_event_scope',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'DEFERRED' END,
        jsonb_build_object(
            'event_count',count(*),
            'event_contracts',count(DISTINCT (
                system_event_key,event_type::TEXT,source_table
            ))
        )
    FROM public.financial_events event
    WHERE event.status::TEXT = 'HOLD'
      AND NOT (
          event.system_event_key = 'STOCK_OPENING'
          AND event.event_type::TEXT = 'STOCK_OPENING'
          AND event.source_table = 'opening_stock_documents'
      )

    UNION ALL

    SELECT
        'stock_fifo_gl_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'company_count',count(*),
            'fifo_value',COALESCE(sum(fifo_value),0),
            'inventory_gl_value',COALESCE(sum(inventory_gl_value),0),
            'absolute_difference',COALESCE(sum(abs(difference)),0)
        )
    FROM stock_reconciliation
    WHERE abs(difference) > 0.0001

    UNION ALL

    SELECT
        'supplier_ap_gl_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'company_count',count(*),
            'open_ap_amount',COALESCE(sum(open_ap_amount),0),
            'ap_gl_amount',COALESCE(sum(ap_gl_amount),0),
            'absolute_difference',COALESCE(sum(abs(difference)),0)
        )
    FROM ap_reconciliation
    WHERE abs(difference) > 0.0001

    UNION ALL

    SELECT
        'customer_balance_gl_reconciliation',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BACKFILL' END,
        jsonb_build_object(
            'company_count',count(*),
            'customer_balance_amount',
                COALESCE(sum(customer_balance_amount),0),
            'customer_balance_gl_amount',
                COALESCE(sum(customer_balance_gl_amount),0),
            'absolute_difference',COALESCE(sum(abs(difference)),0)
        )
    FROM customer_balance_reconciliation
    WHERE abs(difference) > 0.0001

    UNION ALL

    SELECT
        'invalid_fifo_valuation_shape',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'BLOCKER' END,
        jsonb_build_object('row_count',count(*))
    FROM public.product_batches batch
    WHERE batch.qty_remaining < 0 OR batch.cogs_unit < 0

    UNION ALL

    SELECT
        'report_fixture_readiness',
        CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'SETUP' END,
        jsonb_build_object(
            'posted_journals',count(*),
            'posted_lines',COALESCE(sum(line_count),0),
            'companies',count(DISTINCT company_id)
        )
    FROM posted_journal_totals

    UNION ALL

    SELECT
        'prior_period_adjustment_inventory',
        'INFO',
        jsonb_build_object(
            'journal_count',count(*),
            'companies',count(DISTINCT company_id)
        )
    FROM public.finance_journals
    WHERE status = 'POSTED'
      AND journal_type = 'PRIOR_PERIOD_ADJUSTMENT'

    UNION ALL

    SELECT
        'operational_pending_inventory',
        'INFO',
        jsonb_build_object(
            'hold_events',count(*) FILTER (WHERE status::TEXT = 'HOLD'),
            'failed_events',count(*) FILTER (WHERE status::TEXT = 'FAILED'),
            'posted_events',count(*) FILTER (WHERE status::TEXT = 'POSTED'),
            'companies',count(DISTINCT company_id)
        )
    FROM public.financial_events

    UNION ALL

    SELECT
        'finance_reporting_runtime_inventory',
        'INFO',
        jsonb_build_object(
            'active_companies',(
                SELECT count(*) FROM public.companies WHERE status = 'ACTIVE'
            ),
            'accounting_periods',(
                SELECT count(*) FROM public.accounting_periods
            ),
            'posted_journals',(
                SELECT count(*) FROM public.finance_journals
                WHERE status = 'POSTED'
            ),
            'posted_lines',(
                SELECT count(*)
                FROM public.finance_journal_lines line
                JOIN public.finance_journals journal
                  ON journal.company_id = line.company_id
                 AND journal.id = line.journal_id
                 AND journal.status = 'POSTED'
            ),
            'reconcilable_accounts',(
                SELECT count(*) FROM public.chart_of_accounts
                WHERE is_active AND allow_reconciliation
            ),
            'queue_runs',(
                SELECT count(*) FROM public.finance_posting_queue_runs
            ),
            'posting_exceptions',(
                SELECT count(*) FROM public.finance_posting_exceptions
                WHERE status <> 'RESOLVED'
            )
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
        WHEN 'DEFERRED' THEN 5
        WHEN 'PASS' THEN 6
        ELSE 7
    END,
    check_name;
