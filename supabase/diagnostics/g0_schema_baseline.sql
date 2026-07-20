-- G0 live-schema baseline for KGS POS.
--
-- SAFETY:
-- - This script only reads persistent database objects/data.
-- - It writes only into a session-local TEMP table in pg_temp.
-- - The TEMP table disappears automatically when the SQL Editor session ends.
-- - It does not expose application rows, email addresses, secrets, or tokens.
-- - Run the whole file in Supabase SQL Editor and export only the final result.

-- Supabase SQL Editor may commit between statements. Do not use ON COMMIT DROP:
-- it can remove the TEMP table before the following diagnostic statements run.
DROP TABLE IF EXISTS pg_temp.g0_baseline_report;

CREATE TEMP TABLE g0_baseline_report (
    section TEXT NOT NULL,
    check_name TEXT NOT NULL,
    status TEXT NOT NULL,
    details JSONB NOT NULL DEFAULT '{}'::jsonb
);

INSERT INTO g0_baseline_report (section, check_name, status, details)
VALUES (
    'environment',
    'database_context',
    'INFO',
    jsonb_build_object(
        'database', current_database(),
        'database_user', current_user,
        'server_version', current_setting('server_version'),
        'captured_at', clock_timestamp()
    )
);

-- Supabase migration registry. The exact columns differ between CLI versions,
-- so the query is selected from catalog evidence rather than assumed.
DO $g0$
DECLARE
    v_has_version BOOLEAN;
    v_has_name BOOLEAN;
BEGIN
    IF to_regclass('supabase_migrations.schema_migrations') IS NULL THEN
        INSERT INTO g0_baseline_report
        VALUES (
            'migration',
            'supabase_migrations.schema_migrations',
            'MISSING',
            jsonb_build_object('message', 'Migration registry table was not found')
        );
        RETURN;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'supabase_migrations'
          AND table_name = 'schema_migrations'
          AND column_name = 'version'
    ) INTO v_has_version;

    SELECT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'supabase_migrations'
          AND table_name = 'schema_migrations'
          AND column_name = 'name'
    ) INTO v_has_name;

    IF v_has_version AND v_has_name THEN
        EXECUTE $sql$
            INSERT INTO g0_baseline_report
            SELECT
                'migration',
                'applied_versions',
                'INFO',
                jsonb_build_object(
                    'count', count(*),
                    'items', COALESCE(
                        jsonb_agg(
                            jsonb_build_object(
                                'version', version::text,
                                'name', name::text
                            )
                            ORDER BY version
                        ),
                        '[]'::jsonb
                    )
                )
            FROM supabase_migrations.schema_migrations
        $sql$;
    ELSIF v_has_version THEN
        EXECUTE $sql$
            INSERT INTO g0_baseline_report
            SELECT
                'migration',
                'applied_versions',
                'INFO',
                jsonb_build_object(
                    'count', count(*),
                    'items', COALESCE(
                        jsonb_agg(version::text ORDER BY version),
                        '[]'::jsonb
                    )
                )
            FROM supabase_migrations.schema_migrations
        $sql$;
    ELSE
        INSERT INTO g0_baseline_report
        VALUES (
            'migration',
            'applied_versions',
            'WARN',
            jsonb_build_object('message', 'Registry exists but has no version column')
        );
    END IF;
END
$g0$;

