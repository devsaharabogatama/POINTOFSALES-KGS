-- Inventory Pickup handover lifecycle closing gate.
-- SAFETY: SELECT-only.
WITH constraint_state AS (
  SELECT COALESCE(pg_get_constraintdef(constraint_row.oid),'') definition
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.sales_delivery_documents'::regclass
    AND constraint_row.conname='sales_delivery_document_lifecycle_check'
), checks AS (
  SELECT 'migration_ledger' check_name,
    CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::BIGINT violation_rows,
    jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260903130000'
  UNION ALL
  SELECT 'pickup_handover_constraint_contract',
    CASE WHEN count(*)=1 AND max(definition)~'fulfillment_mode.*PICKUP'
      AND max(definition)~'reservation_id IS NULL' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=1 AND max(definition)~'fulfillment_mode.*PICKUP'
      AND max(definition)~'reservation_id IS NULL' THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('constraintRows',count(*))
  FROM constraint_state
  UNION ALL
  SELECT 'pickup_transition_runtime_contract',
    CASE WHEN private.sales_delivery_transition_target(
      'READY','PICKUP','DELIVER',NULL)='DELIVERED' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN private.sales_delivery_transition_target(
      'READY','PICKUP','DELIVER',NULL)='DELIVERED' THEN 0 ELSE 1 END::BIGINT,
    jsonb_build_object('routineRows',1)
  UNION ALL
  SELECT 'pickup_ready_handover_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE delivery.fulfillment_mode='PICKUP' AND delivery.reservation_id IS NULL
    AND delivery.status='READY' AND (delivery.dispatched_at IS NOT NULL
      OR delivery.dispatched_by IS NOT NULL
      OR delivery.delivered_at IS NOT NULL OR delivery.delivered_by IS NOT NULL
      OR delivery.total_dispatched_base_qty<>0)
  UNION ALL
  SELECT 'legacy_pickup_delivered_shape',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE delivery.fulfillment_mode='PICKUP' AND delivery.reservation_id IS NULL
    AND delivery.status='DELIVERED' AND (delivery.dispatched_at IS NOT NULL
      OR delivery.dispatched_by IS NOT NULL OR delivery.delivered_at IS NULL
      OR delivery.delivered_by IS NULL OR delivery.total_dispatched_base_qty<>0)
  UNION ALL
  SELECT 'linked_pickup_dispatch_boundary',
    CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,count(*)::BIGINT,
    jsonb_build_object('rowCount',count(*))
  FROM public.sales_delivery_documents delivery
  WHERE delivery.fulfillment_mode='PICKUP' AND delivery.reservation_id IS NOT NULL
    AND delivery.status IN('DISPATCHED','DELIVERED')
    AND (delivery.dispatched_at IS NULL OR delivery.dispatched_by IS NULL
      OR delivery.total_dispatched_base_qty<=0)
  UNION ALL
  SELECT 'pickup_handover_runtime_inventory','INFO',0::BIGINT,
    jsonb_build_object(
      'legacyPickupReady',count(*) FILTER(WHERE fulfillment_mode='PICKUP'
        AND reservation_id IS NULL AND status='READY'),
      'legacyPickupDelivered',count(*) FILTER(WHERE fulfillment_mode='PICKUP'
        AND reservation_id IS NULL AND status='DELIVERED'),
      'linkedPickupOpen',count(*) FILTER(WHERE fulfillment_mode='PICKUP'
        AND reservation_id IS NOT NULL
        AND status IN('READY','PARTIALLY_DISPATCHED','DISPATCHED')))
  FROM public.sales_delivery_documents
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'PASS' THEN 2 ELSE 3 END,check_name;
