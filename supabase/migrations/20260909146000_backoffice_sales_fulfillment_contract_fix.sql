-- Align the empty Backoffice fulfillment foundation with the approved contract:
-- Initial DO starts READY; only Backorder creates another DO. Corrections before
-- receipt stay as discrepancy activity on the same DO; after completion use Return.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909145000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: fulfillment foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909146000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909146000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_reservations)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: fulfillment foundation is not empty';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_delivery_orders
  ALTER COLUMN status SET DEFAULT 'READY',
  DROP CONSTRAINT backoffice_sales_delivery_orders_kind_check,
  ADD CONSTRAINT backoffice_sales_delivery_orders_kind_check CHECK(
    (delivery_kind='INITIAL' AND parent_delivery_order_id IS NULL)
    OR (delivery_kind='BACKORDER' AND parent_delivery_order_id IS NOT NULL));

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909146000','backoffice_sales_fulfillment_contract_fix',
  'Initial Delivery defaults READY; only BACKORDER may create a child Delivery; pre-receipt correction remains discrepancy on the same Delivery and completed correction uses Return');

COMMIT;
