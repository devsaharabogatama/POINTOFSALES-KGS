BEGIN;

DO $guard$
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260828100000','20260828110000','20260828120000',
        '20260828130000','20260828140000'))<>5 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-2/ODR-3 dependency missing';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828150000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF to_regclass('public.sales_order_procurement_demands') IS NOT NULL
    OR to_regclass('public.sales_order_procurement_demand_lines') IS NOT NULL
    OR to_regclass('public.sales_order_procurement_demand_audit') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-4 demand relation exists';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id
     AND reservation.id=line.reservation_id
    WHERE reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
      AND line.shortage_base_qty>line.released_base_qty+
        line.dispatched_base_qty) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open reservation shortage requires reviewed backfill';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_request_lines request_line
    LEFT JOIN public.supplier_order_request_allocations allocation
      ON allocation.company_id=request_line.company_id
     AND allocation.stock_request_line_id=request_line.id
    LEFT JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    LEFT JOIN public.supplier_order_documents order_document
      ON order_document.company_id=order_line.company_id
     AND order_document.id=order_line.document_id
     AND order_document.status IN(
       'CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')
    GROUP BY request_line.company_id,request_line.id,
      request_line.requested_base_qty
    HAVING COALESCE(sum(allocation.allocated_base_qty)
      FILTER(WHERE order_document.id IS NOT NULL),0)
      > request_line.requested_base_qty) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: final PO allocation exceeds request';
  END IF;
END
$guard$;

