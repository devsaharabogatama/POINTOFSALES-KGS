-- Deterministic read-only behavior for future Scheduled Draft resume routing.
BEGIN;
DO $test$
DECLARE v_company uuid;v_timezone text;v_today date;v_future date;
  v_future_at timestamptz;v_route text;v_blocked boolean;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260910100000') THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: scheduled Draft resume fix required';
  END IF;
  SELECT company.id,company.timezone INTO v_company,v_timezone
  FROM public.companies company WHERE company.status='ACTIVE'
  ORDER BY company.id LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company required';
  END IF;
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::date;
  v_future:=v_today+1;
  v_future_at:=(v_future::text||' 12:00:00')::timestamp AT TIME ZONE v_timezone;

  v_route:=private.validate_pos_tempo_draft_save_dates(
    v_company,'SCHEDULED',v_future,v_future_at,v_future_at+interval '14 days',
    'DELIVERY',v_future_at+interval '1 day','PRESERVE');
  IF v_route<>'SCHEDULED_PRESERVE' THEN
    RAISE EXCEPTION 'TEST_FAILED: future Scheduled Draft did not use Scheduled validation';
  END IF;
  IF private.validate_pos_tempo_draft_save_dates(
      v_company,'SCHEDULED',v_future,v_future_at,v_future_at+interval '14 days',
      'DELIVERY',v_future_at+interval '1 day','PRESERVE') IS DISTINCT FROM v_route THEN
    RAISE EXCEPTION 'TEST_FAILED: scheduled validation retry drift';
  END IF;

  v_blocked:=false;
  BEGIN
    PERFORM private.validate_pos_tempo_draft_save_dates(
      v_company,'IMMEDIATE',NULL,v_future_at,v_future_at+interval '14 days',
      'PICKUP',NULL,'PRESERVE');
  EXCEPTION WHEN raise_exception THEN
    v_blocked:=SQLERRM='TEMPO_TRANSACTION_DATE_FUTURE';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: non-Scheduled future effective date accepted';
  END IF;

  v_blocked:=false;
  BEGIN
    PERFORM private.validate_pos_tempo_draft_save_dates(
      v_company,'SCHEDULED',v_future,v_future_at,v_future_at-interval '1 day',
      'PICKUP',NULL,'PRESERVE');
  EXCEPTION WHEN raise_exception THEN
    v_blocked:=SQLERRM='TEMPO_DUE_DATE_BEFORE_PLANNED_ORDER';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: due date before planned Order accepted';
  END IF;

  v_blocked:=false;
  BEGIN
    PERFORM private.validate_pos_tempo_draft_save_dates(
      v_company,'SCHEDULED',v_future,v_future_at,v_future_at+interval '14 days',
      'DELIVERY',v_future_at-interval '1 day','PRESERVE');
  EXCEPTION WHEN raise_exception THEN
    v_blocked:=SQLERRM='DELIVERY_DATE_BEFORE_PLANNED_ORDER';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: delivery before planned Order accepted';
  END IF;

  v_blocked:=false;
  BEGIN
    PERFORM private.validate_pos_tempo_draft_save_dates(
      v_company,'SCHEDULED',v_future,v_future_at+interval '1 day',
      v_future_at+interval '14 days','PICKUP',NULL,'PRESERVE');
  EXCEPTION WHEN raise_exception THEN
    v_blocked:=SQLERRM='SCHEDULED_ORDER_DATE_IDENTITY_MISMATCH';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'TEST_FAILED: mismatched Scheduled date identity accepted';
  END IF;

  IF position('validate_pos_tempo_draft_save_dates' in pg_get_functiondef(
      'private.save_pos_sale_draft_before_schedule_core(jsonb)'::regprocedure))=0
    OR position('v_existing_payload->>''plannedOrderAt''' in pg_get_functiondef(
      'private.save_pos_sale_draft_before_schedule_core(jsonb)'::regprocedure))=0
    OR position('''plannedOrderAt'',v_requested_at' in pg_get_functiondef(
      'private.save_pos_sale_draft_before_schedule_core(jsonb)'::regprocedure))=0
    OR position('MASTER_VERSION_CONFLICT' in pg_get_functiondef(
      'private.save_pos_sale_draft_core(jsonb)'::regprocedure))=0
    OR position('SCHEDULED_ORDER_NOT_ACTIVE' in pg_get_functiondef(
      'public.post_pos_sale(uuid,bigint,uuid)'::regprocedure))=0 THEN
    RAISE EXCEPTION 'TEST_FAILED: save routing, timestamp preservation, or early-post guard missing';
  END IF;
END
$test$;
ROLLBACK;

SELECT 'pos_scheduled_draft_resume_behavior' check_name,'PASS' status,
  0::bigint violation_rows,jsonb_build_object('tested',ARRAY[
    'future Scheduled TEMPO Preserve accepted','exact helper retry stable',
    'future non-Scheduled TEMPO rejected','due before planned Order rejected',
    'delivery before planned Order rejected','Scheduled identity mismatch rejected',
    'scheduled timestamp preservation retained','optimistic-version guard retained',
    'Post-before-schedule guard retained',
    'zero business writes']) details;
