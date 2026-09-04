-- Sales Order revision TEMPO business-date regression.
-- SAFETY: definition and privilege checks only; no business row is changed.
BEGIN;

DO $test$
DECLARE v_definition TEXT;v_schedule_definition TEXT;
BEGIN
  IF to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)'
    ) IS NULL THEN
    RAISE EXCEPTION 'TEST_FAILED: TEMPO validator missing';
  END IF;
  SELECT lower(regexp_replace(pg_get_functiondef(
    'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)'::regprocedure),
    '[[:space:]]+','','g')) INTO v_definition;
  IF position('v_today:=(clock_timestamp()attimezonev_timezone)::date'
      IN v_definition)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Company-local current business date missing';
  END IF;
  IF position('v_effective_date:=(p_transaction_atattimezonev_timezone)::date'
      IN v_definition)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: Company-local transaction business date missing';
  END IF;
  IF position('v_effective_date>v_today' IN v_definition)=0
    OR position('tempo_transaction_date_future' IN v_definition)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: future TEMPO business-date guard missing';
  END IF;
  IF position('p_transaction_at>clock_timestamp' IN v_definition)>0 THEN
    RAISE EXCEPTION 'TEST_FAILED: obsolete raw timestamp future guard retained';
  END IF;
  IF position('tempo_due_date_before_transaction' IN v_definition)=0
    OR position('delivery_date_before_transaction' IN v_definition)=0
    OR position('ensure_company_accounting_periods' IN v_definition)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: retained TEMPO date or period guard missing';
  END IF;
  SELECT lower(regexp_replace(pg_get_functiondef(
    'public.save_pos_sale_draft_with_pricelist(jsonb)'::regprocedure),
    '[[:space:]]+','','g')) INTO v_schedule_definition;
  IF position('v_requested_date>v_today' IN v_schedule_definition)=0
    OR position('scheduled_order_tempo_required' IN v_schedule_definition)=0
    OR position('validate_pos_scheduled_order_dates' IN v_schedule_definition)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: future business-date scheduled routing changed';
  END IF;
  IF has_function_privilege('authenticated',
      'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)',
      'EXECUTE') THEN
    RAISE EXCEPTION 'TEST_FAILED: private TEMPO validator browser-executable';
  END IF;
END
$test$;

SELECT 'sales_order_revision_tempo_business_date_contract_test' check_name,
  'PASS' status,jsonb_build_object('tested',ARRAY[
    'Company-local business-date comparison',
    'same-day clock no longer treated as future business date',
    'future business-date scheduled routing retained',
    'due and delivery date guards retained',
    'accounting period guard retained',
    'private execution boundary retained']) details;

ROLLBACK;