CREATE TABLE public.sales_order_procurement_demands(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  store_id UUID NOT NULL,
  warehouse_id UUID NOT NULL,
  cashier_session_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  total_demand_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  total_released_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  stock_request_document_id UUID,
  master_version BIGINT NOT NULL DEFAULT 1,
  session_closed_at TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_order_procurement_demands_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT sales_order_procurement_demands_session_unique
    UNIQUE(company_id,cashier_session_id),
  CONSTRAINT sales_order_procurement_demands_request_unique
    UNIQUE(company_id,stock_request_document_id),
  CONSTRAINT sales_order_procurement_demands_status_check
    CHECK(status IN('OPEN','FROZEN','CLOSED')),
  CONSTRAINT sales_order_procurement_demands_quantity_check CHECK(
    total_demand_base_qty>=0 AND total_released_base_qty>=0
    AND total_released_base_qty<=total_demand_base_qty),
  CONSTRAINT sales_order_procurement_demands_version_positive
    CHECK(master_version>0),
  CONSTRAINT sales_order_procurement_demands_close_shape CHECK(
    (status='OPEN' AND session_closed_at IS NULL)
    OR (status IN('FROZEN','CLOSED') AND session_closed_at IS NOT NULL)),
  CONSTRAINT fk_sales_order_procurement_demand_company
    FOREIGN KEY(company_id) REFERENCES public.companies(id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_store
    FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_warehouse
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_session
    FOREIGN KEY(company_id,cashier_session_id)
    REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_request
    FOREIGN KEY(company_id,stock_request_document_id)
    REFERENCES public.stock_request_documents(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sales_order_procurement_demand_workspace
  ON public.sales_order_procurement_demands(
    company_id,status,store_id,warehouse_id,updated_at DESC);

CREATE TABLE public.sales_order_procurement_demand_lines(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  demand_id UUID NOT NULL,
  reservation_line_id UUID NOT NULL,
  sales_id UUID NOT NULL,
  stock_product_id UUID NOT NULL,
  warehouse_id UUID NOT NULL,
  demand_base_qty NUMERIC(24,6) NOT NULL,
  released_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  source_reservation_version BIGINT NOT NULL,
  stock_request_line_id UUID,
  status TEXT NOT NULL DEFAULT 'OPEN',
  master_version BIGINT NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_order_procurement_demand_lines_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT sales_order_procurement_demand_lines_reservation_unique
    UNIQUE(company_id,reservation_line_id),
  CONSTRAINT sales_order_procurement_demand_lines_request_unique
    UNIQUE(company_id,stock_request_line_id),
  CONSTRAINT sales_order_procurement_demand_lines_status_check
    CHECK(status IN('OPEN','REQUESTED','ORDERED','AMENDMENT_REQUIRED','CLOSED')),
  CONSTRAINT sales_order_procurement_demand_lines_quantity_check CHECK(
    demand_base_qty>0 AND released_base_qty>=0
    AND released_base_qty<=demand_base_qty),
  CONSTRAINT sales_order_procurement_demand_lines_version_check CHECK(
    source_reservation_version>0 AND master_version>0),
  CONSTRAINT fk_sales_order_procurement_demand_line_header
    FOREIGN KEY(company_id,demand_id)
    REFERENCES public.sales_order_procurement_demands(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_line_reservation
    FOREIGN KEY(company_id,reservation_line_id)
    REFERENCES public.sales_stock_reservation_lines(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_line_sale
    FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_line_product
    FOREIGN KEY(company_id,stock_product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_line_warehouse
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_line_request
    FOREIGN KEY(company_id,stock_request_line_id)
    REFERENCES public.stock_request_lines(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sales_order_procurement_demand_line_workspace
  ON public.sales_order_procurement_demand_lines(
    company_id,demand_id,status,stock_product_id);

CREATE TABLE public.sales_order_procurement_demand_audit(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id UUID NOT NULL,
  demand_id UUID NOT NULL,
  demand_line_id UUID,
  action TEXT NOT NULL,
  idempotency_key UUID NOT NULL,
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_order_procurement_demand_audit_action_check CHECK(action IN(
    'INITIALIZE','QUANTITY_DELTA','SESSION_FREEZE','REQUEST_LINK','DRAFT_PO_SYNC',
    'AMENDMENT_REQUIRED','CLOSE')),
  CONSTRAINT fk_sales_order_procurement_demand_audit_header
    FOREIGN KEY(company_id,demand_id)
    REFERENCES public.sales_order_procurement_demands(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_procurement_demand_audit_line
    FOREIGN KEY(company_id,demand_line_id)
    REFERENCES public.sales_order_procurement_demand_lines(company_id,id)
    ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_sales_order_procurement_demand_audit_header_operation
  ON public.sales_order_procurement_demand_audit(
    company_id,demand_id,idempotency_key)
  WHERE demand_line_id IS NULL;
CREATE UNIQUE INDEX uq_sales_order_procurement_demand_audit_line_operation
  ON public.sales_order_procurement_demand_audit(
    company_id,demand_id,demand_line_id,idempotency_key)
  WHERE demand_line_id IS NOT NULL;

CREATE FUNCTION private.trg_odr_guard_procurement_demand_header()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND (NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.store_id IS DISTINCT FROM OLD.store_id
    OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
    OR NEW.cashier_session_id IS DISTINCT FROM OLD.cashier_session_id
    OR NEW.created_by IS DISTINCT FROM OLD.created_by
    OR NEW.created_at IS DISTINCT FROM OLD.created_at) THEN
    RAISE EXCEPTION 'PROCUREMENT_DEMAND_IDENTITY_IMMUTABLE';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=NEW.company_id
      AND session.id=NEW.cashier_session_id
      AND session.store_id=NEW.store_id
      AND session.sales_warehouse_id=NEW.warehouse_id) THEN
    RAISE EXCEPTION 'PROCUREMENT_DEMAND_SESSION_SCOPE_MISMATCH';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_odr_guard_procurement_demand_header
BEFORE INSERT OR UPDATE ON public.sales_order_procurement_demands
FOR EACH ROW EXECUTE FUNCTION private.trg_odr_guard_procurement_demand_header();

CREATE FUNCTION private.trg_odr_guard_procurement_demand_line()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND (NEW.company_id IS DISTINCT FROM OLD.company_id
    OR NEW.demand_id IS DISTINCT FROM OLD.demand_id
    OR NEW.reservation_line_id IS DISTINCT FROM OLD.reservation_line_id
    OR NEW.sales_id IS DISTINCT FROM OLD.sales_id
    OR NEW.stock_product_id IS DISTINCT FROM OLD.stock_product_id
    OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
    OR NEW.created_at IS DISTINCT FROM OLD.created_at) THEN
    RAISE EXCEPTION 'PROCUREMENT_DEMAND_LINE_IDENTITY_IMMUTABLE';
  END IF;
  IF NOT EXISTS(SELECT 1
    FROM public.sales_order_procurement_demands demand
    JOIN public.sales_stock_reservation_lines reservation_line
      ON reservation_line.company_id=demand.company_id
     AND reservation_line.id=NEW.reservation_line_id
    JOIN public.sales_headers sale
      ON sale.company_id=reservation_line.company_id
     AND sale.id=reservation_line.sales_id
    WHERE demand.company_id=NEW.company_id AND demand.id=NEW.demand_id
      AND demand.cashier_session_id=sale.session_id
      AND demand.store_id=sale.store_id
      AND demand.warehouse_id=reservation_line.warehouse_id
      AND reservation_line.sales_id=NEW.sales_id
      AND reservation_line.stock_product_id=NEW.stock_product_id
      AND reservation_line.warehouse_id=NEW.warehouse_id
      AND NEW.demand_base_qty<=reservation_line.shortage_base_qty) THEN
    RAISE EXCEPTION 'PROCUREMENT_DEMAND_RESERVATION_SCOPE_MISMATCH';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER trg_odr_guard_procurement_demand_line
BEFORE INSERT OR UPDATE ON public.sales_order_procurement_demand_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_odr_guard_procurement_demand_line();

CREATE FUNCTION private.trg_odr_guard_procurement_demand_audit()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'PROCUREMENT_DEMAND_AUDIT_IMMUTABLE';
END
$$;

CREATE TRIGGER trg_odr_guard_procurement_demand_audit
BEFORE UPDATE OR DELETE ON public.sales_order_procurement_demand_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_odr_guard_procurement_demand_audit();

ALTER TABLE public.sales_order_procurement_demands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_procurement_demand_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_procurement_demand_audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.sales_order_procurement_demands,
  public.sales_order_procurement_demand_lines,
  public.sales_order_procurement_demand_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.sales_order_procurement_demands,
  public.sales_order_procurement_demand_lines,
  public.sales_order_procurement_demand_audit TO service_role;

REVOKE ALL ON FUNCTION
  private.trg_odr_guard_procurement_demand_header(),
  private.trg_odr_guard_procurement_demand_line(),
  private.trg_odr_guard_procurement_demand_audit()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_odr_guard_procurement_demand_header(),
  private.trg_odr_guard_procurement_demand_line(),
  private.trg_odr_guard_procurement_demand_audit()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828150000','odr_phase4a_procurement_demand_foundation',
  'Additive session-scoped reservation-shortage demand header, immutable source line identity, append-only audit, tenant guards and browser boundary; zero backfill and no Stock Request, Supplier Order, Stock, or Finance mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
