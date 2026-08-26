-- POS TEMPO backdated order/delivery preflight.
-- SAFETY: SELECT-only.
WITH checks AS (
  SELECT 'migration_dependency' AS check_name,
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END AS status,
    jsonb_build_object('expected',2,'ledgerRows',count(*)) AS details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260825110000','20260825120000')
  UNION ALL
  SELECT 'canonical_pos_runtime',
    CASE WHEN count(*)=2 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',2,'routineRows',count(*))
  FROM pg_proc procedure
  JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE namespace.nspname IN('public','private')
    AND procedure.proname IN('save_pos_sale_draft_with_pricelist','post_pos_sale_online_core')
  UNION ALL
  SELECT 'active_company_period_readiness',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BACKFILL' END,
    jsonb_build_object('companiesWithoutOpenPeriod',count(*))
  FROM public.companies company
  WHERE company.status='ACTIVE'
    AND NOT EXISTS(
      SELECT 1 FROM public.accounting_periods period
      WHERE period.company_id=company.id
        AND (clock_timestamp() AT TIME ZONE company.timezone)::DATE
          BETWEEN period.start_date AND period.end_date
        AND period.status IN('OPEN','REOPENED')
    )
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions submission
  WHERE submission.status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'canonical_backdate_schema_state','SETUP',jsonb_build_object(
    'missingColumns',COALESCE((
      SELECT jsonb_agg(required.column_name ORDER BY required.column_name)
      FROM (VALUES('transaction_date_source'),('transaction_date_selected_by'),
        ('transaction_date_selected_at')) required(column_name)
      WHERE NOT EXISTS(
        SELECT 1 FROM information_schema.columns column_state
        WHERE column_state.table_schema='public'
          AND column_state.table_name='sales_headers'
          AND column_state.column_name=required.column_name
      )
    ),'[]'::JSONB)
  )
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'BACKFILL' THEN 2
  WHEN 'SETUP' THEN 3 ELSE 4 END,check_name;
