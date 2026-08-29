BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828170000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-4C required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828180000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regclass('public.sales_order_procurement_amendments') IS NOT NULL
    OR to_regclass('public.sales_order_procurement_amendment_audit') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: amendment relation exists';
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

CREATE TABLE public.sales_order_procurement_amendments(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  demand_id UUID NOT NULL,
  stock_request_document_id UUID NOT NULL,
  stock_request_line_id UUID NOT NULL,
  product_id UUID NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  desired_base_qty NUMERIC(24,6) NOT NULL,
  draft_allocated_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  final_allocated_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  delta_base_qty NUMERIC(24,6) NOT NULL,
  source_demand_version BIGINT NOT NULL,
  resolution_supplier_order_id UUID,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  resolved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  resolved_at TIMESTAMPTZ,
  master_version BIGINT NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_order_procurement_amendments_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT sales_order_procurement_amendments_reason_check CHECK(reason IN(
    'UNALLOCATED','AMBIGUOUS_DRAFT_TARGET','MIXED_MANUAL_DRAFT_LINE',
    'FINAL_PO_IMMUTABLE','QUANTITY_DECREASE_REQUIRES_REVIEW')),
  CONSTRAINT sales_order_procurement_amendments_status_check
    CHECK(status IN('OPEN','RESOLVED','CANCELED')),
  CONSTRAINT sales_order_procurement_amendments_quantity_check CHECK(
    desired_base_qty>=0 AND draft_allocated_base_qty>=0
    AND final_allocated_base_qty>=0
    AND delta_base_qty=desired_base_qty-draft_allocated_base_qty
      -final_allocated_base_qty),
  CONSTRAINT sales_order_procurement_amendments_version_check CHECK(
    source_demand_version>0 AND master_version>0),
  CONSTRAINT sales_order_procurement_amendments_resolution_shape CHECK(
    (status='OPEN' AND resolved_by IS NULL AND resolved_at IS NULL)
    OR (status IN('RESOLVED','CANCELED')
      AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL)),
  CONSTRAINT fk_sales_order_procurement_amendment_demand
    FOREIGN KEY(company_id,demand_id)
    REFERENCES public.sales_order_procurement_demands(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_amendment_request
    FOREIGN KEY(company_id,stock_request_document_id)
    REFERENCES public.stock_request_documents(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_amendment_request_line
    FOREIGN KEY(company_id,stock_request_line_id)
    REFERENCES public.stock_request_lines(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_amendment_product
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_amendment_resolution_order
    FOREIGN KEY(company_id,resolution_supplier_order_id)
    REFERENCES public.supplier_order_documents(company_id,id)
    ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_sales_order_procurement_amendment_open_line
  ON public.sales_order_procurement_amendments(
    company_id,stock_request_line_id)
  WHERE status='OPEN';
CREATE INDEX idx_sales_order_procurement_amendment_workspace
  ON public.sales_order_procurement_amendments(
    company_id,status,reason,updated_at DESC);

CREATE TABLE public.sales_order_procurement_amendment_audit(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id UUID NOT NULL,
  amendment_id UUID NOT NULL,
  action TEXT NOT NULL,
  idempotency_key UUID NOT NULL,
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_order_procurement_amendment_audit_action_check
    CHECK(action IN('OPEN','REFRESH','RESOLVE','CANCEL')),
  CONSTRAINT sales_order_procurement_amendment_audit_operation_unique
    UNIQUE(company_id,amendment_id,idempotency_key),
  CONSTRAINT fk_sales_order_procurement_amendment_audit_parent
    FOREIGN KEY(company_id,amendment_id)
    REFERENCES public.sales_order_procurement_amendments(company_id,id)
    ON DELETE RESTRICT
);

CREATE FUNCTION private.trg_odr_guard_procurement_amendment()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'PROCUREMENT_AMENDMENT_DELETE_FORBIDDEN';
  END IF;
  IF TG_OP='UPDATE' AND (NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.demand_id IS DISTINCT FROM OLD.demand_id
    OR NEW.stock_request_document_id IS DISTINCT FROM OLD.stock_request_document_id
    OR NEW.stock_request_line_id IS DISTINCT FROM OLD.stock_request_line_id
    OR NEW.product_id IS DISTINCT FROM OLD.product_id
    OR NEW.created_by IS DISTINCT FROM OLD.created_by
    OR NEW.created_at IS DISTINCT FROM OLD.created_at) THEN
    RAISE EXCEPTION 'PROCUREMENT_AMENDMENT_IDENTITY_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND OLD.status IN('RESOLVED','CANCELED') THEN
    RAISE EXCEPTION 'FINAL_PROCUREMENT_AMENDMENT_IMMUTABLE';
  END IF;
  IF NOT EXISTS(SELECT 1
    FROM public.sales_order_procurement_demands demand
    JOIN public.stock_request_documents request
      ON request.company_id=demand.company_id
     AND request.id=demand.stock_request_document_id
    JOIN public.stock_request_lines request_line
      ON request_line.company_id=request.company_id
     AND request_line.document_id=request.id
     AND request_line.id=NEW.stock_request_line_id
    WHERE demand.company_id=NEW.company_id AND demand.id=NEW.demand_id
      AND request.id=NEW.stock_request_document_id
      AND request.request_source='SALES_ORDER_RESERVATION'
      AND request_line.product_id=NEW.product_id) THEN
    RAISE EXCEPTION 'PROCUREMENT_AMENDMENT_LINEAGE_INVALID';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_odr_guard_procurement_amendment
BEFORE INSERT OR UPDATE OR DELETE
ON public.sales_order_procurement_amendments
FOR EACH ROW EXECUTE FUNCTION private.trg_odr_guard_procurement_amendment();

CREATE FUNCTION private.trg_odr_guard_procurement_amendment_audit()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PROCUREMENT_AMENDMENT_AUDIT_IMMUTABLE';
END
$$;
CREATE TRIGGER trg_odr_guard_procurement_amendment_audit
BEFORE UPDATE OR DELETE ON public.sales_order_procurement_amendment_audit
FOR EACH ROW EXECUTE FUNCTION
  private.trg_odr_guard_procurement_amendment_audit();

ALTER TABLE public.sales_order_procurement_amendments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_procurement_amendment_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_order_procurement_amendments,
  public.sales_order_procurement_amendment_audit
FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.sales_order_procurement_amendments,
  public.sales_order_procurement_amendment_audit TO service_role;

REVOKE ALL ON FUNCTION
  private.trg_odr_guard_procurement_amendment(),
  private.trg_odr_guard_procurement_amendment_audit()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_odr_guard_procurement_amendment(),
  private.trg_odr_guard_procurement_amendment_audit()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828180000','odr_phase4d_amendment_foundation',
  'Additive immutable Purchasing delta/amendment notice and audit foundation for managed Session demand; zero backfill and no Stock Request, Supplier Order, Stock, FIFO or Finance mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
