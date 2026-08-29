BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-2 dependency missing';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
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

ALTER TABLE public.sales_delivery_documents
  ADD COLUMN reservation_id UUID,
  ADD COLUMN dispatch_version BIGINT NOT NULL DEFAULT 0,
  ADD COLUMN total_dispatched_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0;

ALTER TABLE public.sales_delivery_documents
  ADD CONSTRAINT fk_sales_delivery_reservation
    FOREIGN KEY(company_id,reservation_id)
    REFERENCES public.sales_stock_reservations(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT sales_delivery_dispatch_version_nonnegative
    CHECK(dispatch_version>=0),
  ADD CONSTRAINT sales_delivery_dispatched_quantity_nonnegative
    CHECK(total_dispatched_base_qty>=0);

CREATE UNIQUE INDEX uq_sales_delivery_reservation
  ON public.sales_delivery_documents(company_id,reservation_id)
  WHERE reservation_id IS NOT NULL;

ALTER TABLE public.sales_delivery_documents
  DROP CONSTRAINT sales_delivery_document_status_check,
  DROP CONSTRAINT sales_delivery_document_lifecycle_check;

ALTER TABLE public.sales_delivery_documents
  ADD CONSTRAINT sales_delivery_document_status_check CHECK(status IN(
    'READY','PARTIALLY_DISPATCHED','DISPATCHED','DELIVERED','CANCELED')),
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
    OR (status='DELIVERED' AND dispatched_at IS NOT NULL
      AND dispatched_by IS NOT NULL AND delivered_at IS NOT NULL
      AND delivered_by IS NOT NULL AND canceled_at IS NULL
      AND ((reservation_id IS NULL AND total_dispatched_base_qty=0)
        OR (reservation_id IS NOT NULL AND total_dispatched_base_qty>0)))
    OR (status='CANCELED' AND canceled_at IS NOT NULL
      AND canceled_by IS NOT NULL AND COALESCE(btrim(cancel_reason),'')<>''
      AND total_dispatched_base_qty=0));

CREATE TABLE public.sales_dispatch_allocations(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  delivery_document_id UUID NOT NULL,
  delivery_line_id UUID NOT NULL,
  reservation_id UUID NOT NULL,
  reservation_line_id UUID NOT NULL,
  dispatch_idempotency_key UUID NOT NULL,
  allocation_no INTEGER NOT NULL,
  allocation_kind TEXT NOT NULL,
  dispatched_base_qty NUMERIC(24,6) NOT NULL,
  fifo_batch_id UUID,
  stock_movement_id UUID,
  unit_cost_snapshot NUMERIC(24,6),
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_dispatch_allocations_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT sales_dispatch_allocation_operation_unique UNIQUE(
    company_id,delivery_document_id,dispatch_idempotency_key,allocation_no),
  CONSTRAINT sales_dispatch_allocation_shape CHECK(
    allocation_no>0 AND allocation_kind IN('FIFO','NEGATIVE')
    AND dispatched_base_qty>0
    AND ((allocation_kind='FIFO' AND fifo_batch_id IS NOT NULL
      AND unit_cost_snapshot IS NOT NULL AND unit_cost_snapshot>=0)
      OR (allocation_kind='NEGATIVE' AND fifo_batch_id IS NULL
        AND unit_cost_snapshot IS NULL))),
  CONSTRAINT fk_sales_dispatch_allocation_delivery FOREIGN KEY(company_id,delivery_document_id)
    REFERENCES public.sales_delivery_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_dispatch_allocation_delivery_line FOREIGN KEY(company_id,delivery_line_id)
    REFERENCES public.sales_delivery_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_dispatch_allocation_reservation FOREIGN KEY(company_id,reservation_id)
    REFERENCES public.sales_stock_reservations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_dispatch_allocation_reservation_line FOREIGN KEY(company_id,reservation_line_id)
    REFERENCES public.sales_stock_reservation_lines(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sales_dispatch_allocation_reservation
  ON public.sales_dispatch_allocations(company_id,reservation_id,reservation_line_id);
CREATE INDEX idx_sales_dispatch_allocation_document
  ON public.sales_dispatch_allocations(company_id,delivery_document_id,delivery_line_id);

CREATE FUNCTION private.trg_odr_guard_dispatch_allocation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'SALES_DISPATCH_ALLOCATION_IMMUTABLE';
END
$$;

CREATE TRIGGER trg_odr_guard_dispatch_allocation
BEFORE UPDATE OR DELETE ON public.sales_dispatch_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_odr_guard_dispatch_allocation();

ALTER TABLE public.sales_dispatch_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_dispatch_allocations FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.sales_dispatch_allocations TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828120000','odr_phase3a_delivery_dispatch_foundation',
  'Additive reservation-to-Delivery linkage, partial dispatch lifecycle, immutable dispatch allocation evidence and browser write boundary; no stock, FIFO, Movement, document, or Finance row is mutated');

COMMIT;
