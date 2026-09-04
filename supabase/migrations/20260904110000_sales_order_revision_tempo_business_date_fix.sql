-- Treat POS TEMPO transaction dates as Company business dates. A clock value
-- later on the same business day must not block a Sales Order revision.
BEGIN;

DO $migration$
DECLARE v_definition TEXT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260904110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260827090000','20260827154000',
        '20260903110000','20260903120000'))<>4
    OR to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)'
    ) IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: scheduled TEMPO and revision runtime required';
  END IF;
  SELECT pg_get_functiondef(
    'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'TEMPO_TRANSACTION_DATE_FUTURE'
    OR v_definition!~'ensure_company_accounting_periods'
    OR v_definition!~'TEMPO_DUE_DATE_BEFORE_TRANSACTION'
    OR v_definition!~'DELIVERY_DATE_BEFORE_TRANSACTION' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: TEMPO date validator drift';
  END IF;
END
$migration$;

CREATE OR REPLACE FUNCTION private.validate_pos_tempo_effective_dates(
  p_company_id UUID,p_transaction_at TIMESTAMPTZ,p_due_at TIMESTAMPTZ,
  p_fulfillment_mode TEXT,p_delivery_scheduled_at TIMESTAMPTZ
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_timezone TEXT;
  v_today DATE;
  v_effective_date DATE;
  v_due_date DATE;
  v_delivery_date DATE;
  v_period_id UUID;
BEGIN
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF p_transaction_at IS NULL THEN RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_REQUIRED'; END IF;

  -- Accounting and scheduling are business-date contracts. Comparing the raw
  -- timestamp caused a revision copied from an existing Order to be rejected
  -- when its clock portion was later on the same Company-local day.
  v_today:=(clock_timestamp() AT TIME ZONE v_timezone)::DATE;
  v_effective_date:=(p_transaction_at AT TIME ZONE v_timezone)::DATE;
  IF v_effective_date>v_today THEN
    RAISE EXCEPTION 'TEMPO_TRANSACTION_DATE_FUTURE';
  END IF;

  v_due_date:=CASE WHEN p_due_at IS NULL THEN NULL
    ELSE (p_due_at AT TIME ZONE v_timezone)::DATE END;
  v_delivery_date:=CASE WHEN p_delivery_scheduled_at IS NULL THEN NULL
    ELSE (p_delivery_scheduled_at AT TIME ZONE v_timezone)::DATE END;
  IF v_due_date IS NULL OR v_due_date<v_effective_date THEN
    RAISE EXCEPTION 'TEMPO_DUE_DATE_BEFORE_TRANSACTION';
  END IF;
  IF p_fulfillment_mode='DELIVERY' AND v_delivery_date IS NOT NULL
     AND v_delivery_date<v_effective_date THEN
    RAISE EXCEPTION 'DELIVERY_DATE_BEFORE_TRANSACTION';
  END IF;
  PERFORM private.ensure_company_accounting_periods(
    p_company_id,v_effective_date,auth.uid()
  );
  SELECT period.id INTO v_period_id FROM public.accounting_periods period
  WHERE period.company_id=p_company_id
    AND v_effective_date BETWEEN period.start_date AND period.end_date
    AND period.status IN('OPEN','REOPENED')
  ORDER BY period.start_date DESC,period.id LIMIT 1 FOR SHARE;
  IF v_period_id IS NULL THEN RAISE EXCEPTION 'TEMPO_ACCOUNTING_PERIOD_NOT_OPEN'; END IF;
END
$$;

REVOKE ALL ON FUNCTION private.validate_pos_tempo_effective_dates(
  UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.validate_pos_tempo_effective_dates(
  UUID,TIMESTAMPTZ,TIMESTAMPTZ,TEXT,TIMESTAMPTZ)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260904110000','sales_order_revision_tempo_business_date_fix',
  'Compares TEMPO transaction date to the Company-local business date so a copied revision timestamp later on the same day does not fail, while future business dates remain scheduled-only');

NOTIFY pgrst,'reload schema';
COMMIT;
