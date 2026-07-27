-- KGS POS G2 phase 19: isolate Finance history trigger branches by table.
-- Forward fix for record-field error on Transaction Category updates.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722180000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: phase 18 required categories missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722210000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722210000';
    END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION private.trg_g2_guard_finance_master_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_TABLE_NAME = 'transaction_categories' THEN
        IF NEW.system_key IS DISTINCT FROM OLD.system_key
           AND (
               EXISTS (
                   SELECT 1 FROM public.transaction_account_rules r
                   WHERE r.company_id = OLD.company_id
                     AND r.transaction_category_id = OLD.id
               ) OR EXISTS (
                   SELECT 1 FROM public.financial_events e
                   WHERE e.company_id = OLD.company_id
                     AND e.transaction_category_id = OLD.id
               )
           ) THEN
            RAISE EXCEPTION 'CATEGORY_SYSTEM_EVENT_LOCKED_BY_HISTORY';
        END IF;
    ELSIF TG_TABLE_NAME = 'chart_of_accounts' THEN
        IF NEW.account_type IS DISTINCT FROM OLD.account_type
           AND EXISTS (
               SELECT 1 FROM public.journal_entries je
               WHERE je.company_id = OLD.company_id
                 AND je.account_id = OLD.id
           ) THEN
            RAISE EXCEPTION 'ACCOUNT_TYPE_LOCKED_BY_HISTORY';
        END IF;
    ELSE
        RAISE EXCEPTION
            'UNSUPPORTED_FINANCE_MASTER_HISTORY_TABLE: %',TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_finance_master_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_guard_finance_master_history()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260722210000',
    'g2_phase19_finance_history_trigger_fix',
    'Forward fix: branch on trigger table before accessing table-specific fields; no schema, category, mapping, resolver, or journal behavior change'
);

COMMIT;
