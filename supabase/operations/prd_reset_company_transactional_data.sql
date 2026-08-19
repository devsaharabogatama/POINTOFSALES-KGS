-- PRD controlled operation: reset transactional/test data for ONE Company.
--
-- This is intentionally NOT a migration. Run it manually from Supabase SQL
-- Editor during a maintenance window, using the postgres/database-owner role.
-- Default mode is PREVIEW and performs no persistent data mutation.
--
-- SAFETY CONTRACT
--   1. Scope is one exact Company UUID + exact Company name.
--   2. Execution additionally requires the exact confirmation phrase.
--   3. Unknown company-scoped tables block execution (schema drift guard).
--   4. Master/config/user tables and private document counters are preserved.
--   5. The operation is one transaction: any error rolls everything back.

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '0';

CREATE TEMP TABLE kgs_company_transaction_reset_config (
    company_id UUID,
    expected_company_name TEXT,
    execute_reset BOOLEAN NOT NULL DEFAULT FALSE,
    confirmation_phrase TEXT NOT NULL DEFAULT ''
) ON COMMIT DROP;

-- EDIT ONLY THIS ROW.
-- First run: keep execute_reset = FALSE to preview.
-- Final run: set execute_reset = TRUE and use the exact confirmation phrase.
INSERT INTO kgs_company_transaction_reset_config (
    company_id,
    expected_company_name,
    execute_reset,
    confirmation_phrase
) VALUES (
    NULL, -- replace with: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'::UUID
    'REPLACE_WITH_EXACT_COMPANY_NAME',
    FALSE,
    '' -- required for execution: I_UNDERSTAND_THIS_DELETES_TRANSACTION_DATA
);

