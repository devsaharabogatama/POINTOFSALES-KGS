-- KGS POS G6 corrective phase 3: imported COA ownership correction.
-- Imported Company accounts keep identity/history/function tags, but duplicate
-- system ownership is removed before canonical posting mappings are provisioned.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810180000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G6 phase 2 is required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810185000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810185000';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810190000'
    ) OR to_regclass('public.posting_rule_sets') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 3 mapping already started';
    END IF;
END
$migration_guard$;

DO $correct_imported_account_ownership$
DECLARE
    v_actor UUID;
    v_correction_scope BIGINT;
    v_invalid_scope BIGINT;
    v_changed BIGINT;
    v_remaining BIGINT;
BEGIN
    WITH seed_map(function_key,seed_code) AS (
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
            ('UNDER_DEPOSIT_CONTROL','1280'),
            ('INVENTORY_ASSET','1310'),
            ('SUPPLIER_AP_PROVISIONAL','2110'),
            ('SUPPLIER_AP_FINAL','2120'),
            ('CUSTOMER_BALANCE_LIABILITY','2130'),
            ('OUTPUT_TAX','2150'),
            ('CUSTOMER_REFUND_LIABILITY','2160'),
            ('CASH_OVERAGE_LIABILITY','2170'),
            ('OWNER_CAPITAL','3110'),('RETAINED_EARNINGS','3210'),
            ('OPENING_BALANCE_CLEARING','3310'),
            ('SALES_REVENUE','4110'),
            ('SALES_RETURN_DISCOUNT','4120'),('COGS','5110'),
            ('PURCHASE_PRICE_VARIANCE','5130'),('EXPENSE','6110'),
            ('STOCK_LOSS_EXPENSE','6130'),
            ('BAD_DEBT_EXPENSE','6140'),('ROUNDING_LOSS','6150'),
            ('STOCK_GAIN_INCOME','7110'),('ROUNDING_GAIN','7120'),
            ('BAD_DEBT_RECOVERY','7130'),('OTHER_INCOME','7140'),
            ('PAYMENT_SURCHARGE_INCOME','7150')
    )
    SELECT count(*) INTO v_correction_scope
    FROM public.chart_of_accounts account
    WHERE account.is_system_account
      AND NOT EXISTS (
          SELECT 1
          FROM seed_map seed
          WHERE seed.function_key = account.system_function_key
            AND seed.seed_code = upper(btrim(account.account_code))
      );

    -- Fresh databases contain only canonical seed accounts, so there is no
    -- historical imported-account correction to audit. A linked Super Admin
    -- remains mandatory whenever a real correction is present.
    IF v_correction_scope > 0 THEN
    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id = profile.id
    WHERE profile.role::TEXT = 'super_admin'
    ORDER BY profile.id
    LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: linked Super Admin required';
    END IF;

    WITH seed_map(function_key,seed_code) AS (
        VALUES
            ('COGS','5110'),
            ('INVENTORY_ASSET','1310'),
            ('SALES_REVENUE','4110'),
            ('STOCK_GAIN_INCOME','7110'),
            ('STOCK_LOSS_EXPENSE','6130')
    ), duplicate_scope AS (
        SELECT account.company_id,account.system_function_key
        FROM public.chart_of_accounts account
        JOIN seed_map seed
          ON seed.function_key = account.system_function_key
        WHERE account.is_system_account
          AND account.is_active
          AND account.is_postable
        GROUP BY account.company_id,account.system_function_key
        HAVING count(*) > 1
    )
    SELECT count(*) INTO v_invalid_scope
    FROM duplicate_scope duplicate
    JOIN seed_map seed ON seed.function_key = duplicate.system_function_key
    WHERE (
        SELECT count(*)
        FROM public.chart_of_accounts canonical
        WHERE canonical.company_id = duplicate.company_id
          AND canonical.system_function_key = duplicate.system_function_key
          AND canonical.is_system_account
          AND canonical.is_active
          AND canonical.is_postable
          AND upper(btrim(canonical.account_code)) = seed.seed_code
    ) <> 1;
    IF v_invalid_scope <> 0 THEN
        RAISE EXCEPTION
            'IMPORTED_COA_CANONICAL_SEED_UNRESOLVED: % scopes',
            v_invalid_scope;
    END IF;

    -- The old guard intentionally locks this flag. ALTER TRIGGER takes a table
    -- lock, so concurrent writes cannot enter during this one-time correction.
    -- Transaction rollback restores the trigger on any failure.
    ALTER TABLE public.chart_of_accounts
        DISABLE TRIGGER g2_guard_chart_of_account_structure;

    WITH seed_map(function_key,seed_code) AS (
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
            ('UNDER_DEPOSIT_CONTROL','1280'),
            ('INVENTORY_ASSET','1310'),
            ('SUPPLIER_AP_PROVISIONAL','2110'),
            ('SUPPLIER_AP_FINAL','2120'),
            ('CUSTOMER_BALANCE_LIABILITY','2130'),
            ('OUTPUT_TAX','2150'),
            ('CUSTOMER_REFUND_LIABILITY','2160'),
            ('CASH_OVERAGE_LIABILITY','2170'),
            ('OWNER_CAPITAL','3110'),('RETAINED_EARNINGS','3210'),
            ('OPENING_BALANCE_CLEARING','3310'),
            ('SALES_REVENUE','4110'),
            ('SALES_RETURN_DISCOUNT','4120'),('COGS','5110'),
            ('PURCHASE_PRICE_VARIANCE','5130'),('EXPENSE','6110'),
            ('STOCK_LOSS_EXPENSE','6130'),
            ('BAD_DEBT_EXPENSE','6140'),('ROUNDING_LOSS','6150'),
            ('STOCK_GAIN_INCOME','7110'),('ROUNDING_GAIN','7120'),
            ('BAD_DEBT_RECOVERY','7130'),('OTHER_INCOME','7140'),
            ('PAYMENT_SURCHARGE_INCOME','7150')
    ), demotion AS MATERIALIZED (
        SELECT
            account.company_id,account.id,
            to_jsonb(account) AS before_state
        FROM public.chart_of_accounts account
        WHERE account.is_system_account
          AND NOT EXISTS (
              SELECT 1
              FROM seed_map seed
              WHERE seed.function_key = account.system_function_key
                AND seed.seed_code = upper(btrim(account.account_code))
          )
    ), updated AS (
        UPDATE public.chart_of_accounts account
        SET is_system_account = FALSE,
            updated_by = v_actor
        FROM demotion
        WHERE account.company_id = demotion.company_id
          AND account.id = demotion.id
        RETURNING
            account.company_id,account.id,to_jsonb(account) AS after_state
    )
    INSERT INTO public.finance_master_audit(
        company_id,entity_type,entity_id,action,actor_id,
        before_state,after_state
    )
    SELECT
        updated.company_id,'ACCOUNT',updated.id,'UPDATE',v_actor,
        demotion.before_state,updated.after_state
    FROM updated
    JOIN demotion
      ON demotion.company_id = updated.company_id
     AND demotion.id = updated.id;
    GET DIAGNOSTICS v_changed = ROW_COUNT;

    ALTER TABLE public.chart_of_accounts
        ENABLE TRIGGER g2_guard_chart_of_account_structure;

    IF v_changed = 0 THEN
        RAISE EXCEPTION 'IMPORTED_COA_OWNERSHIP_CORRECTION_EMPTY';
    END IF;
    END IF;

    WITH target_functions(function_key) AS (
        VALUES
            ('COGS'),('INVENTORY_ASSET'),('SALES_REVENUE'),
            ('STOCK_GAIN_INCOME'),('STOCK_LOSS_EXPENSE')
    )
    SELECT count(*) INTO v_remaining
    FROM (
        SELECT account.company_id,account.system_function_key
        FROM public.chart_of_accounts account
        JOIN target_functions target
          ON target.function_key = account.system_function_key
        WHERE account.is_system_account
          AND account.is_active
          AND account.is_postable
        GROUP BY account.company_id,account.system_function_key
        HAVING count(*) <> 1
    ) unresolved;
    IF v_remaining <> 0 THEN
        RAISE EXCEPTION
            'SYSTEM_FUNCTION_ACCOUNT_CORRECTION_INCOMPLETE: % scopes',
            v_remaining;
    END IF;
END
$correct_imported_account_ownership$;

CREATE FUNCTION private.trg_g6_guard_single_system_function_account()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.is_system_account
       AND NEW.system_function_key IS NOT NULL
       AND EXISTS (
           SELECT 1
           FROM public.chart_of_accounts existing
           WHERE existing.company_id = NEW.company_id
             AND existing.system_function_key = NEW.system_function_key
             AND existing.is_system_account
             AND existing.id <> NEW.id
       ) THEN
        RAISE EXCEPTION 'SYSTEM_FUNCTION_ACCOUNT_ALREADY_EXISTS';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g6_guard_single_system_function_account
BEFORE INSERT OR UPDATE OF company_id,system_function_key,is_system_account
ON public.chart_of_accounts
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_single_system_function_account();

REVOKE ALL ON FUNCTION private.trg_g6_guard_single_system_function_account()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g6_guard_single_system_function_account()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260810185000',
    'g6_phase3_company_owned_imported_coa_fix',
    'Demotes imported duplicate system COA to Company-owned accounts while preserving identity, function tag, references, and audit history'
);

COMMIT;
