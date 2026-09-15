-- Optional Backoffice Quotation/Sales Order isolated persistence foundation.
-- Feature remains OFF. No POS, Stock, Delivery, Invoice, Payment or Finance effect.
BEGIN;

DO $migration_guard$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version = '20260908100000'
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Backoffice process identity foundation required';
  END IF;
  IF EXISTS (
    SELECT 1 FROM private.kgs_schema_migrations
    WHERE version = '20260908110000'
  ) OR to_regclass('public.backoffice_sales_orders') IS NOT NULL
    OR to_regclass('public.backoffice_sales_order_lines') IS NOT NULL
    OR to_regclass('public.backoffice_sales_order_operations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_order_audit') IS NOT NULL THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Backoffice Sales Order foundation collision';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.platform_features
    WHERE feature_code = 'backoffice_delivered_qty_sales_enabled'
      AND is_active
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Backoffice Sales feature missing';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.company_features
    WHERE feature_code = 'backoffice_delivered_qty_sales_enabled'
      AND is_enabled
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: Backoffice Sales feature must remain disabled';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN ('PREVIEWED','APPROVED','PROCESSING')
  ) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')
  ) THEN
    RAISE EXCEPTION
      'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$migration_guard$;

CREATE TABLE public.backoffice_sales_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  store_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  pricelist_id uuid,
  quotation_no text NOT NULL,
  order_no text,
  status text NOT NULL DEFAULT 'DRAFT',
  sales_origin text NOT NULL DEFAULT 'BACKOFFICE_SALES',
  sales_process_mode text NOT NULL DEFAULT 'BACKOFFICE_DELIVERED_QTY_INVOICE',
  order_date date NOT NULL,
  planned_delivery_date date NOT NULL,
  is_tempo boolean NOT NULL DEFAULT false,
  due_date date,
  currency_code text NOT NULL DEFAULT 'IDR',
  customer_snapshot jsonb NOT NULL,
  commercial_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  notes text,
  subtotal numeric(20,4) NOT NULL DEFAULT 0,
  discount_total numeric(20,4) NOT NULL DEFAULT 0,
  tax_total numeric(20,4) NOT NULL DEFAULT 0,
  grand_total numeric(20,4) NOT NULL DEFAULT 0,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  sent_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  sent_at timestamptz,
  confirmed_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  confirmed_at timestamptz,
  canceled_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_at timestamptz,
  cancel_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_orders_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_orders_quotation_unique
    UNIQUE(company_id,quotation_no),
  CONSTRAINT backoffice_sales_orders_store_fk
    FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_orders_warehouse_fk
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_orders_customer_fk
    FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_orders_pricelist_fk
    FOREIGN KEY(company_id,pricelist_id)
    REFERENCES public.pricelists(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_orders_status_check
    CHECK(status IN ('DRAFT','SENT','CONFIRMED','CANCELED')),
  CONSTRAINT backoffice_sales_orders_process_check CHECK(
    sales_origin = 'BACKOFFICE_SALES'
    AND sales_process_mode = 'BACKOFFICE_DELIVERED_QTY_INVOICE'
  ),
  CONSTRAINT backoffice_sales_orders_date_check CHECK(
    planned_delivery_date >= order_date
    AND (due_date IS NULL OR due_date >= order_date)
    AND (NOT is_tempo OR due_date IS NOT NULL)
  ),
  CONSTRAINT backoffice_sales_orders_currency_check
    CHECK(currency_code ~ '^[A-Z]{3}$'),
  CONSTRAINT backoffice_sales_orders_snapshot_check CHECK(
    jsonb_typeof(customer_snapshot) = 'object'
    AND jsonb_typeof(commercial_snapshot) = 'object'
  ),
  CONSTRAINT backoffice_sales_orders_amount_check CHECK(
    subtotal >= 0 AND discount_total >= 0 AND tax_total >= 0
    AND discount_total <= subtotal
    AND grand_total = subtotal - discount_total + tax_total
  ),
  CONSTRAINT backoffice_sales_orders_version_check CHECK(master_version > 0),
  CONSTRAINT backoffice_sales_orders_actor_time_check CHECK(
    (sent_by IS NULL) = (sent_at IS NULL)
    AND (confirmed_by IS NULL) = (confirmed_at IS NULL)
    AND (canceled_by IS NULL) = (canceled_at IS NULL)
  ),
  CONSTRAINT backoffice_sales_orders_lifecycle_check CHECK(
    (status = 'DRAFT' AND sent_at IS NULL AND confirmed_at IS NULL
      AND canceled_at IS NULL AND order_no IS NULL)
    OR (status = 'SENT' AND sent_at IS NOT NULL AND confirmed_at IS NULL
      AND canceled_at IS NULL AND order_no IS NULL)
    OR (status = 'CONFIRMED' AND confirmed_at IS NOT NULL
      AND canceled_at IS NULL AND order_no IS NOT NULL)
    OR (status = 'CANCELED' AND canceled_at IS NOT NULL
      AND nullif(btrim(cancel_reason),'') IS NOT NULL)
  )
);

CREATE UNIQUE INDEX backoffice_sales_orders_order_no_unique
  ON public.backoffice_sales_orders(company_id,order_no)
  WHERE order_no IS NOT NULL;
CREATE INDEX backoffice_sales_orders_company_status_date
  ON public.backoffice_sales_orders(company_id,status,order_date DESC,id);
CREATE INDEX backoffice_sales_orders_customer_date
  ON public.backoffice_sales_orders(company_id,customer_id,order_date DESC,id);

