-- Additive Backoffice Sales Reservation and Delivery Order lineage.
-- No existing POS relation, Confirm runtime, Stock, FIFO, Invoice or Finance
-- behavior is changed by this foundation migration.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909144000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: revision commercial fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909145000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909145000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name IN(
      'backoffice_sales_reservations','backoffice_sales_reservation_lines',
      'backoffice_sales_delivery_orders','backoffice_sales_delivery_order_lines',
      'backoffice_sales_fulfillment_audit')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: fulfillment relation collision';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_order_lines
  ADD CONSTRAINT backoffice_sales_order_lines_order_identity_unique
  UNIQUE(company_id,sales_order_id,id);

CREATE TABLE public.backoffice_sales_reservations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  sales_order_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'OPEN',
  total_ordered_base_qty numeric(24,6) NOT NULL,
  total_reserved_base_qty numeric(24,6) NOT NULL,
  total_released_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  total_in_transit_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  total_completed_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  released_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  released_at timestamptz,
  release_reason text,
  CONSTRAINT backoffice_sales_reservations_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_reservations_order_unique UNIQUE(company_id,sales_order_id),
  CONSTRAINT backoffice_sales_reservations_order_identity_unique
    UNIQUE(company_id,id,sales_order_id),
  CONSTRAINT backoffice_sales_reservations_order_fk
    FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_reservations_warehouse_fk
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_reservations_status_check CHECK(status IN(
    'OPEN','PARTIALLY_ALLOCATED','ALLOCATED','PARTIALLY_FULFILLED',
    'FULFILLED','RELEASED')),
  CONSTRAINT backoffice_sales_reservations_quantity_check CHECK(
    total_ordered_base_qty>0
    AND total_reserved_base_qty=total_ordered_base_qty
    AND total_released_base_qty>=0 AND total_in_transit_base_qty>=0
    AND total_completed_base_qty>=0
    AND total_released_base_qty+total_in_transit_base_qty
      +total_completed_base_qty<=total_reserved_base_qty),
  CONSTRAINT backoffice_sales_reservations_version_check CHECK(master_version>0),
  CONSTRAINT backoffice_sales_reservations_release_check CHECK(
    (status='RELEASED' AND released_by IS NOT NULL AND released_at IS NOT NULL
      AND nullif(btrim(release_reason),'') IS NOT NULL)
    OR status<>'RELEASED')
);

