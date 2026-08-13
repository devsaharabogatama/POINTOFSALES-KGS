-- G6 corrective phase 1 behavioral privilege test.
-- SAFETY: metadata assertions only; transaction is rolled back.

BEGIN;

DO $test$
DECLARE
    v_routine RECORD;
    v_rows INTEGER := 0;
BEGIN
    FOR v_routine IN
        SELECT routine.oid,routine.proname
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
        v_rows := v_rows + 1;

        IF has_function_privilege(
               'authenticated',v_routine.oid,'EXECUTE'
           ) OR has_function_privilege('anon',v_routine.oid,'EXECUTE') THEN
            RAISE EXCEPTION
                'TEST_FAILED: browser can execute unsafe Finance routine %',
                v_routine.proname;
        END IF;

        IF NOT has_function_privilege(
            'service_role',v_routine.oid,'EXECUTE'
        ) THEN
            RAISE EXCEPTION
                'TEST_FAILED: service_role lost Finance routine compatibility %',
                v_routine.proname;
        END IF;
    END LOOP;

    RAISE NOTICE
        'TEST PASSED: % rejected Finance routines found; every existing routine is browser-inaccessible and service-role compatible.',
        v_rows;
END
$test$;

ROLLBACK;
