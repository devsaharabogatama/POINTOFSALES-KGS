-- Sales Order revision Order-date preservation preflight.
-- SAFETY: SELECT-only. No operational row is changed.
WITH revision_runtime AS (
  SELECT lower(regexp_replace(COALESCE(pg_get_functiondef(to_regprocedure(
    'public.start_pos_sales_order_revision(uuid,bigint,uuid,uuid,text)')),''),
    '[[:space:]]+','','g')) definition
), pending_mismatch AS (
  SELECT revision.id,revision.company_id,source.draft_no source_order_no,
    replacement.draft_no replacement_draft_no,
    source.transaction_date source_transaction_date,
    replacement.transaction_date replacement_transaction_date
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
   AND replacement.id=revision.replacement_sales_id
  WHERE revision.status='PENDING'
    AND (replacement.transaction_date IS DISTINCT FROM source.transaction_date
      OR replacement.transaction_date_source IS DISTINCT FROM
        source.transaction_date_source
      OR replacement.transaction_date_selected_by IS DISTINCT FROM
        source.transaction_date_selected_by
      OR replacement.transaction_date_selected_at IS DISTINCT FROM
        source.transaction_date_selected_at)
), checks AS (
  SELECT 'revision_order_date_dependencies'::TEXT check_name,
    CASE WHEN count(*)=5 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('expected',5,'ledgerRows',count(*),
      'requiredVersions',ARRAY['20260903100000','20260903110000',
        '20260903120000','20260904110000','20260904120000']) details
  FROM private.kgs_schema_migrations WHERE version IN(
    '20260903100000','20260903110000','20260903120000',
    '20260904110000','20260904120000')
  UNION ALL
  SELECT 'canonical_revision_start_runtime',
    CASE WHEN definition<>'' AND position('save_pos_sale_draft_with_pricelist'
      IN definition)>0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('routineRows',CASE WHEN definition='' THEN 0 ELSE 1 END)
  FROM revision_runtime
  UNION ALL
  SELECT 'pending_revision_date_identity',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('mismatchRows',count(*),
      'resolution','abandon pending mismatch and restart after migration')
  FROM pending_mismatch
  UNION ALL
  SELECT 'pending_revision_zero_final_effect',
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
  SELECT 'revision_order_date_runtime_inventory','INFO',
    jsonb_build_object('pendingRevisions',count(*) FILTER(
        WHERE revision.status='PENDING'),
      'appliedRevisions',count(*) FILTER(WHERE revision.status='APPLIED'),
      'pendingDateMismatches',(SELECT count(*) FROM pending_mismatch),
      'historicalAppliedDateMismatches',count(*) FILTER(
        WHERE revision.status='APPLIED' AND
          replacement.transaction_date IS DISTINCT FROM source.transaction_date))
  FROM public.sales_order_revisions revision
  JOIN public.sales_headers source ON source.company_id=revision.company_id
    AND source.id=revision.source_sales_id
  JOIN public.sales_headers replacement
    ON replacement.company_id=revision.company_id
   AND replacement.id=revision.replacement_sales_id
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,
  check_name;