CREATE TABLE public.backoffice_sales_reservation_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  product_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  ordered_base_qty numeric(24,6) NOT NULL,
  reserved_base_qty numeric(24,6) NOT NULL,
  released_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  in_transit_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  completed_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_reservation_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_reservation_lines_source_unique
    UNIQUE(company_id,sales_order_line_id),
  CONSTRAINT backoffice_sales_reservation_lines_reservation_identity_unique
    UNIQUE(company_id,reservation_id,id),
  CONSTRAINT backoffice_sales_reservation_lines_header_fk
    FOREIGN KEY(company_id,reservation_id,sales_order_id)
    REFERENCES public.backoffice_sales_reservations(company_id,id,sales_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_reservation_lines_order_line_fk
    FOREIGN KEY(company_id,sales_order_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_reservation_lines_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_reservation_lines_warehouse_fk
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_reservation_lines_quantity_check CHECK(
    ordered_base_qty>0 AND reserved_base_qty=ordered_base_qty
    AND released_base_qty>=0 AND in_transit_base_qty>=0
    AND completed_base_qty>=0
    AND released_base_qty+in_transit_base_qty+completed_base_qty<=reserved_base_qty)
);

CREATE INDEX backoffice_sales_reservation_lines_open_product
  ON public.backoffice_sales_reservation_lines(company_id,warehouse_id,product_id)
  WHERE released_base_qty+completed_base_qty<reserved_base_qty;

CREATE TABLE public.backoffice_sales_delivery_orders(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  sales_order_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  delivery_no text NOT NULL,
  sequence_no integer NOT NULL,
  delivery_kind text NOT NULL DEFAULT 'INITIAL',
  parent_delivery_order_id uuid,
  status text NOT NULL DEFAULT 'PREPARING',
  scheduled_date date NOT NULL,
  recipient_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes text,
  total_planned_base_qty numeric(24,6) NOT NULL,
  total_shipped_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  total_received_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  departed_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  departed_at timestamptz,
  completed_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  completed_at timestamptz,
  canceled_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_at timestamptz,
  cancel_reason text,
  CONSTRAINT backoffice_sales_delivery_orders_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_orders_order_identity_unique
    UNIQUE(company_id,sales_order_id,id),
  CONSTRAINT backoffice_sales_delivery_orders_number_unique UNIQUE(company_id,delivery_no),
  CONSTRAINT backoffice_sales_delivery_orders_sequence_unique
    UNIQUE(company_id,sales_order_id,sequence_no),
  CONSTRAINT backoffice_sales_delivery_orders_order_fk
    FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_orders_reservation_fk
    FOREIGN KEY(company_id,reservation_id,sales_order_id)
    REFERENCES public.backoffice_sales_reservations(company_id,id,sales_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_orders_parent_fk
    FOREIGN KEY(company_id,sales_order_id,parent_delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_orders_identity_check CHECK(
    nullif(btrim(delivery_no),'') IS NOT NULL AND sequence_no>0
    AND jsonb_typeof(recipient_snapshot)='object'),
  CONSTRAINT backoffice_sales_delivery_orders_kind_check CHECK(
    (delivery_kind='INITIAL' AND parent_delivery_order_id IS NULL)
    OR (delivery_kind IN('BACKORDER','CORRECTION')
      AND parent_delivery_order_id IS NOT NULL)),
  CONSTRAINT backoffice_sales_delivery_orders_status_check CHECK(status IN(
    'PREPARING','READY','PARTIALLY_SHIPPED','IN_TRANSIT','COMPLETED','CANCELED')),
  CONSTRAINT backoffice_sales_delivery_orders_quantity_check CHECK(
    total_planned_base_qty>0 AND total_shipped_base_qty>=0
    AND total_received_base_qty>=0),
  CONSTRAINT backoffice_sales_delivery_orders_version_check CHECK(master_version>0),
  CONSTRAINT backoffice_sales_delivery_orders_lifecycle_check CHECK(
    (status IN('PREPARING','READY') AND departed_at IS NULL
      AND completed_at IS NULL AND canceled_at IS NULL)
    OR (status IN('PARTIALLY_SHIPPED','IN_TRANSIT') AND departed_by IS NOT NULL
      AND departed_at IS NOT NULL AND completed_at IS NULL AND canceled_at IS NULL)
    OR (status='COMPLETED' AND departed_by IS NOT NULL AND departed_at IS NOT NULL
      AND completed_by IS NOT NULL AND completed_at IS NOT NULL
      AND canceled_at IS NULL)
    OR (status='CANCELED' AND canceled_by IS NOT NULL AND canceled_at IS NOT NULL
      AND nullif(btrim(cancel_reason),'') IS NOT NULL))
);

CREATE TABLE public.backoffice_sales_delivery_order_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  delivery_order_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  reservation_line_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  uom_id uuid NOT NULL,
  product_code_snapshot text NOT NULL,
  product_name_snapshot text NOT NULL,
  uom_code_snapshot text NOT NULL,
  uom_name_snapshot text NOT NULL,
  base_qty_per_uom numeric(24,6) NOT NULL,
  planned_qty_uom numeric(24,6) NOT NULL,
  planned_base_qty numeric(24,6) NOT NULL,
  shipped_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  received_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_delivery_order_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_order_lines_no_unique
    UNIQUE(company_id,delivery_order_id,line_no),
  CONSTRAINT backoffice_sales_delivery_order_lines_source_unique
    UNIQUE(company_id,delivery_order_id,sales_order_line_id),
  CONSTRAINT backoffice_sales_delivery_order_lines_document_fk
    FOREIGN KEY(company_id,sales_order_id,delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_order_lines_reservation_fk
    FOREIGN KEY(company_id,reservation_id,reservation_line_id)
    REFERENCES public.backoffice_sales_reservation_lines(company_id,reservation_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_order_lines_order_line_fk
    FOREIGN KEY(company_id,sales_order_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_order_lines_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_order_lines_uom_fk
    FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_order_lines_snapshot_check CHECK(
    line_no>0 AND nullif(btrim(product_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(product_name_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_name_snapshot),'') IS NOT NULL),
  CONSTRAINT backoffice_sales_delivery_order_lines_quantity_check CHECK(
    base_qty_per_uom>0 AND planned_qty_uom>0 AND planned_base_qty>0
    AND shipped_base_qty>=0 AND received_base_qty>=0)
);

CREATE TABLE public.backoffice_sales_fulfillment_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  sales_order_id uuid NOT NULL,
  reservation_id uuid,
  delivery_order_id uuid,
  operation_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  reason text,
  before_state jsonb,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_fulfillment_audit_operation_unique
    UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_fulfillment_audit_order_fk
    FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_fulfillment_audit_reservation_fk
    FOREIGN KEY(company_id,reservation_id)
    REFERENCES public.backoffice_sales_reservations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_fulfillment_audit_delivery_fk
    FOREIGN KEY(company_id,delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_fulfillment_audit_target_check CHECK(
    (reservation_id IS NOT NULL)::integer
      +(delivery_order_id IS NOT NULL)::integer=1),
  CONSTRAINT backoffice_sales_fulfillment_audit_action_check CHECK(action IN(
    'RESERVE','RELEASE','CREATE_DELIVERY','UPDATE_PLAN','DEPART_PARTIAL',
    'DEPART_FULL','COMPLETE','CANCEL','CREATE_BACKORDER','RECORD_DISCREPANCY')),
  CONSTRAINT backoffice_sales_fulfillment_audit_state_check CHECK(
    (before_state IS NULL OR jsonb_typeof(before_state)='object')
    AND jsonb_typeof(after_state)='object')
);

CREATE FUNCTION private.trg_guard_backoffice_sales_fulfillment_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_FULFILLMENT_AUDIT_IMMUTABLE';
END
$$;

CREATE TRIGGER backoffice_sales_fulfillment_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_fulfillment_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_fulfillment_audit();

ALTER TABLE public.backoffice_sales_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_reservation_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_delivery_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_delivery_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_fulfillment_audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.backoffice_sales_reservations,
  public.backoffice_sales_reservation_lines,
  public.backoffice_sales_delivery_orders,
  public.backoffice_sales_delivery_order_lines,
  public.backoffice_sales_fulfillment_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.backoffice_sales_reservations,
  public.backoffice_sales_reservation_lines,
  public.backoffice_sales_delivery_orders,
  public.backoffice_sales_delivery_order_lines,
  public.backoffice_sales_fulfillment_audit TO service_role;
REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_fulfillment_audit()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_fulfillment_audit()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909145000','backoffice_sales_fulfillment_foundation',
  'Isolated Backoffice Reservation and multi-Delivery lineage with Backorder/Correction identity, composite tenant FKs, RLS and immutable audit; zero runtime and downstream effect');

COMMIT;
