-- ODR-2A Sales Order and reservation additive foundation.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260827154000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: scheduled POS runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828100000';
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

ALTER TABLE public.sales_headers
  ADD COLUMN order_runtime_status TEXT NOT NULL DEFAULT 'DRAFT_INPUT',
  ADD COLUMN confirmed_at TIMESTAMPTZ,
  ADD COLUMN confirmed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  ADD COLUMN confirmation_idempotency_key UUID,
  ADD COLUMN reservation_version BIGINT NOT NULL DEFAULT 0;

UPDATE public.sales_headers SET order_runtime_status=CASE
  WHEN document_status='POSTED' THEN 'LEGACY_POSTED'
  WHEN document_status='CANCELED' THEN 'CANCELED'
  WHEN order_timing_mode='SCHEDULED' THEN 'SCHEDULED'
  ELSE 'DRAFT_INPUT' END;

-- The classification UPDATE can queue deferred FK/constraint trigger events on
-- this heavily-related table. Flush them before the next ALTER TABLE so
-- PostgreSQL does not raise 55006 (pending trigger events).
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE public.sales_headers
  ADD CONSTRAINT sales_headers_order_runtime_status_check CHECK(
    order_runtime_status IN('DRAFT_INPUT','SCHEDULED','CONFIRMED','RESERVED',
      'PARTIALLY_DISPATCHED','DISPATCHED','DELIVERED','CANCELED','LEGACY_POSTED')),
  ADD CONSTRAINT sales_headers_reservation_version_nonnegative
    CHECK(reservation_version>=0),
  ADD CONSTRAINT sales_headers_order_runtime_shape CHECK(
    (order_runtime_status='LEGACY_POSTED' AND document_status='POSTED')
    OR (order_runtime_status='CANCELED' AND document_status='CANCELED')
    OR (order_runtime_status IN('DRAFT_INPUT','SCHEDULED')
      AND document_status='DRAFT' AND confirmed_at IS NULL
      AND confirmed_by IS NULL AND confirmation_idempotency_key IS NULL
      AND reservation_version=0)
    OR (order_runtime_status IN('CONFIRMED','RESERVED','PARTIALLY_DISPATCHED',
        'DISPATCHED','DELIVERED')
      AND document_status='DRAFT' AND confirmed_at IS NOT NULL
      AND confirmed_by IS NOT NULL AND confirmation_idempotency_key IS NOT NULL
      AND sales_warehouse_id IS NOT NULL AND reservation_version>0));

CREATE UNIQUE INDEX uq_sales_headers_company_confirmation_idempotency
  ON public.sales_headers(company_id,confirmation_idempotency_key)
  WHERE confirmation_idempotency_key IS NOT NULL;
CREATE INDEX idx_sales_headers_company_order_runtime
  ON public.sales_headers(company_id,order_runtime_status,updated_at DESC);

