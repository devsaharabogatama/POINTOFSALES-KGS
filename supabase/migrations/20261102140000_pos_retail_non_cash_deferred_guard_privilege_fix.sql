BEGIN;

DO $guard$
DECLARE
  v_definition text;
  v_owner text;
  v_security_definer boolean;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261102140000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260828210000','20260923100000',
        '20261031100000','20261031110000'))<>4 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: required POS payment chain';
  END IF;
  IF to_regprocedure('private.trg_enforce_no_pending_pos_cash()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: deferred Cash guard missing';
  END IF;
  SELECT pg_get_functiondef(routine.oid),pg_get_userbyid(routine.proowner),
    routine.prosecdef
  INTO v_definition,v_owner,v_security_definer
  FROM pg_proc routine
  WHERE routine.oid='private.trg_enforce_no_pending_pos_cash()'::regprocedure;
  IF v_owner<>'postgres' OR v_security_definer
    OR v_definition NOT LIKE '%sales_payment_verification_requests%'
    OR v_definition NOT LIKE '%POS_CASH_AUTO_VERIFICATION_REQUIRED%' THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: deferred Cash guard runtime drift';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_trigger trigger_row
      JOIN pg_class relation ON relation.oid=trigger_row.tgrelid
      JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
      WHERE namespace.nspname='public'
        AND relation.relname='sales_payment_verification_requests'
        AND trigger_row.tgname='enforce_no_pending_pos_cash'
        AND trigger_row.tgfoid=
          'private.trg_enforce_no_pending_pos_cash()'::regprocedure
        AND trigger_row.tgdeferrable AND trigger_row.tginitdeferred
        AND trigger_row.tgenabled='O' AND NOT trigger_row.tgisinternal) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: deferred Cash trigger contract drift';
  END IF;
  IF has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','SELECT') THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: authenticated table access must stay denied';
  END IF;
END
$guard$;

ALTER FUNCTION private.trg_enforce_no_pending_pos_cash() SECURITY DEFINER;
ALTER FUNCTION private.trg_enforce_no_pending_pos_cash() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.trg_enforce_no_pending_pos_cash()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_enforce_no_pending_pos_cash()
TO service_role;

DO $verify$
DECLARE v_definition text;
BEGIN
  SELECT pg_get_functiondef(routine.oid) INTO v_definition
  FROM pg_proc routine
  WHERE routine.oid='private.trg_enforce_no_pending_pos_cash()'::regprocedure
    AND routine.prosecdef
    AND pg_get_userbyid(routine.proowner)='postgres';
  IF v_definition IS NULL
    OR v_definition NOT LIKE '%sales_payment_verification_requests%'
    OR v_definition NOT LIKE '%POS_CASH_AUTO_VERIFICATION_REQUIRED%' THEN
    RAISE EXCEPTION
      'MIGRATION_POSTCONDITION_FAILED: deferred Cash guard privilege boundary';
  END IF;
  IF has_table_privilege('authenticated',
      'public.sales_payment_verification_requests','SELECT') THEN
    RAISE EXCEPTION
      'MIGRATION_POSTCONDITION_FAILED: authenticated table access changed';
  END IF;
END
$verify$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261102140000','pos_retail_non_cash_deferred_guard_privilege_fix',
  'Run the existing deferred no-pending-Cash verification guard through its postgres owner so authenticated Retail POS non-cash checkout can commit without granting verification-table access; preserve Cash rejection, Finance verification, Tempo, Backoffice, Stock/FIFO and accounting');

NOTIFY pgrst,'reload schema';
COMMIT;

-- Rollback/forward-fix note:
-- Never edit or rerun this installed migration. If rollback is required, add a
-- new migration with:
-- ALTER FUNCTION private.trg_enforce_no_pending_pos_cash() SECURITY INVOKER;
-- That rollback reintroduces the authenticated checkout defect and is not a
-- safe operational state while direct Retail non-cash payment capture is live.
