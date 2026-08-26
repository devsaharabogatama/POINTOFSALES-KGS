-- POS TEMPO effective-date validation behavior.
-- Read-only helper calls; no business data is written.
DO $test$
DECLARE
  v_company UUID;
  v_timezone TEXT;
  v_transaction_at TIMESTAMPTZ;
BEGIN
  SELECT company.id,company.timezone,
    (period.start_date::TIMESTAMP + interval '1 hour') AT TIME ZONE company.timezone
  INTO v_company,v_timezone,v_transaction_at
  FROM public.companies company
  JOIN public.accounting_periods period ON period.company_id=company.id
    AND period.status IN('OPEN','REOPENED')
    AND period.start_date<=LEAST(
      period.end_date,(clock_timestamp() AT TIME ZONE company.timezone)::DATE
    )
  WHERE company.status='ACTIVE'
  ORDER BY period.start_date DESC,company.id
  LIMIT 1;
  IF v_company IS NULL THEN
    RAISE EXCEPTION 'TEST_PRECONDITION_FAILED: active Company with open period required';
  END IF;

  PERFORM private.validate_pos_tempo_effective_dates(
    v_company,v_transaction_at,v_transaction_at+interval '14 days',
    'DELIVERY',v_transaction_at+interval '1 day'
  );

  BEGIN
    PERFORM private.validate_pos_tempo_effective_dates(
      v_company,clock_timestamp()+interval '1 day',clock_timestamp()+interval '15 days',
      'PICKUP',NULL
    );
    RAISE EXCEPTION 'TEST_FAILED: future transaction accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'TEMPO_TRANSACTION_DATE_FUTURE' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM private.validate_pos_tempo_effective_dates(
      v_company,v_transaction_at,v_transaction_at-interval '1 second',
      'PICKUP',NULL
    );
    RAISE EXCEPTION 'TEST_FAILED: due date before transaction accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'TEMPO_DUE_DATE_BEFORE_TRANSACTION' THEN RAISE; END IF;
  END;

  BEGIN
    PERFORM private.validate_pos_tempo_effective_dates(
      v_company,v_transaction_at,v_transaction_at+interval '14 days',
      'DELIVERY',v_transaction_at-interval '1 second'
    );
    RAISE EXCEPTION 'TEST_FAILED: delivery before transaction accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM<>'DELIVERY_DATE_BEFORE_TRANSACTION' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'PASS: TEMPO backdate, future, due-date, and delivery-date contracts';
END
$test$;
