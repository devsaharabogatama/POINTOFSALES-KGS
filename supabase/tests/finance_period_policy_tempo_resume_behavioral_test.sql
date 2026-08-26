-- Behavioral smoke for Company business-date validation.
-- One SELECT-only statement: no fixture, temp table, transaction, or write.
WITH fixture AS (
  SELECT company.id company_id,company.timezone,period.start_date
  FROM public.companies company
  JOIN public.finance_company_policies policy
    ON policy.company_id=company.id
   AND policy.period_creation_mode='MANUAL'
  JOIN public.accounting_periods period
    ON period.company_id=company.id
   AND period.status IN('OPEN','REOPENED')
  WHERE company.status='ACTIVE'
    AND period.start_date<=(clock_timestamp() AT TIME ZONE company.timezone)::DATE
  ORDER BY period.start_date DESC,company.id
  LIMIT 1
), validation AS (
  SELECT fixture.*,
    private.validate_pos_tempo_effective_dates(
      fixture.company_id,
      (fixture.start_date::TEXT||' 18:00:00')::TIMESTAMP
        AT TIME ZONE fixture.timezone,
      (fixture.start_date::TEXT||' 06:00:00')::TIMESTAMP
        AT TIME ZONE fixture.timezone,
      'PICKUP',NULL
    ) validation_result
  FROM fixture
), result AS (
  SELECT 'same_business_date_validation' check_name,'PASS' status,
    jsonb_build_object(
      'companyId',validation.company_id,
      'businessDate',validation.start_date,
      'rule','due time may be earlier while business date is equal'
    ) details
  FROM validation
  UNION ALL
  SELECT 'same_business_date_validation','SETUP',
    jsonb_build_object(
      'reason','active Company with MANUAL policy and open current/past period required'
    )
  WHERE NOT EXISTS(SELECT 1 FROM fixture)
)
SELECT check_name,status,details FROM result ORDER BY check_name;
