-- Additive foundation for clean Backoffice Customer receipt and quantity-to-invoice.
-- This gate creates no receipt runtime, Stock Movement, Financial Event, Journal,
-- Invoice, Payment, Stock Movement vocabulary, or historical backfill.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909151000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Dispatch to Transit required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909152000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909152000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_sales_delivery_receipts') IS NOT NULL
    OR to_regclass('public.backoffice_sales_delivery_receipt_lines') IS NOT NULL
    OR to_regclass('public.backoffice_sales_receipt_fifo_allocations') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer receipt relation collision';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='backoffice_sales_order_lines'
      AND column_name IN('accepted_base_qty','returned_before_invoice_base_qty',
        'draft_invoice_allocated_base_qty','invoiced_base_qty',
        'net_delivered_base_qty','to_invoice_base_qty')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: quantity ledger column collision';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_order_lines
  ADD COLUMN accepted_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN returned_before_invoice_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN draft_invoice_allocated_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN invoiced_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN net_delivered_base_qty numeric(24,6)
    GENERATED ALWAYS AS (accepted_base_qty-returned_before_invoice_base_qty) STORED,
  ADD COLUMN to_invoice_base_qty numeric(24,6)
    GENERATED ALWAYS AS (accepted_base_qty-returned_before_invoice_base_qty
      -draft_invoice_allocated_base_qty-invoiced_base_qty) STORED,
  ADD CONSTRAINT backoffice_sales_order_lines_invoiceable_quantity_check CHECK(
    accepted_base_qty>=0 AND accepted_base_qty<=ordered_base_qty
    AND returned_before_invoice_base_qty>=0
    AND returned_before_invoice_base_qty<=accepted_base_qty
    AND draft_invoice_allocated_base_qty>=0 AND invoiced_base_qty>=0
    AND draft_invoice_allocated_base_qty+invoiced_base_qty
      <=accepted_base_qty-returned_before_invoice_base_qty);

