-- G6 phase 3 imported-COA ownership correction postflight.
-- SAFETY: SELECT-only; aggregate metadata only.

WITH canonical_seed(function_key,seed_code) AS (
    VALUES
        ('CASH_DRAWER','1110'),('MAIN_CASH','1120'),
        ('BANK','1130'),('PAYMENT_CLEARING','1140'),
        ('CASH_IN_TRANSIT','1150'),('INPUT_TAX','1160'),
        ('CUSTOMER_RECEIVABLE','1210'),
        ('OUTSTANDING_EXPENSE','1230'),
        ('CASH_SHORTAGE_CONTROL','1240'),
        ('SUPPLIER_REFUND_RECEIVABLE','1250'),
        ('SUPPLIER_ADVANCE','1260'),
        ('OFFLINE_PAYMENT_RECEIVABLE','1270'),
        ('UNDER_DEPOSIT_CONTROL','1280'),('INVENTORY_ASSET','1310'),
        ('SUPPLIER_AP_PROVISIONAL','2110'),
        ('SUPPLIER_AP_FINAL','2120'),
        ('CUSTOMER_BALANCE_LIABILITY','2130'),('OUTPUT_TAX','2150'),
        ('CUSTOMER_REFUND_LIABILITY','2160'),
        ('CASH_OVERAGE_LIABILITY','2170'),('OWNER_CAPITAL','3110'),
        ('RETAINED_EARNINGS','3210'),
        ('OPENING_BALANCE_CLEARING','3310'),('SALES_REVENUE','4110'),
        ('SALES_RETURN_DISCOUNT','4120'),('COGS','5110'),
        ('PURCHASE_PRICE_VARIANCE','5130'),('EXPENSE','6110'),
        ('STOCK_LOSS_EXPENSE','6130'),('BAD_DEBT_EXPENSE','6140'),
        ('ROUNDING_LOSS','6150'),('STOCK_GAIN_INCOME','7110'),
        ('ROUNDING_GAIN','7120'),('BAD_DEBT_RECOVERY','7130'),
        ('OTHER_INCOME','7140'),('PAYMENT_SURCHARGE_INCOME','7150')
), target_functions(function_key,seed_code) AS (
    VALUES
        ('COGS','5110'),
        ('INVENTORY_ASSET','1310'),
        ('SALES_REVENUE','4110'),
        ('STOCK_GAIN_INCOME','7110'),
        ('STOCK_LOSS_EXPENSE','6130')
), target_scope AS (
    SELECT
        account.company_id,account.system_function_key,
        count(*) FILTER (
            WHERE account.is_system_account
              AND account.is_active
              AND account.is_postable
        ) AS system_account_count,
        count(*) FILTER (
            WHERE account.is_system_account
              AND upper(btrim(account.account_code)) = target.seed_code
        ) AS canonical_seed_count
    FROM public.chart_of_accounts account
    JOIN target_functions target
      ON target.function_key = account.system_function_key
    GROUP BY account.company_id,account.system_function_key
), checks AS (
    SELECT
        'migration_ledger'::TEXT AS check_name,
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END AS status,
        count(*) FILTER (WHERE version IS NULL) AS violation_rows,
        jsonb_build_object('ledger_rows',count(*)) AS details
    FROM private.kgs_schema_migrations
    WHERE version = '20260810185000'

    UNION ALL

    SELECT
        'single_system_account_per_target_function',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('invalid_company_function_rows',count(*))
    FROM target_scope
    WHERE system_account_count <> 1

    UNION ALL

    SELECT
        'canonical_seed_remains_system_owned',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('invalid_company_function_rows',count(*))
    FROM target_scope
    WHERE canonical_seed_count <> 1

    UNION ALL

    SELECT
        'noncanonical_system_owned_account',
        CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
        count(*),
        jsonb_build_object('row_count',count(*))
    FROM public.chart_of_accounts account
    WHERE account.is_system_account
      AND NOT EXISTS (
          SELECT 1
          FROM canonical_seed seed
          WHERE seed.function_key = account.system_function_key
            AND seed.seed_code = upper(btrim(account.account_code))
      )

    UNION ALL

    SELECT
        'company_owned_duplicate_inventory',
        'INFO',0,
        jsonb_build_object(
            'demoted_rows',count(*),
            'companies',count(DISTINCT account.company_id)
        )
    FROM public.chart_of_accounts account
    JOIN target_functions target
      ON target.function_key = account.system_function_key
    WHERE NOT account.is_system_account

    UNION ALL

    SELECT
        'ownership_correction_audit',
        CASE WHEN count(*) > 0 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) > 0 THEN 0 ELSE 1 END,
        jsonb_build_object('audit_rows',count(*))
    FROM public.finance_master_audit audit
    WHERE audit.entity_type = 'ACCOUNT'
      AND audit.action = 'UPDATE'
      AND COALESCE((audit.before_state->>'is_system_account')::BOOLEAN,FALSE)
      AND NOT COALESCE(
          (audit.after_state->>'is_system_account')::BOOLEAN,TRUE
      )

    UNION ALL

    SELECT
        'single_system_account_guard',
        CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN count(*) = 1 THEN 0 ELSE 1 END,
        jsonb_build_object('trigger_rows',count(*))
    FROM pg_trigger trigger_state
    WHERE trigger_state.tgname = 'g6_guard_single_system_function_account'
      AND NOT trigger_state.tgisinternal
      AND trigger_state.tgenabled <> 'D'
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
    check_name;
