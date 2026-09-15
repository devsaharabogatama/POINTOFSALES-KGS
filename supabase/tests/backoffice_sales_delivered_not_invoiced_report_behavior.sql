-- Rollback-only behavior for Step 5/6.3. Run the entire file.
BEGIN;
DO $test$
DECLARE v_value text;v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912138000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: migration 20260912138000 required';
  END IF;

  v_value:=private.classify_backoffice_sales_dni(10,0,0);
  IF v_value<>'NOT_DRAFTED' THEN RAISE EXCEPTION 'TEST_FAILED: undrafted classifier'; END IF;
  v_value:=private.classify_backoffice_sales_dni(10,4,0);
  IF v_value<>'PARTIALLY_DRAFTED' THEN RAISE EXCEPTION 'TEST_FAILED: partial Draft classifier'; END IF;
  v_value:=private.classify_backoffice_sales_dni(10,10,0);
  IF v_value<>'FULLY_DRAFTED' THEN RAISE EXCEPTION 'TEST_FAILED: full Draft classifier'; END IF;
  v_value:=private.classify_backoffice_sales_dni(10,0,10);
  IF v_value<>'FULLY_POSTED' THEN RAISE EXCEPTION 'TEST_FAILED: Posted exit classifier'; END IF;
  v_value:=private.classify_backoffice_sales_dni(10,3,4);
  IF v_value<>'PARTIALLY_DRAFTED' THEN RAISE EXCEPTION 'TEST_FAILED: Posted plus Draft classifier'; END IF;

  BEGIN
    PERFORM private.classify_backoffice_sales_dni(10,7,4);
    RAISE EXCEPTION 'TEST_FAILED: over-allocation accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='TEST_FAILED: over-allocation accepted' THEN RAISE; END IF;
    IF position('DELIVERED_NOT_INVOICED_QUANTITY_INVALID' in SQLERRM)=0 THEN RAISE; END IF;
  END;

  SELECT pg_get_functiondef('public.get_finance_delivered_not_invoiced(date,integer,integer)'::regprocedure)
  INTO STRICT v_definition;
  IF v_definition!~'header\.accepted_date\s*<=\s*p_as_of'
    OR v_definition!~'invoice\.posted_at.*<=\s*p_as_of'
    OR v_definition!~'invoice\.status\s*=\s*''DRAFT'''
    OR v_definition!~'invoice\.status\s*=\s*''POSTED'''
    OR position('DELIVERY_FEE' in v_definition)=0
    OR position('delivery_fee_amount' in v_definition)=0
    OR position('measureKind' in v_definition)=0
    OR position('financialStatementIncluded' in v_definition)=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: canonical DNI As-of definition drift';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'backoffice_sales_delivered_not_invoiced_report_behavior' check_name,
  'PASS' status,0 violation_rows,
  jsonb_build_object('tested',jsonb_build_array(
    'not drafted remains DNI','partial Draft remains DNI','full Draft remains DNI',
    'Posted exits DNI','mixed Posted and Draft','over-allocation rejected',
    'acceptance and Posted use As-of business boundaries',
    'delivery fee is a separate amount component')) details;