CREATE TEMP TABLE kgs_reset_targets (
    table_name TEXT PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO kgs_reset_targets(table_name) VALUES
    -- POS, session, Sale, payment, fulfillment, and Return runtime
    ('cashier_session_audit'),
    ('cashier_session_stock_snapshots'),
    ('cashier_sessions'),
    ('pos_reconciliations'),
    ('sale_master_audit'),
    ('sale_stock_requirements'),
    ('sale_fifo_allocations'),
    ('sales_fifo_allocations'),
    ('bundle_sale_allocations'),
    ('sales_document_audit'),
    ('sales_delivery_lines'),
    ('sales_delivery_documents'),
    ('sales_invoice_snapshots'),
    ('sales_return_audit'),
    ('sales_return_fifo_restorations'),
    ('sales_return_refunds'),
    ('sales_return_lines'),
    ('sales_return_documents'),
    ('sales_payments'),
    ('sales_details'),
    ('sales_headers'),

    -- Offline POS and negative-stock operational runtime
    ('offline_payment_exceptions'),
    ('pos_offline_sale_allowance_consumptions'),
    ('pos_offline_sale_submission_events'),
    ('pos_offline_sync_exceptions'),
    ('pos_offline_sale_submissions'),
    ('pos_offline_stock_allowance_audit'),
    ('pos_offline_stock_allowances'),
    ('negative_stock_replenishment_allocations'),
    ('negative_stock_sale_allocations'),
    ('pos_negative_stock_authorizations'),

    -- Inventory balances, FIFO, Movement, and operational documents
    ('stock_opname_audit'),
    ('stock_opname_count_attempts'),
    ('stock_opname_details'),
    ('stock_opnames'),
    ('stock_adjustment_audit'),
    ('stock_adjustment_fifo_allocations'),
    ('stock_adjustment_lines'),
    ('stock_adjustment_documents'),
    ('stock_adjustments'),
    ('stock_transfer_audit'),
    ('stock_transfer_fifo_allocations'),
    ('stock_transfer_lines'),
    ('stock_transfer_documents'),
    ('opening_stock_audit'),
    ('opening_stock_lines'),
    ('opening_stock_documents'),
    ('stock_movements'),
    ('product_batches'),
    ('product_stocks'),

    -- Purchase, receipt, Return, AP Invoice, and Supplier Payment runtime
    ('stock_request_audit'),
    ('supplier_order_audit'),
    ('supplier_order_request_allocations'),
    ('supplier_order_lines'),
    ('supplier_order_documents'),
    ('stock_request_lines'),
    ('stock_request_documents'),
    ('goods_receipt_audit'),
    ('goods_receipt_ap_provisionals'),
    ('goods_receipt_condition_allocations'),
    ('goods_receipt_lines'),
    ('goods_receipt_documents'),
    ('purchase_return_audit'),
    ('purchase_return_ap_adjustments'),
    ('purchase_return_fifo_allocations'),
    ('purchase_return_lines'),
    ('purchase_return_documents'),
    ('supplier_invoice_audit'),
    ('supplier_invoice_tolerance_results'),
    ('supplier_invoice_allocations'),
    ('supplier_invoice_lines'),
    ('supplier_invoice_documents'),
    ('supplier_payment_audit'),
    ('supplier_payment_allocations'),
    ('supplier_payment_documents'),
    ('purchases_details'),
    ('purchases_headers'),

    -- Expense, drawer, deposit, and variance runtime
    ('expense_audit'),
    ('expense_additional_disbursement_requests'),
    ('expense_settlement_requests'),
    ('expense_returns'),
    ('expense_settlements'),
    ('expense_disbursements'),
    ('expense_documents'),
    ('cash_in_documents'),
    ('cash_drawer_movements'),
    ('cash_deposit_audit'),
    ('cash_deposit_session_lines'),
    ('deposit_variance_resolution_audit'),
    ('deposit_variance_allocations'),
    ('deposit_variance_resolution_requests'),
    ('deposit_variance_exceptions'),
    ('cash_deposit_documents'),
    ('cash_advances'),
    ('bank_deposits'),

    -- Customer Balance operational ledger and approvals
    ('customer_balance_audit'),
    ('customer_balance_ledger_entries'),
    ('customer_balance_correction_requests'),

    -- Finance final effects, queue, exception, reconciliation, and exports
    ('finance_posting_queue_audit'),
    ('finance_posting_queue_items'),
    ('finance_posting_queue_runs'),
    ('finance_posting_exceptions'),
    ('finance_reconciliation_audit'),
    ('finance_reconciliation_allocations'),
    ('finance_reconciliation_documents'),
    ('finance_report_exports'),
    ('finance_journal_audit'),
    ('finance_journal_lines'),
    ('finance_journals'),
    ('journal_lines'),
    ('journal_entries'),
    ('financial_events');

-- Explicit preservation inventory. This is also a fail-closed schema-drift
-- guard: a new company-scoped table must be intentionally classified before
-- execution is allowed.
CREATE TEMP TABLE kgs_reset_preserved (
    table_name TEXT PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO kgs_reset_preserved(table_name) VALUES
    ('companies'),
    ('profiles'),
    ('company_memberships'),
    ('store_memberships'),
    ('user_active_company_contexts'),
    ('user_active_company_context_audit'),
    ('user_company_assignment_audit'),
    ('access_permission_catalog'),
    ('user_company_permission_overrides'),
    ('user_company_permission_audit'),
    ('stores'),
    ('pos_terminals'),
    ('warehouses'),
    ('uoms'),
    ('product_categories'),
    ('products'),
    ('product_uoms'),
    ('product_uom_conversions'),
    ('product_bundle_items'),
    ('product_bundle_master_audit'),
    ('product_master_audit'),
    ('inventory_master_write_audit'),
    ('product_warehouse_stock_settings'),
    ('product_warehouse_stock_setting_audit'),
    ('suppliers'),
    ('product_suppliers'),
    ('supplier_master_audit'),
    ('product_supplier_audit'),
    ('customer_categories'),
    ('customers'),
    ('customer_category_audit'),
    ('customer_master_audit'),
    ('pricelists'),
    ('pricelist_rules'),
    ('pricelist_store_assignments'),
    ('pricelist_master_audit'),
    ('payment_methods'),
    ('payment_method_store_assignments'),
    ('payment_method_master_audit'),
    ('tax_rules'),
    ('tax_rule_versions'),
    ('tax_master_audit'),
    ('tax_assignment_audit'),
    ('platform_features'),
    ('company_features'),
    ('company_feature_audit'),
    ('company_branding_profiles'),
    ('company_branding_audit'),
    ('account_functions'),
    ('system_events'),
    ('chart_of_accounts'),
    ('transaction_categories'),
    ('transaction_account_rules'),
    ('company_account_function_fallbacks'),
    ('finance_master_audit'),
    ('accounting_periods'),
    ('posting_rule_sets'),
    ('posting_rule_lines'),
    ('posting_rule_set_audit'),
    ('finance_report_definitions'),
    ('finance_report_versions'),
    ('finance_report_lines'),
    ('finance_report_audit'),
    ('stock_adjustment_reasons'),
    ('expense_categories'),
    ('expense_approval_policies'),
    ('cash_deposit_policies'),
    ('customer_balance_company_policies'),
    ('supplier_invoice_tolerance_policies'),
    ('pos_offline_allowance_policies'),
    ('pos_negative_stock_policies'),
    ('pos_negative_stock_permissions'),
    ('pos_negative_stock_configuration_audit'),
    ('master_import_jobs'),
    ('master_import_rows'),
    ('master_import_job_events');

CREATE TEMP TABLE kgs_reset_issues (
    issue_type TEXT NOT NULL,
    object_name TEXT NOT NULL,
    details TEXT NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE kgs_reset_result (
    operation TEXT NOT NULL,
    object_name TEXT NOT NULL,
    affected_rows BIGINT NOT NULL
) ON COMMIT DROP;

CREATE TEMP TABLE kgs_reset_trigger_state (
    table_name TEXT NOT NULL,
    trigger_name TEXT NOT NULL,
    trigger_enabled "char" NOT NULL,
    PRIMARY KEY(table_name, trigger_name)
) ON COMMIT DROP;

DO $validate$
DECLARE
    v_company UUID;
    v_expected_name TEXT;
    v_actual_name TEXT;
BEGIN
    SELECT company_id, expected_company_name
      INTO v_company, v_expected_name
    FROM kgs_company_transaction_reset_config;

    IF v_company IS NULL THEN
        RAISE EXCEPTION 'CONFIG_REQUIRED: fill company_id before running this script';
    END IF;

    SELECT company_name INTO v_actual_name
    FROM public.companies
    WHERE id = v_company;

    IF v_actual_name IS NULL THEN
        RAISE EXCEPTION 'TARGET_COMPANY_NOT_FOUND: %', v_company;
    END IF;

    IF btrim(COALESCE(v_expected_name, '')) <> btrim(v_actual_name) THEN
        RAISE EXCEPTION
            'TARGET_COMPANY_NAME_MISMATCH: expected "%", actual "%"',
            v_expected_name, v_actual_name;
    END IF;
END
$validate$;

-- Existing target tables must be tenant-scoped. An old/partial schema is not
-- guessed around because that could delete another Company's rows.
INSERT INTO kgs_reset_issues(issue_type, object_name, details)
SELECT
    'TARGET_WITHOUT_COMPANY_ID',
    target.table_name,
    'Existing reset target has no public.company_id column'
FROM kgs_reset_targets target
JOIN information_schema.tables relation
  ON relation.table_schema = 'public'
 AND relation.table_name = target.table_name
 AND relation.table_type = 'BASE TABLE'
WHERE NOT EXISTS (
    SELECT 1
    FROM information_schema.columns column_state
    WHERE column_state.table_schema = 'public'
      AND column_state.table_name = target.table_name
      AND column_state.column_name = 'company_id'
);

-- Any new company-scoped table which is neither DELETE nor PRESERVE is a hard
-- execution blocker until a human classifies it.
INSERT INTO kgs_reset_issues(issue_type, object_name, details)
SELECT
    'UNCLASSIFIED_COMPANY_TABLE',
    relation.table_name,
    'Classify this table as transactional DELETE or master/config PRESERVE'
FROM information_schema.tables relation
WHERE relation.table_schema = 'public'
  AND relation.table_type = 'BASE TABLE'
  AND EXISTS (
      SELECT 1
      FROM information_schema.columns column_state
      WHERE column_state.table_schema = relation.table_schema
        AND column_state.table_name = relation.table_name
        AND column_state.column_name = 'company_id'
  )
  AND NOT EXISTS (
      SELECT 1 FROM kgs_reset_targets target
      WHERE target.table_name = relation.table_name
  )
  AND NOT EXISTS (
      SELECT 1 FROM kgs_reset_preserved preserved
      WHERE preserved.table_name = relation.table_name
  );

-- Preview exact row counts using the same explicit target inventory.
DO $preview$
DECLARE
    v_company UUID;
    v_table RECORD;
    v_count BIGINT;
BEGIN
    SELECT company_id INTO v_company
    FROM kgs_company_transaction_reset_config;

    FOR v_table IN
        SELECT target.table_name
        FROM kgs_reset_targets target
        JOIN information_schema.tables relation
          ON relation.table_schema = 'public'
         AND relation.table_name = target.table_name
         AND relation.table_type = 'BASE TABLE'
        JOIN information_schema.columns tenant_column
          ON tenant_column.table_schema = relation.table_schema
         AND tenant_column.table_name = relation.table_name
         AND tenant_column.column_name = 'company_id'
        ORDER BY target.table_name
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM public.%I WHERE company_id = $1',
            v_table.table_name
        ) INTO v_count USING v_company;

        INSERT INTO kgs_reset_result(operation, object_name, affected_rows)
        VALUES ('PREVIEW_DELETE', v_table.table_name, v_count);
    END LOOP;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'customers'
          AND column_name = 'current_balance'
    ) THEN
        SELECT count(*) INTO v_count
        FROM public.customers
        WHERE company_id = v_company
          AND current_balance <> 0;
        INSERT INTO kgs_reset_result(operation, object_name, affected_rows)
        VALUES ('PREVIEW_RESET_DERIVED_CACHE', 'customers.current_balance', v_count);
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'product_suppliers'
          AND column_name = 'last_purchase_price'
    ) THEN
        SELECT count(*) INTO v_count
        FROM public.product_suppliers
        WHERE company_id = v_company
          AND (
              last_purchase_price IS NOT NULL
              OR last_price_updated_at IS NOT NULL
              OR last_price_source_document_id IS NOT NULL
          );
        INSERT INTO kgs_reset_result(operation, object_name, affected_rows)
        VALUES ('PREVIEW_RESET_DERIVED_CACHE', 'product_suppliers.last_purchase_price', v_count);
    END IF;
