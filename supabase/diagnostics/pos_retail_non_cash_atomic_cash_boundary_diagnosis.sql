-- SELECT-only diagnosis after the atomic non-cash postflight reported legacy
-- MANUAL_REVIEW Cash rows. This does not mutate requests, Events, Journals,
-- cashier sessions, or migration state.
WITH
cutover AS (
  SELECT
    max(applied_at) FILTER (WHERE version='20260923100000') auto_cash_applied_at,
    max(applied_at) FILTER (WHERE version='20261031100000') atomic_applied_at
  FROM private.kgs_schema_migrations
  WHERE version IN ('20260923100000','20261031100000')
),
cash_rows AS (
  SELECT
    request.id,
    company.company_code,
    sale.invoice_no,
    sale.draft_no,
    sale.sales_origin,
    sale.sales_process_mode,
    sale.document_status,
    sale.order_runtime_status,
    request.status,
    request.verification_mode,
    request.requested_at,
    request.reviewed_at,
    request.financial_event_id,
    event.status::text event_status,
    (SELECT count(*)
      FROM public.finance_journals journal
      WHERE journal.company_id=request.company_id
        AND journal.financial_event_id=request.financial_event_id) journal_rows,
    (SELECT coalesce(jsonb_agg(audit.action ORDER BY audit.created_at),'[]'::jsonb)
      FROM public.sales_payment_verification_audit audit
      WHERE audit.company_id=request.company_id
        AND audit.verification_request_id=request.id) audit_actions,
    request.requested_at < cutover.auto_cash_applied_at legacy_before_auto_cash,
    request.requested_at >= cutover.atomic_applied_at created_by_or_after_atomic
  FROM public.sales_payment_verification_requests request
  JOIN public.companies company ON company.id=request.company_id
  JOIN public.sales_headers sale
    ON sale.company_id=request.company_id AND sale.id=request.sales_id
  LEFT JOIN public.financial_events event
    ON event.company_id=request.company_id AND event.id=request.financial_event_id
  CROSS JOIN cutover
  WHERE request.settlement_route_snapshot='CASH_DRAWER'
    AND request.verification_mode='MANUAL_REVIEW'
),
guard AS (
  SELECT pg_get_functiondef(
    'private.trg_odr5_guard_payment_verification()'::regprocedure
  ) definition
),
checks AS (
  SELECT 10 seq,
    'pos_retail_non_cash_cash_diagnosis_cutover_identity'::text check_name,
    CASE WHEN auto_cash_applied_at IS NOT NULL AND atomic_applied_at IS NOT NULL
      THEN 'PASS' ELSE 'FAIL' END status,
    CASE WHEN auto_cash_applied_at IS NOT NULL AND atomic_applied_at IS NOT NULL
      THEN 0 ELSE 1 END violation_rows,
    jsonb_build_object('autoCashAppliedAt',auto_cash_applied_at,
      'atomicAppliedAt',atomic_applied_at) details
  FROM cutover
  UNION ALL
  SELECT 20,'pos_retail_non_cash_cash_diagnosis_runtime_guard',
    CASE WHEN definition~'POS_CASH_MANUAL_VERIFICATION_FORBIDDEN'
      AND definition~'PAYMENT_VERIFICATION_MODE_IMMUTABLE'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'POS_CASH_MANUAL_VERIFICATION_FORBIDDEN'
      AND definition~'PAYMENT_VERIFICATION_MODE_IMMUTABLE'
      THEN 0 ELSE 1 END,
    jsonb_build_object(
      'manualCashBlocked',definition~'POS_CASH_MANUAL_VERIFICATION_FORBIDDEN',
      'modeImmutable',definition~'PAYMENT_VERIFICATION_MODE_IMMUTABLE')
  FROM guard
  UNION ALL
  SELECT 30,'pos_retail_non_cash_cash_diagnosis_legacy_partition',
    CASE WHEN count(*) FILTER (WHERE NOT legacy_before_auto_cash
        OR created_by_or_after_atomic OR status='PENDING')=0
      THEN 'PASS' ELSE 'ROOT_CAUSE' END,
    count(*) FILTER (WHERE NOT legacy_before_auto_cash
      OR created_by_or_after_atomic OR status='PENDING'),
    jsonb_build_object('rows',count(*),
      'legacyBeforeAutoCash',count(*) FILTER (WHERE legacy_before_auto_cash),
      'createdByOrAfterAtomic',count(*) FILTER (WHERE created_by_or_after_atomic),
      'pending',count(*) FILTER (WHERE status='PENDING'),
      'terminal',count(*) FILTER (WHERE status IN ('VERIFIED','REJECTED','CANCELED')))
  FROM cash_rows
  UNION ALL
  SELECT 40,'pos_retail_non_cash_cash_diagnosis_exact_rows','INFO',0,
    jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(cash_rows)
      ORDER BY requested_at,id),'[]'::jsonb))
  FROM cash_rows
)
SELECT check_name,status,violation_rows,details FROM checks ORDER BY seq;
