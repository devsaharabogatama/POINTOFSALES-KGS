-- Finance period policy + TEMPO resume preflight. SELECT-only.
WITH checks AS (
  SELECT 'migration_dependency' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260826100000'
  UNION ALL
  SELECT 'canonical_tempo_runtime',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',count(*),'expected',3)
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE (namespace.nspname,procedure.proname) IN(
    ('public','save_pos_sale_draft_with_pricelist'),
    ('public','list_pos_sale_drafts'),
    ('private','validate_pos_tempo_effective_dates'))
  UNION ALL
  SELECT 'accounting_period_overlap',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('overlapPairs',count(*))
  FROM public.accounting_periods left_period
  JOIN public.accounting_periods right_period
    ON right_period.company_id=left_period.company_id
   AND right_period.id>left_period.id
   AND daterange(right_period.start_date,right_period.end_date,'[]')
       &&daterange(left_period.start_date,left_period.end_date,'[]')
  UNION ALL
  SELECT 'tempo_draft_period_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'REVIEW' END,
    jsonb_build_object('draftsWithoutOpenPeriod',count(*))
  FROM public.sales_headers sale
  JOIN public.companies company ON company.id=sale.company_id
  WHERE sale.document_status='DRAFT' AND sale.is_tempo
    AND NOT EXISTS(SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=sale.company_id
        AND (sale.transaction_date AT TIME ZONE company.timezone)::DATE
            BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED'))
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'REVIEW' THEN 1 ELSE 2 END,
  check_name;
