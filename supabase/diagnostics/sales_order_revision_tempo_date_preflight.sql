-- Sales Order revision TEMPO business-date forward-fix preflight.
-- SAFETY: SELECT-only. No operational row is changed.
WITH validator AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(
    to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)'
    )),''),'[[:space:]]+',' ','g')) definition
), checks AS (
  SELECT 'revision_tempo_date_dependencies'::TEXT check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',4,'ledgerRows',count(*),
      'requiredVersions',ARRAY['20260827090000','20260827154000',
        '20260903110000','20260903120000']) details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260827090000','20260827154000',
    '20260903110000','20260903120000')
  UNION ALL
  SELECT 'canonical_revision_runtime',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',3,'routineRows',count(*))
  FROM (VALUES
    ('public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)'),
    ('public.confirm_pos_sales_order(uuid,bigint,uuid,text)'),
    ('private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)')
  ) routine(signature)
  WHERE to_regprocedure(routine.signature) IS NOT NULL
  UNION ALL
  SELECT 'tempo_timestamp_guard_state',
    CASE WHEN definition~'p_transaction_at>clock_timestamp\(\)\+interval ''1 minute'''
      THEN 'SETUP' ELSE 'PASS' END,
    jsonb_build_object('legacyTimestampComparisonPresent',
      definition~'p_transaction_at>clock_timestamp\(\)\+interval ''1 minute''',
      'businessDateComparisonPresent',definition~'v_effective_date>v_today')
  FROM validator
  UNION ALL
  SELECT 'pending_revision_final_effect_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_order_revisions revision
  WHERE revision.status='PENDING' AND (
    EXISTS(SELECT 1 FROM public.sales_stock_reservations reservation
      WHERE reservation.company_id=revision.company_id
        AND reservation.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_invoice_snapshots invoice
      WHERE invoice.company_id=revision.company_id
        AND invoice.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
      WHERE delivery.company_id=revision.company_id
        AND delivery.sales_id=revision.replacement_sales_id)
    OR EXISTS(SELECT 1 FROM public.financial_events event
      WHERE event.company_id=revision.company_id
        AND event.source_id=revision.replacement_sales_id))
  UNION ALL
  SELECT 'revision_tempo_runtime_inventory','INFO',jsonb_build_object(
    'pendingRevisions',count(*) FILTER(WHERE revision.status='PENDING'),
    'pendingTempoRevisions',count(*) FILTER(WHERE revision.status='PENDING'
      AND replacement.is_tempo),
    'sameBusinessDateFutureClockCandidates',count(*) FILTER(
      WHERE revision.status='PENDING' AND replacement.is_tempo
        AND replacement.transaction_date>clock_timestamp()+interval '1 minute'
        AND (replacement.transaction_date AT TIME ZONE company.timezone)::DATE=
          (clock_timestamp() AT TIME ZONE company.timezone)::DATE))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
   AND replacement.id=revision.replacement_sales_id
  JOIN public.companies company ON company.id=revision.company_id
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
