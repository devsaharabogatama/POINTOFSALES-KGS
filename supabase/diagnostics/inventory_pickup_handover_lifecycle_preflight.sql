-- Inventory Pickup handover lifecycle forward-fix preflight.
-- SAFETY: SELECT-only. No operational row is changed.
WITH current_constraint AS (
  SELECT pg_get_constraintdef(constraint_row.oid) definition
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.sales_delivery_documents'::regclass
    AND constraint_row.conname='sales_delivery_document_lifecycle_check'
), checks AS (
  SELECT 'active_finance_posting_queue' check_name,
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END status,
    jsonb_build_object('runCount',count(*)) details
  FROM public.finance_posting_queue_runs
  WHERE status IN('PREVIEWED','APPROVED','PROCESSING')
  UNION ALL
  SELECT 'nonterminal_offline_submission',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('submissionCount',count(*))
  FROM public.pos_offline_sale_submissions
  WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  UNION ALL
  SELECT 'pickup_handover_dependency',
    CASE WHEN count(*)=3 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('expected',3,'ledgerRows',count(*),
      'requiredVersions',ARRAY[
        '20260827153000','20260828140000','20260903120000'])
  FROM private.kgs_schema_migrations
  WHERE version IN('20260827153000','20260828140000','20260903120000')
  UNION ALL
  SELECT 'pickup_ready_handover_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'BLOCKER' END,
    jsonb_build_object('invalidRows',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE delivery.fulfillment_mode='PICKUP' AND delivery.reservation_id IS NULL
    AND delivery.status='READY' AND (delivery.dispatched_at IS NOT NULL
      OR delivery.dispatched_by IS NOT NULL
      OR delivery.delivered_at IS NOT NULL OR delivery.delivered_by IS NOT NULL
      OR delivery.canceled_at IS NOT NULL OR delivery.canceled_by IS NOT NULL
      OR delivery.total_dispatched_base_qty<>0)
  UNION ALL
  SELECT 'pickup_handover_constraint_state',
    CASE WHEN EXISTS(SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260903130000') THEN 'PASS' ELSE 'SETUP' END,
    jsonb_build_object('constraintRows',count(*),
      'currentDefinition',max(definition))
  FROM current_constraint
  UNION ALL
  SELECT 'pickup_handover_runtime_inventory','INFO',jsonb_build_object(
    'legacyPickupReady',count(*) FILTER(WHERE reservation_id IS NULL
      AND fulfillment_mode='PICKUP' AND status='READY'),
    'linkedPickupReady',count(*) FILTER(WHERE reservation_id IS NOT NULL
      AND fulfillment_mode='PICKUP' AND status IN('READY','PARTIALLY_DISPATCHED')),
    'legacyPickupDelivered',count(*) FILTER(WHERE reservation_id IS NULL
      AND fulfillment_mode='PICKUP' AND status='DELIVERED'))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 1 WHEN 'SETUP' THEN 2
  WHEN 'PASS' THEN 3 ELSE 4 END,check_name;
