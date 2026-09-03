-- Restore the approved direct handover lifecycle for legacy Pickup documents.
-- Linked ODR Pickup remains dispatch-first and keeps canonical stock effects.
BEGIN;

DO $guard$
DECLARE v_definition TEXT;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260903130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260903130000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN(
        '20260827153000','20260828140000','20260903120000'))<>3
    OR to_regprocedure(
      'private.sales_delivery_transition_target(text,text,text,text)') IS NULL
    OR to_regprocedure(
      'private.acp5e_update_sales_delivery_status_odr3_legacy(uuid,bigint,text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: delivery lifecycle runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  SELECT pg_get_constraintdef(constraint_row.oid) INTO v_definition
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid='public.sales_delivery_documents'::regclass
    AND constraint_row.conname='sales_delivery_document_lifecycle_check';
  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: delivery lifecycle constraint missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_delivery_documents delivery
    WHERE NOT (
      (delivery.status='READY' AND delivery.dispatched_at IS NULL
        AND delivery.delivered_at IS NULL AND delivery.canceled_at IS NULL
        AND delivery.total_dispatched_base_qty=0)
      OR (delivery.status='PARTIALLY_DISPATCHED'
        AND delivery.dispatched_at IS NOT NULL
        AND delivery.dispatched_by IS NOT NULL
        AND delivery.delivered_at IS NULL AND delivery.canceled_at IS NULL
        AND delivery.reservation_id IS NOT NULL
        AND delivery.total_dispatched_base_qty>0)
      OR (delivery.status='DISPATCHED'
        AND delivery.dispatched_at IS NOT NULL
        AND delivery.dispatched_by IS NOT NULL
        AND delivery.delivered_at IS NULL AND delivery.canceled_at IS NULL
        AND ((delivery.reservation_id IS NULL
            AND delivery.total_dispatched_base_qty=0)
          OR (delivery.reservation_id IS NOT NULL
            AND delivery.total_dispatched_base_qty>0)))
      OR (delivery.status='DELIVERED' AND delivery.delivered_at IS NOT NULL
        AND delivery.delivered_by IS NOT NULL AND delivery.canceled_at IS NULL
        AND ((delivery.reservation_id IS NOT NULL
            AND delivery.dispatched_at IS NOT NULL
            AND delivery.dispatched_by IS NOT NULL
            AND delivery.total_dispatched_base_qty>0)
          OR (delivery.reservation_id IS NULL
            AND delivery.total_dispatched_base_qty=0
            AND ((delivery.fulfillment_mode='DELIVERY'
                AND delivery.dispatched_at IS NOT NULL
                AND delivery.dispatched_by IS NOT NULL)
              OR (delivery.fulfillment_mode='PICKUP'
                AND delivery.dispatched_at IS NULL
                AND delivery.dispatched_by IS NULL)))))
      OR (delivery.status='CANCELED' AND delivery.canceled_at IS NOT NULL
        AND delivery.canceled_by IS NOT NULL
        AND COALESCE(btrim(delivery.cancel_reason),'')<>''
        AND delivery.total_dispatched_base_qty=0))) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: invalid delivery lifecycle row';
  END IF;
END
$guard$;

ALTER TABLE public.sales_delivery_documents
  DROP CONSTRAINT sales_delivery_document_lifecycle_check,
  ADD CONSTRAINT sales_delivery_document_lifecycle_check CHECK(
    (status='READY' AND dispatched_at IS NULL AND delivered_at IS NULL
      AND canceled_at IS NULL AND total_dispatched_base_qty=0)
    OR (status='PARTIALLY_DISPATCHED'
      AND dispatched_at IS NOT NULL AND dispatched_by IS NOT NULL
      AND delivered_at IS NULL AND canceled_at IS NULL
      AND reservation_id IS NOT NULL AND total_dispatched_base_qty>0)
    OR (status='DISPATCHED'
      AND dispatched_at IS NOT NULL AND dispatched_by IS NOT NULL
      AND delivered_at IS NULL AND canceled_at IS NULL
      AND ((reservation_id IS NULL AND total_dispatched_base_qty=0)
        OR (reservation_id IS NOT NULL AND total_dispatched_base_qty>0)))
    OR (status='DELIVERED' AND delivered_at IS NOT NULL
      AND delivered_by IS NOT NULL AND canceled_at IS NULL
      AND ((reservation_id IS NOT NULL AND dispatched_at IS NOT NULL
          AND dispatched_by IS NOT NULL AND total_dispatched_base_qty>0)
        OR (reservation_id IS NULL AND total_dispatched_base_qty=0
          AND ((fulfillment_mode='DELIVERY' AND dispatched_at IS NOT NULL
              AND dispatched_by IS NOT NULL)
            OR (fulfillment_mode='PICKUP' AND dispatched_at IS NULL
              AND dispatched_by IS NULL)))))
    OR (status='CANCELED' AND canceled_at IS NOT NULL
      AND canceled_by IS NOT NULL AND COALESCE(btrim(cancel_reason),'')<>''
      AND total_dispatched_base_qty=0));

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260903130000','inventory_pickup_handover_lifecycle_fix',
  'Permit only unlinked Pickup READY to complete direct handover without Dispatch markers; linked ODR Pickup and every Delivery remain dispatch-first; no operational backfill');

NOTIFY pgrst,'reload schema';
COMMIT;