-- Expected tables from the current repository. Missing tables are evidence of
-- applied-state drift; this script does not attempt to create them.
WITH expected(table_name) AS (
    VALUES
        ('profiles'),
        ('companies'),
        ('stores'),
        ('pos_terminals'),
        ('company_memberships'),
        ('store_memberships'),
        ('warehouses'),
        ('products'),
        ('product_bundle_items'),
        ('product_stocks'),
        ('customers'),
        ('cashier_sessions'),
        ('sales_headers'),
        ('sales_details'),
        ('sales_payments'),
        ('purchases_headers'),
        ('purchases_details'),
        ('cash_advances'),
        ('bank_deposits'),
        ('financial_events'),
        ('journal_entries'),
        ('pos_reconciliations'),
        ('uoms'),
        ('product_uom_conversions'),
        ('product_batches'),
        ('sales_fifo_allocations'),
        ('stock_opnames'),
        ('stock_opname_details'),
        ('stock_adjustments'),
        ('stock_movements'),
        ('customer_pricelists')
)
INSERT INTO g0_baseline_report (section, check_name, status, details)
SELECT
    'schema',
    'table:' || expected.table_name,
    CASE WHEN c.oid IS NULL THEN 'MISSING' ELSE 'PASS' END,
    CASE
        WHEN c.oid IS NULL THEN jsonb_build_object('schema', 'public')
        ELSE jsonb_build_object(
            'schema', n.nspname,
            'rls_enabled', c.relrowsecurity,
            'rls_forced', c.relforcerowsecurity
        )
    END
FROM expected
LEFT JOIN pg_namespace n ON n.nspname = 'public'
LEFT JOIN pg_class c
    ON c.relnamespace = n.oid
   AND c.relname = expected.table_name
   AND c.relkind IN ('r', 'p')
ORDER BY expected.table_name;

-- Tenant-column coverage and NULL data checks.
DO $g0$
DECLARE
    r RECORD;
    v_nullable TEXT;
    v_null_count BIGINT;
BEGIN
    FOR r IN
        SELECT *
        FROM (VALUES
            ('stores'),
            ('pos_terminals'),
            ('company_memberships'),
            ('store_memberships'),
            ('warehouses'),
            ('products'),
            ('product_bundle_items'),
            ('product_stocks'),
            ('customers'),
            ('cashier_sessions'),
            ('sales_headers'),
            ('sales_details'),
            ('sales_payments'),
            ('purchases_headers'),
            ('purchases_details'),
            ('cash_advances'),
            ('bank_deposits'),
            ('financial_events'),
            ('journal_entries'),
            ('pos_reconciliations'),
            ('uoms'),
            ('product_uom_conversions'),
            ('product_batches'),
            ('sales_fifo_allocations'),
            ('stock_opnames'),
            ('stock_opname_details'),
            ('stock_adjustments'),
            ('stock_movements'),
            ('customer_pricelists')
        ) AS expected(table_name)
    LOOP
        IF to_regclass(format('public.%I', r.table_name)) IS NULL THEN
            CONTINUE;
        END IF;

        SELECT is_nullable
        INTO v_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = r.table_name
          AND column_name = 'company_id';

        IF v_nullable IS NULL THEN
            INSERT INTO g0_baseline_report
            VALUES (
                'tenant',
                'company_id:' || r.table_name,
                'MISSING',
                jsonb_build_object('message', 'company_id column not found')
            );
            CONTINUE;
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM public.%I WHERE company_id IS NULL',
            r.table_name
        ) INTO v_null_count;

        INSERT INTO g0_baseline_report
        VALUES (
            'tenant',
            'company_id:' || r.table_name,
            CASE
                WHEN v_null_count > 0 THEN 'FAIL'
                WHEN v_nullable = 'YES' THEN 'WARN'
                ELSE 'PASS'
            END,
            jsonb_build_object(
                'nullable', v_nullable = 'YES',
                'null_rows', v_null_count
            )
        );
    END LOOP;
END
$g0$;

