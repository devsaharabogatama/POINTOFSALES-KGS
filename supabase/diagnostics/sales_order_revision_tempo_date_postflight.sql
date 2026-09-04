-- Sales Order revision TEMPO business-date forward-fix closing gate.
-- SAFETY: SELECT-only.
WITH validator AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(
    to_regprocedure(
      'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)'
    )),''),'[[:space:]]+','','g')) definition
), schedule_wrapper AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(
    to_regprocedure('public.save_pos_sale_draft_with_pricelist(jsonb)')
  ),''),'[[:space:]]+','','g')) definition
), checks AS (
  SELECT 'migration_ledger'::TEXT check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260904110000'
  UNION ALL
  SELECT 'tempo_business_date_runtime_contract',
    CASE WHEN position('v_today:=(clock_timestamp()attimezonev_timezone)::date'
        IN definition)>0
      AND position('v_effective_date:=(p_transaction_atattimezonev_timezone)::date'
        IN definition)>0
      AND position('v_effective_date>v_today' IN definition)>0
      AND position('p_transaction_at>clock_timestamp' IN definition)=0
      AND position('tempo_due_date_before_transaction' IN definition)>0
      AND position('delivery_date_before_transaction' IN definition)>0
      AND position('ensure_company_accounting_periods' IN definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('v_today:=(clock_timestamp()attimezonev_timezone)::date'
        IN definition)>0
      AND position('v_effective_date:=(p_transaction_atattimezonev_timezone)::date'
        IN definition)>0
      AND position('v_effective_date>v_today' IN definition)>0
      AND position('p_transaction_at>clock_timestamp' IN definition)=0
      AND position('tempo_due_date_before_transaction' IN definition)>0
      AND position('delivery_date_before_transaction' IN definition)>0
      AND position('ensure_company_accounting_periods' IN definition)>0
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM validator
  UNION ALL
  SELECT 'future_business_date_scheduled_routing',
    CASE WHEN position('v_requested_date>v_today' IN definition)>0
      AND position('scheduled_order_tempo_required' IN definition)>0
      AND position('validate_pos_scheduled_order_dates' IN definition)>0
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN position('v_requested_date>v_today' IN definition)>0
      AND position('scheduled_order_tempo_required' IN definition)>0
      AND position('validate_pos_scheduled_order_dates' IN definition)>0
      THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM schedule_wrapper
  UNION ALL
  SELECT 'private_tempo_date_validator_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('browserExecutableRows',count(*))
  FROM (VALUES('anon'),('authenticated')) role_name(name)
  WHERE has_function_privilege(role_name.name,
    'private.validate_pos_tempo_effective_dates(uuid,timestamptz,timestamptz,text,timestamptz)',
    'EXECUTE')
  UNION ALL
  SELECT 'pending_revision_zero_final_effect',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
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
  SELECT 'revision_tempo_date_runtime_inventory','INFO',0::BIGINT,
    jsonb_build_object(
      'pendingRevisions',count(*) FILTER(WHERE revision.status='PENDING'),
      'appliedRevisions',count(*) FILTER(WHERE revision.status='APPLIED'),
      'abandonedRevisions',count(*) FILTER(WHERE revision.status='ABANDONED'),
      'pendingTempoRevisions',count(*) FILTER(WHERE revision.status='PENDING'
        AND replacement.is_tempo))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
   AND replacement.id=revision.replacement_sales_id
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
