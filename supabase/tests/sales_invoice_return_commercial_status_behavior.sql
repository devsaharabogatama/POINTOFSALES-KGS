-- Rollback-only behavior: classification is deterministic and source rows are untouched.
BEGIN;

DO $test$
DECLARE v_actual text;
BEGIN
  SELECT private.derive_sales_invoice_commercial_status(false,100,0,false)
    INTO v_actual;
  IF v_actual<>'ACTIVE' THEN RAISE EXCEPTION
    'TEST_FAILED: untouched Invoice must remain ACTIVE'; END IF;

  SELECT private.derive_sales_invoice_commercial_status(false,100,0,true)
    INTO v_actual;
  IF v_actual<>'RETURN_IN_PROGRESS' THEN RAISE EXCEPTION
    'TEST_FAILED: non-canceled Return must be RETURN_IN_PROGRESS'; END IF;

  SELECT private.derive_sales_invoice_commercial_status(false,100,25,true)
    INTO v_actual;
  IF v_actual<>'PARTIALLY_RETURNED' THEN RAISE EXCEPTION
    'TEST_FAILED: partial posted credit must be PARTIALLY_RETURNED'; END IF;

  SELECT private.derive_sales_invoice_commercial_status(false,100,100,true)
    INTO v_actual;
  IF v_actual<>'RETURNED' THEN RAISE EXCEPTION
    'TEST_FAILED: full posted credit must be RETURNED'; END IF;

  SELECT private.derive_sales_invoice_commercial_status(true,100,100,true)
    INTO v_actual;
  IF v_actual<>'CANCELED' THEN RAISE EXCEPTION
    'TEST_FAILED: cancellation must remain authoritative'; END IF;

  SELECT private.derive_sales_invoice_commercial_status(false,100,125,true)
    INTO v_actual;
  IF v_actual<>'RETURNED' THEN RAISE EXCEPTION
    'TEST_FAILED: rounding/legacy over-credit must not display ACTIVE'; END IF;
END
$test$;

SELECT 'sales_invoice_return_commercial_status_behavior' check_name,'PASS' status,
  0::bigint violation_rows,
  jsonb_build_object('tested',ARRAY['active','return in progress','partial return',
    'full return','cancellation precedence','legacy over-credit']) details;

ROLLBACK;