-- Policy coverage. A policy count of zero on an RLS table is reported as FAIL;
-- it may be intentional only if the table is service-role-only and documented.
WITH expected(table_name) AS (
    VALUES
        ('profiles'), ('companies'), ('stores'), ('pos_terminals'),
        ('company_memberships'), ('store_memberships'), ('warehouses'),
        ('products'), ('product_bundle_items'), ('product_stocks'),
        ('customers'), ('cashier_sessions'), ('sales_headers'),
        ('sales_details'), ('sales_payments'), ('purchases_headers'),
        ('purchases_details'), ('cash_advances'), ('bank_deposits'),
        ('financial_events'), ('journal_entries'), ('pos_reconciliations'),
        ('uoms'), ('product_uom_conversions'), ('product_batches'),
        ('sales_fifo_allocations'), ('stock_opnames'),
        ('stock_opname_details'), ('stock_adjustments'), ('stock_movements'),
        ('customer_pricelists')
), policy_counts AS (
    SELECT tablename, count(*) AS policy_count
    FROM pg_policies
    WHERE schemaname = 'public'
    GROUP BY tablename
)
INSERT INTO g0_baseline_report (section, check_name, status, details)
SELECT
    'security',
    'policies:' || e.table_name,
    CASE
        WHEN c.oid IS NULL THEN 'SKIP'
        WHEN NOT c.relrowsecurity THEN 'FAIL'
        WHEN COALESCE(pc.policy_count, 0) = 0 THEN 'FAIL'
        ELSE 'PASS'
    END,
    jsonb_build_object(
        'table_exists', c.oid IS NOT NULL,
        'rls_enabled', COALESCE(c.relrowsecurity, false),
        'policy_count', COALESCE(pc.policy_count, 0)
    )
FROM expected e
LEFT JOIN pg_namespace n ON n.nspname = 'public'
LEFT JOIN pg_class c
    ON c.relnamespace = n.oid
   AND c.relname = e.table_name
   AND c.relkind IN ('r', 'p')
LEFT JOIN policy_counts pc ON pc.tablename = e.table_name
ORDER BY e.table_name;

-- Security posture of key functions. Function overloads are reported
-- separately through their identity arguments.
WITH expected(function_name) AS (
    VALUES
        ('private_is_super_admin'),
        ('private_user_has_company_access'),
        ('private_user_has_store_access'),
        ('get_user_role_in_company'),
        ('handle_new_user'),
        ('import_products_for_company'),
        ('create_sales_transaction'),
        ('transfer_product_stock'),
        ('confirm_purchase_order'),
        ('process_financial_events_queue')
), functions AS (
    SELECT
        p.proname,
        pg_get_function_identity_arguments(p.oid) AS identity_arguments,
        p.prosecdef,
        p.proconfig,
        has_function_privilege('public', p.oid, 'EXECUTE') AS public_can_execute
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
)
INSERT INTO g0_baseline_report (section, check_name, status, details)
SELECT
    'security',
    'function:' || e.function_name || COALESCE('(' || f.identity_arguments || ')', ''),
    CASE
        WHEN f.proname IS NULL THEN 'MISSING'
        WHEN f.prosecdef
             AND NOT COALESCE(f.proconfig, ARRAY[]::text[])::text[]
                     @> ARRAY['search_path=public, pg_temp']::text[] THEN 'WARN'
        WHEN f.public_can_execute THEN 'WARN'
        ELSE 'PASS'
    END,
    jsonb_build_object(
        'exists', f.proname IS NOT NULL,
        'security_definer', COALESCE(f.prosecdef, false),
        'config', COALESCE(to_jsonb(f.proconfig), '[]'::jsonb),
        'public_can_execute', COALESCE(f.public_can_execute, false)
    )
FROM expected e
LEFT JOIN functions f ON f.proname = e.function_name
ORDER BY e.function_name, f.identity_arguments;

-- Trigger inventory for persistent public tables.
INSERT INTO g0_baseline_report (section, check_name, status, details)
SELECT
    'schema',
    'trigger:' || event_object_table || '.' || trigger_name,
    'INFO',
    jsonb_build_object(
        'timing', action_timing,
        'event', event_manipulation,
        'statement', action_statement
    )
FROM information_schema.triggers
WHERE trigger_schema = 'public'
ORDER BY event_object_table, trigger_name, event_manipulation;

-- Data-quality checks use dynamic SQL only after required objects are proven to
-- exist. They return counts, never business-row contents.
DO $g0$
DECLARE
    v_count BIGINT;