CREATE TABLE public.sales_stock_reservations(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  sales_id UUID NOT NULL,
  warehouse_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN',
  total_reserved_base_qty NUMERIC(24,6) NOT NULL,
  total_released_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  total_dispatched_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  master_version BIGINT NOT NULL DEFAULT 1,
  confirmation_idempotency_key UUID NOT NULL,
  confirmed_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  confirmed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  released_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  released_at TIMESTAMPTZ,
  release_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_stock_reservations_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT sales_stock_reservations_sale_unique UNIQUE(company_id,sales_id),
  CONSTRAINT sales_stock_reservations_confirmation_unique
    UNIQUE(company_id,confirmation_idempotency_key),
  CONSTRAINT sales_stock_reservations_status_check
    CHECK(status IN('OPEN','PARTIALLY_DISPATCHED','CONSUMED','RELEASED')),
  CONSTRAINT sales_stock_reservations_quantity_check CHECK(
    total_reserved_base_qty>0 AND total_released_base_qty>=0
    AND total_dispatched_base_qty>=0
    AND total_released_base_qty+total_dispatched_base_qty<=total_reserved_base_qty),
  CONSTRAINT sales_stock_reservations_version_positive CHECK(master_version>0),
  CONSTRAINT sales_stock_reservations_release_shape CHECK(
    (status='RELEASED' AND released_by IS NOT NULL AND released_at IS NOT NULL
      AND COALESCE(btrim(release_reason),'')<>'') OR status<>'RELEASED'),
  CONSTRAINT fk_sales_stock_reservation_sale FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_stock_reservation_warehouse FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.sales_stock_reservation_lines(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  reservation_id UUID NOT NULL,
  sales_id UUID NOT NULL,
  sales_detail_id UUID NOT NULL,
  stock_requirement_id UUID NOT NULL,
  stock_product_id UUID NOT NULL,
  warehouse_id UUID NOT NULL,
  requested_base_qty NUMERIC(24,6) NOT NULL,
  reserved_base_qty NUMERIC(24,6) NOT NULL,
  released_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  dispatched_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  available_base_qty_snapshot NUMERIC(24,6) NOT NULL,
  shortage_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
  negative_policy_version BIGINT,
  negative_permission_version BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_stock_reservation_lines_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT sales_stock_reservation_lines_requirement_unique
    UNIQUE(company_id,stock_requirement_id),
  CONSTRAINT sales_stock_reservation_lines_quantity_check CHECK(
    requested_base_qty>0 AND reserved_base_qty=requested_base_qty
    AND released_base_qty>=0 AND dispatched_base_qty>=0
    AND released_base_qty+dispatched_base_qty<=reserved_base_qty
    AND shortage_base_qty>=0
    AND shortage_base_qty=GREATEST(reserved_base_qty-GREATEST(available_base_qty_snapshot,0),0)),
  CONSTRAINT sales_stock_reservation_lines_negative_snapshot_check CHECK(
    (shortage_base_qty=0 AND negative_policy_version IS NULL
      AND negative_permission_version IS NULL)
    OR (shortage_base_qty>0 AND negative_policy_version>0
      AND negative_permission_version>0)),
  CONSTRAINT fk_sales_stock_reservation_line_header FOREIGN KEY(company_id,reservation_id)
    REFERENCES public.sales_stock_reservations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_stock_reservation_line_sale FOREIGN KEY(company_id,sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_stock_reservation_line_detail FOREIGN KEY(company_id,sales_detail_id)
    REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_stock_reservation_line_requirement FOREIGN KEY(company_id,stock_requirement_id)
    REFERENCES public.sale_stock_requirements(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_stock_reservation_line_product FOREIGN KEY(company_id,stock_product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_stock_reservation_line_warehouse FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_sales_stock_reservation_open_product
  ON public.sales_stock_reservation_lines(company_id,warehouse_id,stock_product_id)
  WHERE released_base_qty+dispatched_base_qty<reserved_base_qty;

CREATE TABLE public.sales_stock_reservation_audit(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id UUID NOT NULL,
  reservation_id UUID NOT NULL,
  sales_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN(
    'CONFIRM','REPRICE','QUANTITY_DELTA','RELEASE','DISPATCH_PARTIAL','DISPATCH_FULL')),
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  idempotency_key UUID NOT NULL,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT fk_sales_stock_reservation_audit_header FOREIGN KEY(company_id,reservation_id)
    REFERENCES public.sales_stock_reservations(company_id,id) ON DELETE RESTRICT
);

CREATE FUNCTION private.trg_odr_guard_reservation_audit()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN RAISE EXCEPTION 'SALES_STOCK_RESERVATION_AUDIT_IMMUTABLE'; END
$$;
CREATE TRIGGER trg_odr_guard_reservation_audit
BEFORE UPDATE OR DELETE ON public.sales_stock_reservation_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_odr_guard_reservation_audit();

ALTER TABLE public.sales_stock_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_stock_reservation_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_stock_reservation_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sales_stock_reservations,
  public.sales_stock_reservation_lines,
  public.sales_stock_reservation_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.sales_stock_reservations,
  public.sales_stock_reservation_lines,
  public.sales_stock_reservation_audit TO service_role;

INSERT INTO public.access_permission_catalog(permission_key,module_key,
  permission_label,description,view_roles,operator_roles,approver_roles,
  supported_capabilities,required_any_features,is_customizable,enforcement_status)
VALUES('sales.sales_orders','SALES','Sales Order',
  'Order terkonfirmasi, reservation, dan antrean pemenuhan',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'],'{}',
  ARRAY['VIEW','MANAGE','CANCEL_FINAL'],'{}',TRUE,'SHADOW');

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828100000','odr_phase2a_sales_order_reservation_foundation',
  'Additive Sales Order lifecycle metadata, reservation schema, immutable audit, RLS, SHADOW permission, and historical classification; no reservation or final effect is created');

COMMIT;