CREATE TABLE public.backoffice_sales_delivery_receipts(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  receipt_no text NOT NULL,
  delivery_order_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  request_payload jsonb NOT NULL,
  result_payload jsonb NOT NULL,
  transit_warehouse_id uuid NOT NULL,
  accepted_date date NOT NULL,
  total_received_base_qty numeric(24,6) NOT NULL,
  total_fifo_cost numeric(24,4) NOT NULL,
  financial_event_id uuid,
  notes text,
  accepted_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_delivery_receipts_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_receipts_lineage_unique
    UNIQUE(company_id,id,delivery_order_id,sales_order_id,reservation_id),
  CONSTRAINT backoffice_sales_delivery_receipts_number_unique UNIQUE(company_id,receipt_no),
  CONSTRAINT backoffice_sales_delivery_receipts_delivery_unique
    UNIQUE(company_id,delivery_order_id),
  CONSTRAINT backoffice_sales_delivery_receipts_operation_unique
    UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_delivery_receipts_event_unique
    UNIQUE(company_id,financial_event_id),
  CONSTRAINT backoffice_sales_delivery_receipts_delivery_fk
    FOREIGN KEY(company_id,sales_order_id,delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipts_reservation_fk
    FOREIGN KEY(company_id,reservation_id,sales_order_id)
    REFERENCES public.backoffice_sales_reservations(company_id,id,sales_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipts_transit_fk
    FOREIGN KEY(company_id,transit_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipts_event_fk
    FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipts_shape_check CHECK(
    nullif(btrim(receipt_no),'') IS NOT NULL
    AND jsonb_typeof(request_payload)='object'
    AND jsonb_typeof(result_payload)='object'
    AND total_received_base_qty>0 AND total_fifo_cost>=0)
);

CREATE TABLE public.backoffice_sales_delivery_receipt_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  delivery_order_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  reservation_line_id uuid NOT NULL,
  delivery_order_line_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  product_id uuid NOT NULL,
  uom_id uuid NOT NULL,
  received_qty_uom numeric(24,6) NOT NULL,
  received_base_qty numeric(24,6) NOT NULL,
  fifo_cost_total numeric(24,4) NOT NULL,
  stock_movement_id uuid NOT NULL REFERENCES public.stock_movements(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_delivery_receipt_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_receipt_lines_source_unique
    UNIQUE(company_id,receipt_id,delivery_order_line_id),
  CONSTRAINT backoffice_sales_delivery_receipt_lines_movement_unique
    UNIQUE(company_id,stock_movement_id),
  CONSTRAINT backoffice_sales_delivery_receipt_lines_header_fk
    FOREIGN KEY(company_id,receipt_id,delivery_order_id,sales_order_id,reservation_id)
    REFERENCES public.backoffice_sales_delivery_receipts(
      company_id,id,delivery_order_id,sales_order_id,reservation_id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipt_lines_delivery_line_fk
    FOREIGN KEY(company_id,delivery_order_line_id)
    REFERENCES public.backoffice_sales_delivery_order_lines(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipt_lines_reservation_line_fk
    FOREIGN KEY(company_id,reservation_line_id)
    REFERENCES public.backoffice_sales_reservation_lines(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipt_lines_order_line_fk
    FOREIGN KEY(company_id,sales_order_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipt_lines_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipt_lines_uom_fk
    FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_receipt_lines_quantity_check CHECK(
    received_qty_uom>0 AND received_base_qty>0 AND fifo_cost_total>=0)
);

CREATE TABLE public.backoffice_sales_receipt_fifo_allocations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  receipt_id uuid NOT NULL,
  receipt_line_id uuid NOT NULL,
  transit_batch_id uuid NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  unit_cost numeric(24,4) NOT NULL,
  total_cost numeric(24,4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_receipt_fifo_allocations_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_receipt_fifo_allocations_source_unique
    UNIQUE(company_id,receipt_line_id,transit_batch_id),
  CONSTRAINT backoffice_sales_receipt_fifo_allocations_receipt_line_fk
    FOREIGN KEY(company_id,receipt_line_id)
    REFERENCES public.backoffice_sales_delivery_receipt_lines(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_receipt_fifo_allocations_receipt_fk
    FOREIGN KEY(company_id,receipt_id)
    REFERENCES public.backoffice_sales_delivery_receipts(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_receipt_fifo_allocations_batch_fk
    FOREIGN KEY(company_id,transit_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_receipt_fifo_allocations_cost_check CHECK(
    quantity_base>0 AND unit_cost>=0
    AND total_cost=round(quantity_base*unit_cost,4))
);

CREATE INDEX backoffice_sales_delivery_receipts_order_date
  ON public.backoffice_sales_delivery_receipts(company_id,sales_order_id,accepted_date,id);
CREATE INDEX backoffice_sales_delivery_receipt_lines_order_line
  ON public.backoffice_sales_delivery_receipt_lines(company_id,sales_order_line_id,id);
CREATE INDEX backoffice_sales_receipt_fifo_allocations_batch
  ON public.backoffice_sales_receipt_fifo_allocations(company_id,transit_batch_id,id);

CREATE FUNCTION private.trg_guard_backoffice_sales_customer_receipt()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_CUSTOMER_RECEIPT_IMMUTABLE';
END
$$;

CREATE TRIGGER backoffice_sales_delivery_receipts_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_delivery_receipts
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_customer_receipt();
CREATE TRIGGER backoffice_sales_delivery_receipt_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_delivery_receipt_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_customer_receipt();
CREATE TRIGGER backoffice_sales_receipt_fifo_allocations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_receipt_fifo_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_customer_receipt();

ALTER TABLE public.backoffice_sales_delivery_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_delivery_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_receipt_fifo_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.backoffice_sales_delivery_receipts,
  public.backoffice_sales_delivery_receipt_lines,
  public.backoffice_sales_receipt_fifo_allocations FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.backoffice_sales_delivery_receipts,
  public.backoffice_sales_delivery_receipt_lines,
  public.backoffice_sales_receipt_fifo_allocations TO service_role;
REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_customer_receipt()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_customer_receipt()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909152000','backoffice_sales_customer_receipt_foundation',
  'Clean Customer receipt and Qty To Invoice schema foundation only; runtime, Stock sale-out, Finance and Invoice remain disabled');

NOTIFY pgrst,'reload schema';
COMMIT;