BEGIN
    IF to_regclass('public.product_stocks') IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'product_stocks'
             AND column_name = 'stock_qty'
       ) THEN
        EXECUTE 'SELECT count(*) FROM public.product_stocks WHERE stock_qty < 0'
        INTO v_count;
        INSERT INTO g0_baseline_report
        VALUES (
            'data_quality',
            'negative_product_stock',
            CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
            jsonb_build_object('row_count', v_count)
        );
    END IF;

    IF to_regclass('public.product_stocks') IS NOT NULL
       AND to_regclass('public.products') IS NOT NULL
       AND to_regclass('public.warehouses') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM (VALUES
               ('product_stocks', 'company_id'),
               ('product_stocks', 'product_id'),
               ('product_stocks', 'warehouse_id'),
               ('products', 'company_id'),
               ('products', 'id'),
               ('warehouses', 'company_id'),
               ('warehouses', 'id')
           ) AS required(table_name, column_name)
           WHERE NOT EXISTS (
               SELECT 1
               FROM information_schema.columns c
               WHERE c.table_schema = 'public'
                 AND c.table_name = required.table_name
                 AND c.column_name = required.column_name
           )
       ) THEN
        EXECUTE $sql$
            SELECT count(*)
            FROM public.product_stocks ps
            JOIN public.products p ON p.id = ps.product_id
            JOIN public.warehouses w ON w.id = ps.warehouse_id
            WHERE ps.company_id IS DISTINCT FROM p.company_id
               OR ps.company_id IS DISTINCT FROM w.company_id
        $sql$ INTO v_count;
        INSERT INTO g0_baseline_report
        VALUES (
            'data_quality',
            'tenant_mismatch:product_stocks',
            CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
            jsonb_build_object('row_count', v_count)
        );
    END IF;

    IF to_regclass('public.sales_details') IS NOT NULL
       AND to_regclass('public.sales_headers') IS NOT NULL
       AND to_regclass('public.products') IS NOT NULL
       AND to_regclass('public.warehouses') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM (VALUES
               ('sales_details', 'company_id'),
               ('sales_details', 'sales_id'),
               ('sales_details', 'product_id'),
               ('sales_details', 'warehouse_id'),
               ('sales_headers', 'company_id'),
               ('sales_headers', 'id'),
               ('products', 'company_id'),
               ('products', 'id'),
               ('warehouses', 'company_id'),
               ('warehouses', 'id')
           ) AS required(table_name, column_name)
           WHERE NOT EXISTS (
               SELECT 1
               FROM information_schema.columns c
               WHERE c.table_schema = 'public'
                 AND c.table_name = required.table_name
                 AND c.column_name = required.column_name
           )
       ) THEN
        EXECUTE $sql$
            SELECT count(*)
            FROM public.sales_details d
            JOIN public.sales_headers h ON h.id = d.sales_id
            JOIN public.products p ON p.id = d.product_id
            JOIN public.warehouses w ON w.id = d.warehouse_id
            WHERE d.company_id IS DISTINCT FROM h.company_id
               OR d.company_id IS DISTINCT FROM p.company_id
               OR d.company_id IS DISTINCT FROM w.company_id
        $sql$ INTO v_count;
        INSERT INTO g0_baseline_report
        VALUES (
            'data_quality',
            'tenant_mismatch:sales_details',
            CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
            jsonb_build_object('row_count', v_count)
        );
    END IF;

    IF to_regclass('public.purchases_details') IS NOT NULL
       AND to_regclass('public.purchases_headers') IS NOT NULL
       AND to_regclass('public.products') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM (VALUES
               ('purchases_details', 'company_id'),
               ('purchases_details', 'purchase_id'),
               ('purchases_details', 'product_id'),
               ('purchases_headers', 'company_id'),
               ('purchases_headers', 'id'),
               ('products', 'company_id'),
               ('products', 'id')
           ) AS required(table_name, column_name)
           WHERE NOT EXISTS (
               SELECT 1
               FROM information_schema.columns c
               WHERE c.table_schema = 'public'
                 AND c.table_name = required.table_name
                 AND c.column_name = required.column_name
           )
       ) THEN
        EXECUTE $sql$
            SELECT count(*)
            FROM public.purchases_details d
            JOIN public.purchases_headers h ON h.id = d.purchase_id
            JOIN public.products p ON p.id = d.product_id
            WHERE d.company_id IS DISTINCT FROM h.company_id
               OR d.company_id IS DISTINCT FROM p.company_id
        $sql$ INTO v_count;
        INSERT INTO g0_baseline_report
        VALUES (
            'data_quality',
            'tenant_mismatch:purchases_details',
            CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
            jsonb_build_object('row_count', v_count)
        );
    END IF;

    IF to_regclass('public.journal_entries') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1
           FROM (VALUES
               ('company_id'),
               ('entry_group_id'),
               ('debit'),
               ('kredit')
           ) AS required(column_name)
           WHERE NOT EXISTS (
               SELECT 1
               FROM information_schema.columns c
               WHERE c.table_schema = 'public'
                 AND c.table_name = 'journal_entries'
                 AND c.column_name = required.column_name
           )
       ) THEN
        EXECUTE $sql$
            SELECT count(*)
            FROM (
                SELECT company_id, entry_group_id
                FROM public.journal_entries
                GROUP BY company_id, entry_group_id
                HAVING COALESCE(sum(debit), 0) <> COALESCE(sum(kredit), 0)
            ) unbalanced
        $sql$ INTO v_count;
        INSERT INTO g0_baseline_report
        VALUES (
            'data_quality',
            'unbalanced_journal_groups',
            CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
            jsonb_build_object('group_count', v_count)
        );
    END IF;