CREATE TABLE public.backoffice_sales_order_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  uom_id uuid NOT NULL,
  ordered_qty numeric(20,6) NOT NULL,
  base_qty_per_uom numeric(20,6) NOT NULL,
  ordered_base_qty numeric(20,6)
    GENERATED ALWAYS AS (ordered_qty * base_qty_per_uom) STORED,
  unit_price numeric(20,4) NOT NULL,
  line_subtotal numeric(20,4)
    GENERATED ALWAYS AS (ordered_qty * unit_price) STORED,
  discount_amount numeric(20,4) NOT NULL DEFAULT 0,
  tax_amount numeric(20,4) NOT NULL DEFAULT 0,
  line_total numeric(20,4)
    GENERATED ALWAYS AS (
      ordered_qty * unit_price - discount_amount + tax_amount
    ) STORED,
  product_code_snapshot text NOT NULL,
  product_name_snapshot text NOT NULL,
  uom_code_snapshot text NOT NULL,
  uom_name_snapshot text NOT NULL,
  pricing_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_order_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_order_lines_order_line_unique
    UNIQUE(company_id,sales_order_id,line_no),
  CONSTRAINT backoffice_sales_order_lines_order_fk
    FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_order_lines_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_order_lines_uom_fk
    FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_order_lines_quantity_check
    CHECK(line_no > 0 AND ordered_qty > 0 AND base_qty_per_uom > 0),
  CONSTRAINT backoffice_sales_order_lines_amount_check CHECK(
    unit_price >= 0 AND discount_amount >= 0 AND tax_amount >= 0
    AND discount_amount <= ordered_qty * unit_price
  ),
  CONSTRAINT backoffice_sales_order_lines_snapshot_check CHECK(
    nullif(btrim(product_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(product_name_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_code_snapshot),'') IS NOT NULL
    AND nullif(btrim(uom_name_snapshot),'') IS NOT NULL
    AND jsonb_typeof(pricing_snapshot) = 'object'
  ),
  CONSTRAINT backoffice_sales_order_lines_version_check CHECK(master_version > 0)
);

CREATE INDEX backoffice_sales_order_lines_product
  ON public.backoffice_sales_order_lines(company_id,product_id,sales_order_id);

CREATE TABLE public.backoffice_sales_order_operations (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  operation_type text NOT NULL,
  sales_order_id uuid NOT NULL,
  expected_version bigint,
  request_hash text NOT NULL,
  response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_order_operations_identity_unique
    UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_order_operations_order_fk
    FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_order_operations_type_check CHECK(
    operation_type IN ('SAVE_DRAFT','SEND','CONFIRM','CANCEL')
  ),
  CONSTRAINT backoffice_sales_order_operations_version_check
    CHECK(expected_version IS NULL OR expected_version > 0),
  CONSTRAINT backoffice_sales_order_operations_hash_check
    CHECK(request_hash ~ '^[0-9a-f]{64}$'),
  CONSTRAINT backoffice_sales_order_operations_response_check
    CHECK(jsonb_typeof(response_snapshot) = 'object')
);

CREATE INDEX backoffice_sales_order_operations_order_time
  ON public.backoffice_sales_order_operations(
    company_id,sales_order_id,created_at DESC,id DESC
  );

CREATE TABLE public.backoffice_sales_order_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  sales_order_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  reason text,
  before_state jsonb,
  after_state jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_order_audit_order_fk
    FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_order_audit_operation_fk
    FOREIGN KEY(company_id,operation_id)
    REFERENCES public.backoffice_sales_order_operations(company_id,operation_id)
      ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_order_audit_action_check CHECK(
    action IN ('CREATE','UPDATE','SEND','CONFIRM','CANCEL')
  ),
  CONSTRAINT backoffice_sales_order_audit_state_check CHECK(
    (before_state IS NULL OR jsonb_typeof(before_state) = 'object')
    AND (after_state IS NULL OR jsonb_typeof(after_state) = 'object')
    AND (before_state IS NOT NULL OR after_state IS NOT NULL)
  )
);

CREATE INDEX backoffice_sales_order_audit_order_time
  ON public.backoffice_sales_order_audit(
    company_id,sales_order_id,created_at DESC,id DESC
  );

CREATE FUNCTION private.trg_guard_backoffice_sales_order_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_HISTORY_IMMUTABLE';
END
$$;

CREATE TRIGGER backoffice_sales_order_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_order_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_order_history();

CREATE TRIGGER backoffice_sales_order_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_order_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_order_history();

ALTER TABLE public.backoffice_sales_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_order_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_order_audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
  public.backoffice_sales_orders,
  public.backoffice_sales_order_lines,
  public.backoffice_sales_order_operations,
  public.backoffice_sales_order_audit
FROM PUBLIC, anon, authenticated;

GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE
  public.backoffice_sales_orders,
  public.backoffice_sales_order_lines
TO service_role;
GRANT SELECT,INSERT ON TABLE
  public.backoffice_sales_order_operations,
  public.backoffice_sales_order_audit
TO service_role;
GRANT USAGE,SELECT ON SEQUENCE
  public.backoffice_sales_order_operations_id_seq,
  public.backoffice_sales_order_audit_id_seq
TO service_role;

REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_order_history()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_order_history()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260908110000',
  'backoffice_sales_order_foundation',
  'Add isolated RLS-protected Quotation/Sales Order header, line, exact-operation and immutable audit persistence while feature remains OFF; zero POS, Stock, Delivery, Invoice, Payment and Finance effect'
);

COMMIT;
