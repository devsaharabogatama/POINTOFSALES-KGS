-- Step 4/6.5C2A: accepted-overage Invoice-line allocation foundation only.
BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912122000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: reconstruction transfer required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260912123000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912123000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines
    WHERE requested_resolution='ACCEPT_OVERAGE'
      AND commercial_approval_status='APPROVED' AND warehouse_resolution_status='RESOLVED') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: resolved accepted overage requires reconciliation';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  ADD COLUMN accepted_overage_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN draft_overage_invoice_allocated_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN invoiced_overage_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN overage_to_invoice_base_qty numeric(24,6)
    GENERATED ALWAYS AS (accepted_overage_base_qty
      -draft_overage_invoice_allocated_base_qty-invoiced_overage_base_qty) STORED,
  ADD CONSTRAINT bo_sales_discrepancy_overage_invoiceable_check CHECK(
    accepted_overage_base_qty>=0 AND draft_overage_invoice_allocated_base_qty>=0
    AND invoiced_overage_base_qty>=0
    AND draft_overage_invoice_allocated_base_qty+invoiced_overage_base_qty
      <=accepted_overage_base_qty
    AND ((requested_resolution='ACCEPT_OVERAGE'
      AND accepted_overage_base_qty<=quantity_base
      AND (accepted_overage_base_qty=0 OR (commercial_approval_status='APPROVED'
        AND warehouse_resolution_status='RESOLVED')))
      OR (requested_resolution<>'ACCEPT_OVERAGE' AND accepted_overage_base_qty=0
        AND draft_overage_invoice_allocated_base_qty=0
        AND invoiced_overage_base_qty=0)));

ALTER TABLE public.backoffice_sales_invoice_lines
  ADD COLUMN source_kind text NOT NULL DEFAULT 'SALES_ORDER',
  ADD COLUMN discrepancy_line_id uuid,
  ADD CONSTRAINT bo_sales_invoice_lines_discrepancy_fk
    FOREIGN KEY(company_id,discrepancy_line_id)
    REFERENCES public.backoffice_sales_delivery_discrepancy_lines(company_id,id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT bo_sales_invoice_lines_source_check CHECK(
    (source_kind='SALES_ORDER' AND discrepancy_line_id IS NULL)
    OR (source_kind='ACCEPTED_OVERAGE' AND discrepancy_line_id IS NOT NULL
      AND line_type='PRODUCT' AND effect_type='CHARGE'));

ALTER TABLE public.backoffice_sales_invoice_quantity_allocations
  ADD COLUMN source_kind text NOT NULL DEFAULT 'SALES_ORDER',
  ADD COLUMN discrepancy_line_id uuid,
  ADD CONSTRAINT bo_sales_invoice_qty_discrepancy_fk
    FOREIGN KEY(company_id,discrepancy_line_id)
    REFERENCES public.backoffice_sales_delivery_discrepancy_lines(company_id,id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT bo_sales_invoice_qty_source_check CHECK(
    (source_kind='SALES_ORDER' AND discrepancy_line_id IS NULL)
    OR (source_kind='ACCEPTED_OVERAGE' AND discrepancy_line_id IS NOT NULL)),
  ADD CONSTRAINT bo_sales_invoice_qty_overage_unique
    UNIQUE(company_id,invoice_id,discrepancy_line_id);

CREATE FUNCTION private.validate_backoffice_sales_invoice_overage_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_line record;v_source record;
BEGIN
  IF NEW.source_kind='SALES_ORDER' THEN RETURN NEW; END IF;
  SELECT line.source_kind,line.discrepancy_line_id,line.sales_order_id,
    line.sales_order_line_id,line.product_id,line.uom_id,line.quantity_base
  INTO STRICT v_line FROM public.backoffice_sales_invoice_lines line
  WHERE line.company_id=NEW.company_id AND line.id=NEW.invoice_line_id;
  SELECT discrepancy.sales_order_id,discrepancy.sales_order_line_id,
    discrepancy.expected_product_id,discrepancy.uom_id,
    discrepancy.overage_to_invoice_base_qty
  INTO STRICT v_source FROM public.backoffice_sales_delivery_discrepancy_lines discrepancy
  WHERE discrepancy.company_id=NEW.company_id AND discrepancy.id=NEW.discrepancy_line_id
    AND discrepancy.requested_resolution='ACCEPT_OVERAGE'
    AND discrepancy.commercial_approval_status='APPROVED'
    AND discrepancy.warehouse_resolution_status='RESOLVED' FOR UPDATE;
  IF v_line.source_kind<>'ACCEPTED_OVERAGE'
    OR v_line.discrepancy_line_id<>NEW.discrepancy_line_id
    OR v_line.sales_order_id<>v_source.sales_order_id
    OR v_line.sales_order_line_id<>v_source.sales_order_line_id
    OR v_line.product_id<>v_source.expected_product_id OR v_line.uom_id<>v_source.uom_id
    OR NEW.allocated_base_qty<>v_line.quantity_base
    OR NEW.allocated_base_qty>v_source.overage_to_invoice_base_qty THEN
    RAISE EXCEPTION 'BACKOFFICE_ACCEPTED_OVERAGE_INVOICE_SOURCE_INVALID';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_invoice_overage_source_validate
BEFORE INSERT OR UPDATE ON public.backoffice_sales_invoice_quantity_allocations
FOR EACH ROW EXECUTE FUNCTION private.validate_backoffice_sales_invoice_overage_source();

REVOKE ALL ON FUNCTION private.validate_backoffice_sales_invoice_overage_source()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.validate_backoffice_sales_invoice_overage_source()
  TO service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912123000','backoffice_sales_accepted_overage_invoice_line_foundation',
  'Step 4/6.5C2A adds separate accepted-overage Invoice source and allocation counters; no resolver/save/post/UI mutation');
NOTIFY pgrst,'reload schema';
COMMIT;