END
$preview$;

DO $execute$
DECLARE
    v_company UUID;
    v_execute BOOLEAN;
    v_confirmation TEXT;
    v_table RECORD;
    v_candidate RECORD;
    v_rows BIGINT;
    v_remaining_count INTEGER;
BEGIN
    SELECT company_id, execute_reset, confirmation_phrase
      INTO v_company, v_execute, v_confirmation
    FROM kgs_company_transaction_reset_config;

    IF NOT v_execute THEN
        RETURN;
    END IF;

    IF v_confirmation <> 'I_UNDERSTAND_THIS_DELETES_TRANSACTION_DATA' THEN
        RAISE EXCEPTION
            'CONFIRMATION_REQUIRED: use exact phrase I_UNDERSTAND_THIS_DELETES_TRANSACTION_DATA';
    END IF;

    IF EXISTS (SELECT 1 FROM kgs_reset_issues) THEN
        RAISE EXCEPTION 'RESET_BLOCKED_BY_SCHEMA_CLASSIFICATION: inspect kgs_reset_issues output in preview mode';
    END IF;

    -- One reset per Company at a time, plus a row lock on the tenant root.
    PERFORM pg_advisory_xact_lock(hashtextextended(
        'KGS_COMPANY_TRANSACTION_RESET:' || v_company::TEXT, 0
    ));
    PERFORM 1 FROM public.companies WHERE id = v_company FOR UPDATE;

    -- Preserve the exact pre-existing USER-trigger state. FK triggers are
    -- internal and deliberately remain enabled throughout the operation.
    INSERT INTO kgs_reset_trigger_state(
        table_name, trigger_name, trigger_enabled
    )
    SELECT relation.relname, trigger_state.tgname, trigger_state.tgenabled
    FROM pg_catalog.pg_trigger trigger_state
    JOIN pg_catalog.pg_class relation
      ON relation.oid = trigger_state.tgrelid
    JOIN pg_catalog.pg_namespace namespace_state
      ON namespace_state.oid = relation.relnamespace
    WHERE namespace_state.nspname = 'public'
      AND NOT trigger_state.tgisinternal
      AND (
          relation.relname IN ('customers', 'product_suppliers')
          OR EXISTS (
              SELECT 1 FROM kgs_reset_targets target
              WHERE target.table_name = relation.relname
          )
      );

    -- Lock every mutation target before the first write. A live application
    -- will make this fail on lock_timeout instead of racing the reset.
    FOR v_table IN
        SELECT target.table_name
        FROM kgs_reset_targets target
        JOIN pg_catalog.pg_class relation
          ON relation.relname = target.table_name
         AND relation.relkind IN ('r', 'p')
        JOIN pg_catalog.pg_namespace namespace_state
          ON namespace_state.oid = relation.relnamespace
         AND namespace_state.nspname = 'public'
        JOIN information_schema.columns tenant_column
          ON tenant_column.table_schema = 'public'
         AND tenant_column.table_name = target.table_name
         AND tenant_column.column_name = 'company_id'
        ORDER BY target.table_name
    LOOP
        EXECUTE format(
            'LOCK TABLE public.%I IN ACCESS EXCLUSIVE MODE',
            v_table.table_name
        );
    END LOOP;

    LOCK TABLE public.customers IN ACCESS EXCLUSIVE MODE;
    LOCK TABLE public.product_suppliers IN ACCESS EXCLUSIVE MODE;

    FOR v_table IN
        SELECT table_name, trigger_name
        FROM kgs_reset_trigger_state
        WHERE trigger_enabled <> 'D'
        ORDER BY table_name, trigger_name
    LOOP
        EXECUTE format(
            'ALTER TABLE public.%I DISABLE TRIGGER %I',
            v_table.table_name,
            v_table.trigger_name
        );
    END LOOP;

    -- Clear transaction-derived values stored on preserved master rows before
    -- deleting their source documents/ledgers.
    IF to_regclass('public.customers') IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'customers'
             AND column_name = 'current_balance'
       ) THEN
        UPDATE public.customers
        SET current_balance = 0
        WHERE company_id = v_company
          AND current_balance <> 0;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        INSERT INTO kgs_reset_result(operation, object_name, affected_rows)
        VALUES ('RESET_DERIVED_CACHE', 'customers.current_balance', v_rows);
    END IF;

    IF to_regclass('public.product_suppliers') IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'product_suppliers'
             AND column_name = 'last_purchase_price'
       ) THEN
        UPDATE public.product_suppliers
        SET last_purchase_price = NULL,
            last_price_updated_at = NULL,
            last_price_source_document_id = NULL
        WHERE company_id = v_company
          AND (
              last_purchase_price IS NOT NULL
              OR last_price_updated_at IS NOT NULL
              OR last_price_source_document_id IS NOT NULL
          );
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        INSERT INTO kgs_reset_result(operation, object_name, affected_rows)
        VALUES ('RESET_DERIVED_CACHE', 'product_suppliers.last_purchase_price', v_rows);
    END IF;

    CREATE TEMP TABLE kgs_reset_remaining (
        table_oid OID PRIMARY KEY,
        table_name TEXT NOT NULL UNIQUE
    ) ON COMMIT DROP;

    INSERT INTO kgs_reset_remaining(table_oid, table_name)
    SELECT relation.oid, target.table_name
    FROM kgs_reset_targets target
    JOIN pg_catalog.pg_class relation
      ON relation.relname = target.table_name
     AND relation.relkind IN ('r', 'p')
    JOIN pg_catalog.pg_namespace namespace_state
      ON namespace_state.oid = relation.relnamespace
     AND namespace_state.nspname = 'public'
    JOIN information_schema.columns tenant_column
      ON tenant_column.table_schema = 'public'
     AND tenant_column.table_name = target.table_name
     AND tenant_column.column_name = 'company_id';

    LOOP
        SELECT count(*) INTO v_remaining_count FROM kgs_reset_remaining;
        EXIT WHEN v_remaining_count = 0;

        SELECT remaining.table_oid, remaining.table_name
          INTO v_candidate
        FROM kgs_reset_remaining remaining
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_constraint foreign_key
            JOIN kgs_reset_remaining child
              ON child.table_oid = foreign_key.conrelid
            WHERE foreign_key.contype = 'f'
              AND foreign_key.confrelid = remaining.table_oid
              AND foreign_key.conrelid <> foreign_key.confrelid
        )
        ORDER BY remaining.table_name
        LIMIT 1;

        IF v_candidate.table_oid IS NULL THEN
            RAISE EXCEPTION
                'RESET_BLOCKED_BY_FOREIGN_KEY_CYCLE: remaining tables=%',
                (SELECT string_agg(table_name, ', ' ORDER BY table_name)
                 FROM kgs_reset_remaining);
        END IF;

        EXECUTE format(
            'DELETE FROM public.%I WHERE company_id = $1',
            v_candidate.table_name
        ) USING v_company;
        GET DIAGNOSTICS v_rows = ROW_COUNT;

        INSERT INTO kgs_reset_result(operation, object_name, affected_rows)
        VALUES ('DELETE', v_candidate.table_name, v_rows);

        DELETE FROM kgs_reset_remaining
        WHERE table_oid = v_candidate.table_oid;
    END LOOP;

    -- Restore exactly the prior state; do not accidentally enable a trigger
    -- which was disabled before this operation.
    FOR v_table IN
        SELECT table_name, trigger_name, trigger_enabled
        FROM kgs_reset_trigger_state
        WHERE trigger_enabled <> 'D'
        ORDER BY table_name, trigger_name
    LOOP
        IF v_table.trigger_enabled = 'A' THEN
            EXECUTE format(
                'ALTER TABLE public.%I ENABLE ALWAYS TRIGGER %I',
                v_table.table_name, v_table.trigger_name
            );
        ELSIF v_table.trigger_enabled = 'R' THEN
            EXECUTE format(
                'ALTER TABLE public.%I ENABLE REPLICA TRIGGER %I',
                v_table.table_name, v_table.trigger_name
            );
        ELSE
            EXECUTE format(
                'ALTER TABLE public.%I ENABLE TRIGGER %I',
                v_table.table_name, v_table.trigger_name
            );
        END IF;
    END LOOP;

    -- Exact postcondition: no scoped row may remain in any classified target.
    FOR v_table IN
        SELECT target.table_name
        FROM kgs_reset_targets target
        JOIN information_schema.tables relation
          ON relation.table_schema = 'public'
         AND relation.table_name = target.table_name
         AND relation.table_type = 'BASE TABLE'
        JOIN information_schema.columns tenant_column
          ON tenant_column.table_schema = relation.table_schema
         AND tenant_column.table_name = relation.table_name
         AND tenant_column.column_name = 'company_id'
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM public.%I WHERE company_id = $1',
            v_table.table_name
        ) INTO v_rows USING v_company;
        IF v_rows <> 0 THEN
            RAISE EXCEPTION 'RESET_POSTCONDITION_FAILED: %.% rows remain',
                v_table.table_name, v_rows;
        END IF;
    END LOOP;
END
$execute$;

-- Result set 1: target identity and current mode.
SELECT
    company.id AS company_id,
    company.company_code,
    company.company_name,
    CASE WHEN config.execute_reset THEN 'EXECUTED' ELSE 'PREVIEW_ONLY' END AS mode
FROM kgs_company_transaction_reset_config config
JOIN public.companies company ON company.id = config.company_id;

-- Result set 2: must be empty before execute_reset may be enabled.
SELECT issue_type, object_name, details
FROM kgs_reset_issues
ORDER BY issue_type, object_name;

-- Result set 3: preview counts or committed operation counts.
SELECT operation, object_name, affected_rows
FROM kgs_reset_result
WHERE (
    (SELECT execute_reset FROM kgs_company_transaction_reset_config)
    AND operation <> 'PREVIEW_DELETE'
    AND operation <> 'PREVIEW_RESET_DERIVED_CACHE'
) OR (
    NOT (SELECT execute_reset FROM kgs_company_transaction_reset_config)
    AND operation LIKE 'PREVIEW_%'
)
ORDER BY operation, object_name;

COMMIT;
