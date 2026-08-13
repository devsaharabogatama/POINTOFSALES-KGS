-- G6 corrective phase 1: quarantine unsafe browser-executable Finance routines.
--
-- This migration is intentionally privilege-only. It preserves routine
-- definitions for dependency/forensic compatibility, does not post or mutate
-- any Finance business row, and does not claim that the G6 posting engine is
-- operational.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260810160000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G5 corrective tolerance gate incomplete';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810170000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810170000';
    END IF;
END
$migration_guard$;

DO $quarantine$
DECLARE
    v_routine RECORD;
    v_identity TEXT;
BEGIN
    FOR v_routine IN
        SELECT
            namespace.nspname AS schema_name,
            routine.proname AS routine_name,
            pg_get_function_identity_arguments(routine.oid)
                AS identity_arguments
        FROM pg_proc routine
        JOIN pg_namespace namespace ON namespace.oid = routine.pronamespace
        WHERE namespace.nspname = 'public'
          AND routine.proname = ANY (ARRAY[
              'post_financial_event',
              'post_pending_financial_events',
              'ensure_accounting_period_open',
              'resolve_account_for_function',
              'resolve_account_by_code',
              'get_general_ledger_report',
              'get_trial_balance_report',
              'get_income_statement_report',
              'get_balance_sheet_report',
              'get_account_journal_lines'
          ]::TEXT[])
    LOOP
        v_identity := format(
            '%I.%I(%s)',
            v_routine.schema_name,
            v_routine.routine_name,
            v_routine.identity_arguments
        );

        EXECUTE format(
            'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',
            v_identity
        );
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION %s TO service_role',
            v_identity
        );
    END LOOP;
END
$quarantine$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260810170000',
    'g6_phase1_unsafe_finance_routine_quarantine',
    'Privilege-only corrective quarantine for rejected G6 Finance routines; no business-row mutation and Finance posting remains closed'
);

COMMIT;