END
$g0$;

-- Detect duplicate tenant-scoped business identifiers before unique constraints
-- are introduced or repaired.
DO $g0$
DECLARE
    r RECORD;
    v_count BIGINT;
BEGIN
    FOR r IN
        SELECT *
        FROM (VALUES
            ('products', 'sku'),
            ('warehouses', 'code'),
            ('customers', 'code'),
            ('uoms', 'code')
        ) AS expected(table_name, key_column)
    LOOP
        IF to_regclass(format('public.%I', r.table_name)) IS NULL
           OR NOT EXISTS (
               SELECT 1
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = r.table_name
                 AND column_name = 'company_id'
           )
           OR NOT EXISTS (
               SELECT 1
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = r.table_name
                 AND column_name = r.key_column
           ) THEN
            CONTINUE;
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM (' ||
            'SELECT company_id, %I FROM public.%I ' ||
            'GROUP BY company_id, %I HAVING count(*) > 1' ||
            ') duplicates',
            r.key_column,
            r.table_name,
            r.key_column
        ) INTO v_count;

        INSERT INTO g0_baseline_report
        VALUES (
            'data_quality',
            'duplicate_tenant_key:' || r.table_name || '.' || r.key_column,
            CASE WHEN v_count = 0 THEN 'PASS' ELSE 'FAIL' END,
            jsonb_build_object('duplicate_group_count', v_count)
        );
    END LOOP;
END
$g0$;

-- Compact summary plus detailed rows. Sort order puts actionable results first.
SELECT
    section,
    check_name,
    status,
    details
FROM g0_baseline_report
ORDER BY
    CASE status
        WHEN 'FAIL' THEN 1
        WHEN 'MISSING' THEN 2
        WHEN 'WARN' THEN 3
        WHEN 'SKIP' THEN 4
        WHEN 'PASS' THEN 5
        ELSE 6
    END,
    section,
    check_name;

-- No persistent cleanup is required. g0_baseline_report lives only in pg_temp
-- and is removed automatically when the SQL Editor database session closes.
