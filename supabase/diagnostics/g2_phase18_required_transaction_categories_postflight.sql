-- G2 phase 18 postflight: required default Transaction Categories.
-- Expected: 11 PASS rows with violation_rows = 0.

WITH expected_defaults(system_key) AS (
    VALUES
        ('SALE_POSTED'),('SALE_PAYMENT'),('SALES_RETURN'),
        ('CUSTOMER_CREDIT_NOTE'),('CUSTOMER_DEBIT_NOTE'),
        ('GOODS_RECEIPT'),('SUPPLIER_INVOICE'),('SUPPLIER_PAYMENT'),
        ('PURCHASE_RETURN'),('SUPPLIER_CREDIT_NOTE'),
        ('SUPPLIER_DEBIT_NOTE'),('STOCK_OPENING'),('STOCK_GAIN'),
        ('STOCK_LOSS'),('STOCK_TRANSFER'),('EXPENSE_DISBURSEMENT'),
        ('EXPENSE_SETTLEMENT'),('CASH_IN'),('CASH_DEPOSIT'),
        ('CASH_VARIANCE'),('CUSTOMER_BALANCE_RECEIPT'),
        ('CUSTOMER_BALANCE_USAGE'),('KETUL_CUSTOMER_INTAKE'),
        ('KETUL_VENDOR_RESULT'),('KETUL_VENDOR_PAYMENT'),('MANUAL_JOURNAL')
), active_companies AS (
    SELECT id FROM public.companies WHERE status = 'ACTIVE'
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        abs(count(*) - 1)::BIGINT AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260722180000'

    UNION ALL

    SELECT
        'required_default_column',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('column_rows',count(*))
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'transaction_categories'
      AND column_name = 'is_system_default'
      AND is_nullable = 'NO'

    UNION ALL

    SELECT
        'active_company_default_category_coverage',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('missing_rows',count(*))
    FROM active_companies c
    CROSS JOIN expected_defaults d
    WHERE NOT EXISTS (
        SELECT 1 FROM public.transaction_categories tc
        WHERE tc.company_id = c.id
          AND tc.system_key = d.system_key
          AND tc.is_system_default
          AND tc.is_active
    )

    UNION ALL

    SELECT
        'unexpected_required_default_system_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.transaction_categories tc
    WHERE tc.is_system_default
      AND NOT EXISTS (
          SELECT 1 FROM expected_defaults d WHERE d.system_key = tc.system_key
      )

    UNION ALL

    SELECT
        'inactive_required_default_category',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('row_count',count(*))
    FROM public.transaction_categories
    WHERE is_system_default AND NOT is_active

    UNION ALL

    SELECT
        'duplicate_company_default_system_event',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),jsonb_build_object('duplicate_groups',count(*))
    FROM (
        SELECT company_id,system_key
        FROM public.transaction_categories
        WHERE is_system_default
        GROUP BY company_id,system_key
        HAVING count(*) > 1
    ) duplicates

    UNION ALL

    SELECT
        'required_default_guard_constraint',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('constraint_rows',count(*))
    FROM pg_constraint
    WHERE conrelid = 'public.transaction_categories'::regclass
      AND conname = 'transaction_categories_required_default_active_check'
      AND convalidated

    UNION ALL

    SELECT
        'required_default_unique_index',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 1)::BIGINT,
        jsonb_build_object('index_rows',count(*))
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'transaction_categories'
      AND indexname = 'uq_transaction_categories_company_default_system'

    UNION ALL

    SELECT
        'required_default_triggers',
        CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 2)::BIGINT,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger
    WHERE tgrelid IN (
        'public.companies'::regclass,
        'public.transaction_categories'::regclass
    )
      AND NOT tgisinternal
      AND tgname IN (
        'g2_provision_required_transaction_categories',
        'g2_guard_required_transaction_category'
      )

    UNION ALL

    SELECT
        'required_default_private_routines',
        CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL' END,
        abs(count(*) - 3)::BIGINT,
        jsonb_build_object('routine_rows',count(*))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private'
      AND p.proname IN (
        'provision_g2_required_transaction_categories',
        'trg_g2_provision_required_transaction_categories',
        'trg_g2_guard_required_transaction_category'
      )
      AND COALESCE(p.proconfig,ARRAY[]::TEXT[])::TEXT[]
          @> ARRAY['search_path=public, pg_temp']::TEXT[]
      AND NOT has_function_privilege('authenticated',p.oid,'EXECUTE')

    UNION ALL

    SELECT
        'browser_category_write_boundary',
        CASE WHEN NOT has_table_privilege(
            'authenticated','public.transaction_categories',
            'INSERT,UPDATE,DELETE'
        ) THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN has_table_privilege(
            'authenticated','public.transaction_categories',
            'INSERT,UPDATE,DELETE'
        ) THEN 1 ELSE 0 END,
        jsonb_build_object(
            'direct_write',has_table_privilege(
                'authenticated','public.transaction_categories',
                'INSERT,UPDATE,DELETE'
            )
        )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE WHEN violation_rows > 0 THEN 1 ELSE 2 END,check_name;
