-- Odoo-style Backoffice invoice/accounting document foundation.
-- Zero-backfill only: no runtime Invoice, Payment, Financial Event, Journal, or Stock effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909155000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer receipt Finance posting required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909156000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909156000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name IN(
    'backoffice_sales_payment_terms','backoffice_sales_payment_term_lines',
    'backoffice_sales_proformas','backoffice_sales_invoices','backoffice_sales_invoice_lines',
    'backoffice_sales_invoice_quantity_allocations','backoffice_sales_down_payment_applications',
    'backoffice_sales_invoice_receivable_schedules','backoffice_sales_invoice_audit')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Invoice foundation relation collision';
  END IF;
END
$guard$;

CREATE TABLE public.backoffice_sales_payment_terms(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  term_code text NOT NULL,
  term_name text NOT NULL,
  description text,
  show_installment_dates boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_payment_terms_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_payment_terms_code_unique UNIQUE(company_id,term_code),
  CONSTRAINT backoffice_sales_payment_terms_shape_check CHECK(
    nullif(btrim(term_code),'') IS NOT NULL AND nullif(btrim(term_name),'') IS NOT NULL
    AND master_version>0)
);

CREATE TABLE public.backoffice_sales_payment_term_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  payment_term_id uuid NOT NULL,
  line_no integer NOT NULL,
  amount_type text NOT NULL,
  amount_value numeric(20,6),
  due_rule text NOT NULL,
  days_offset integer NOT NULL DEFAULT 0,
  day_of_month integer,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_payment_term_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_payment_term_lines_order_unique UNIQUE(company_id,payment_term_id,line_no),
  CONSTRAINT backoffice_sales_payment_term_lines_header_fk FOREIGN KEY(company_id,payment_term_id)
    REFERENCES public.backoffice_sales_payment_terms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_payment_term_lines_shape_check CHECK(
    line_no>0 AND amount_type IN('PERCENT','FIXED','BALANCE')
    AND ((amount_type='BALANCE' AND amount_value IS NULL)
      OR (amount_type='PERCENT' AND amount_value>0 AND amount_value<=100)
      OR (amount_type='FIXED' AND amount_value>0))
    AND due_rule IN('DAYS_AFTER_INVOICE','END_OF_MONTH','DAY_OF_FOLLOWING_MONTH')
    AND days_offset>=0
    AND ((due_rule='DAY_OF_FOLLOWING_MONTH' AND day_of_month BETWEEN 1 AND 31)
      OR (due_rule<>'DAY_OF_FOLLOWING_MONTH' AND day_of_month IS NULL)))
);

ALTER TABLE public.backoffice_sales_orders
  ADD COLUMN payment_term_id uuid,
  ADD COLUMN payment_term_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD CONSTRAINT backoffice_sales_orders_payment_term_fk FOREIGN KEY(company_id,payment_term_id)
    REFERENCES public.backoffice_sales_payment_terms(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_orders_payment_term_snapshot_check
    CHECK(jsonb_typeof(payment_term_snapshot)='object');

CREATE TABLE public.backoffice_sales_proformas(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  proforma_no text NOT NULL,
  source_version bigint NOT NULL,
  document_snapshot jsonb NOT NULL,
  status text NOT NULL DEFAULT 'ISSUED',
  issued_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  issued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  canceled_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_at timestamptz,
  cancel_reason text,
  CONSTRAINT backoffice_sales_proformas_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_proformas_number_unique UNIQUE(company_id,proforma_no),
  CONSTRAINT backoffice_sales_proformas_order_fk FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_proformas_shape_check CHECK(
    source_version>0 AND jsonb_typeof(document_snapshot)='object'
    AND status IN('ISSUED','CANCELED')
    AND ((status='ISSUED' AND canceled_at IS NULL AND canceled_by IS NULL AND cancel_reason IS NULL)
      OR (status='CANCELED' AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
        AND nullif(btrim(cancel_reason),'') IS NOT NULL)))
);

CREATE TABLE public.backoffice_sales_invoices(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  store_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  payment_term_id uuid,
  draft_no text NOT NULL,
  invoice_no text,
  invoice_sequence integer NOT NULL,
  invoice_type text NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT',
  invoice_date date NOT NULL,
  currency_code text NOT NULL,
  customer_snapshot jsonb NOT NULL,
  payment_term_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  commercial_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  down_payment_mode text,
  down_payment_input numeric(20,6),
  down_payment_basis_total numeric(24,4) NOT NULL DEFAULT 0,
  charge_total numeric(24,4) NOT NULL DEFAULT 0,
  discount_total numeric(24,4) NOT NULL DEFAULT 0,
  tax_total numeric(24,4) NOT NULL DEFAULT 0,
  down_payment_deduction_total numeric(24,4) NOT NULL DEFAULT 0,
  grand_total numeric(24,4) NOT NULL DEFAULT 0,
  financial_event_id uuid,
  notes text,
  master_version bigint NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  posted_at timestamptz,
  canceled_by uuid REFERENCES public.profiles(id) ON DELETE RESTRICT,
  canceled_at timestamptz,
  cancel_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_invoices_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_invoices_lineage_unique UNIQUE(company_id,id,sales_order_id),
  CONSTRAINT backoffice_sales_invoices_order_sequence_unique UNIQUE(company_id,sales_order_id,invoice_sequence),
  CONSTRAINT backoffice_sales_invoices_draft_number_unique UNIQUE(company_id,draft_no),
  CONSTRAINT backoffice_sales_invoices_invoice_number_unique UNIQUE(company_id,invoice_no),
  CONSTRAINT backoffice_sales_invoices_event_unique UNIQUE(company_id,financial_event_id),
  CONSTRAINT backoffice_sales_invoices_order_fk FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoices_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoices_store_fk FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoices_warehouse_fk FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoices_term_fk FOREIGN KEY(company_id,payment_term_id)
    REFERENCES public.backoffice_sales_payment_terms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoices_event_fk FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoices_type_check CHECK(invoice_type IN('REGULAR','DOWN_PAYMENT')),
  CONSTRAINT backoffice_sales_invoices_status_check CHECK(status IN('DRAFT','POSTED','CANCELED','REVERSED')),
  CONSTRAINT backoffice_sales_invoices_shape_check CHECK(
    invoice_sequence>0 AND currency_code~'^[A-Z]{3}$' AND master_version>0
    AND jsonb_typeof(customer_snapshot)='object'
    AND jsonb_typeof(payment_term_snapshot)='object'
    AND jsonb_typeof(commercial_snapshot)='object'
    AND ((invoice_type='REGULAR' AND down_payment_mode IS NULL AND down_payment_input IS NULL)
      OR (invoice_type='DOWN_PAYMENT' AND down_payment_mode IN('PERCENT','FIXED')
        AND down_payment_input>0
        AND (down_payment_mode<>'PERCENT' OR down_payment_input<=100)))
    AND down_payment_basis_total>=0 AND charge_total>=0 AND discount_total>=0
    AND tax_total>=0 AND down_payment_deduction_total>=0
    AND grand_total=charge_total-discount_total+tax_total-down_payment_deduction_total
    AND grand_total>=0
    AND ((status='DRAFT' AND invoice_no IS NULL AND posted_at IS NULL AND posted_by IS NULL
          AND canceled_at IS NULL AND canceled_by IS NULL)
      OR (status='POSTED' AND invoice_no IS NOT NULL AND posted_at IS NOT NULL AND posted_by IS NOT NULL
          AND canceled_at IS NULL AND canceled_by IS NULL)
      OR (status='CANCELED' AND posted_at IS NULL AND posted_by IS NULL
          AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
          AND nullif(btrim(cancel_reason),'') IS NOT NULL)
      OR (status='REVERSED' AND invoice_no IS NOT NULL AND posted_at IS NOT NULL AND posted_by IS NOT NULL
          AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
          AND nullif(btrim(cancel_reason),'') IS NOT NULL)))
);

CREATE TABLE public.backoffice_sales_invoice_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  sales_order_line_id uuid,
  line_no integer NOT NULL,
  line_type text NOT NULL,
  effect_type text NOT NULL,
  product_id uuid,
  uom_id uuid,
  quantity_uom numeric(24,6),
  base_qty_per_uom numeric(24,6),
  quantity_base numeric(24,6),
  unit_price numeric(24,4) NOT NULL,
  discount_amount numeric(24,4) NOT NULL DEFAULT 0,
  tax_amount numeric(24,4) NOT NULL DEFAULT 0,
  line_amount numeric(24,4) NOT NULL,
  description text NOT NULL,
  source_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_invoice_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_invoice_lines_lineage_unique
    UNIQUE(company_id,id,invoice_id,sales_order_id,sales_order_line_id),
  CONSTRAINT backoffice_sales_invoice_lines_order_unique UNIQUE(company_id,invoice_id,line_no),
  CONSTRAINT backoffice_sales_invoice_lines_invoice_fk
    FOREIGN KEY(company_id,invoice_id,sales_order_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id,sales_order_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_lines_order_line_fk
    FOREIGN KEY(company_id,sales_order_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,sales_order_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_lines_product_fk FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_lines_uom_fk FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_lines_shape_check CHECK(
    line_no>0 AND line_type IN('PRODUCT','DOWN_PAYMENT','DOWN_PAYMENT_DEDUCTION')
    AND effect_type IN('CHARGE','DEDUCTION') AND unit_price>=0
    AND discount_amount>=0 AND tax_amount>=0 AND line_amount>=0
    AND nullif(btrim(description),'') IS NOT NULL AND jsonb_typeof(source_snapshot)='object'
    AND ((line_type='PRODUCT' AND effect_type='CHARGE' AND sales_order_line_id IS NOT NULL
      AND product_id IS NOT NULL AND uom_id IS NOT NULL AND quantity_uom>0
      AND base_qty_per_uom>0 AND quantity_base=quantity_uom*base_qty_per_uom)
      OR (line_type='DOWN_PAYMENT' AND effect_type='CHARGE' AND sales_order_line_id IS NULL
        AND product_id IS NULL AND uom_id IS NULL AND quantity_uom IS NULL
        AND base_qty_per_uom IS NULL AND quantity_base IS NULL)
      OR (line_type='DOWN_PAYMENT_DEDUCTION' AND effect_type='DEDUCTION'
        AND sales_order_line_id IS NULL AND product_id IS NULL AND uom_id IS NULL
        AND quantity_uom IS NULL AND base_qty_per_uom IS NULL AND quantity_base IS NULL)))
);

CREATE TABLE public.backoffice_sales_invoice_quantity_allocations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  invoice_line_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  allocated_base_qty numeric(24,6) NOT NULL,
  status text NOT NULL DEFAULT 'HELD',
  released_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_invoice_qty_alloc_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_invoice_qty_alloc_line_unique UNIQUE(company_id,invoice_line_id),
  CONSTRAINT backoffice_sales_invoice_qty_alloc_lineage_fk
    FOREIGN KEY(company_id,invoice_line_id,invoice_id,sales_order_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_invoice_lines(
      company_id,id,invoice_id,sales_order_id,sales_order_line_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_qty_alloc_shape_check CHECK(
    allocated_base_qty>0 AND status IN('HELD','POSTED','RELEASED')
    AND (status<>'RELEASED' OR nullif(btrim(released_reason),'') IS NOT NULL))
);

CREATE TABLE public.backoffice_sales_down_payment_applications(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  down_payment_invoice_id uuid NOT NULL,
  regular_invoice_id uuid NOT NULL,
  applied_amount numeric(24,4) NOT NULL,
  status text NOT NULL DEFAULT 'HELD',
  released_reason text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_dp_applications_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_dp_applications_pair_unique
    UNIQUE(company_id,down_payment_invoice_id,regular_invoice_id),
  CONSTRAINT backoffice_sales_dp_applications_dp_fk
    FOREIGN KEY(company_id,down_payment_invoice_id,sales_order_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id,sales_order_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_dp_applications_regular_fk
    FOREIGN KEY(company_id,regular_invoice_id,sales_order_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id,sales_order_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_dp_applications_order_fk FOREIGN KEY(company_id,sales_order_id)
    REFERENCES public.backoffice_sales_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_dp_applications_shape_check CHECK(
    down_payment_invoice_id<>regular_invoice_id AND applied_amount>0
    AND status IN('HELD','POSTED','RELEASED')
    AND (status<>'RELEASED' OR nullif(btrim(released_reason),'') IS NOT NULL))
);

CREATE TABLE public.backoffice_sales_invoice_receivable_schedules(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  installment_no integer NOT NULL,
  due_date date NOT NULL,
  amount_due numeric(24,4) NOT NULL,
  allocated_payment_amount numeric(24,4) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'DRAFT',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_invoice_schedules_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_invoice_schedules_order_unique UNIQUE(company_id,invoice_id,installment_no),
  CONSTRAINT backoffice_sales_invoice_schedules_invoice_fk FOREIGN KEY(company_id,invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_schedules_shape_check CHECK(
    installment_no>0 AND amount_due>0 AND allocated_payment_amount>=0
    AND allocated_payment_amount<=amount_due
    AND status IN('DRAFT','OPEN','PARTIALLY_PAID','PAID','CANCELED'))
);

CREATE TABLE public.backoffice_sales_invoice_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL,
  invoice_id uuid NOT NULL,
  action text NOT NULL,
  operation_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  reason text,
  before_state jsonb,
  after_state jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_invoice_audit_invoice_fk FOREIGN KEY(company_id,invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_invoice_audit_operation_unique UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_invoice_audit_shape_check CHECK(
    action IN('CREATE_DRAFT','UPDATE_DRAFT','CANCEL_DRAFT','POST','REVERSE')
    AND (before_state IS NOT NULL OR after_state IS NOT NULL)
    AND (before_state IS NULL OR jsonb_typeof(before_state)='object')
    AND (after_state IS NULL OR jsonb_typeof(after_state)='object'))
);

CREATE INDEX backoffice_sales_invoices_order_status
  ON public.backoffice_sales_invoices(company_id,sales_order_id,status,invoice_sequence);
CREATE INDEX backoffice_sales_invoice_qty_alloc_order_line
  ON public.backoffice_sales_invoice_quantity_allocations(company_id,sales_order_line_id,status);
CREATE INDEX backoffice_sales_invoice_schedules_due
  ON public.backoffice_sales_invoice_receivable_schedules(company_id,status,due_date);

CREATE FUNCTION private.trg_guard_backoffice_sales_proforma_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_PROFORMA_IMMUTABLE'; END IF;
  IF (NEW.company_id,NEW.sales_order_id,NEW.proforma_no,NEW.source_version,
      NEW.document_snapshot,NEW.issued_by,NEW.issued_at)
    IS DISTINCT FROM
    (OLD.company_id,OLD.sales_order_id,OLD.proforma_no,OLD.source_version,
      OLD.document_snapshot,OLD.issued_by,OLD.issued_at)
    OR OLD.status<>'ISSUED' OR NEW.status<>'CANCELED'
    OR NEW.canceled_by IS NULL OR NEW.canceled_at IS NULL
    OR nullif(btrim(NEW.cancel_reason),'') IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_PROFORMA_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;
CREATE FUNCTION private.trg_guard_backoffice_sales_invoice_foundation_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_INVOICE_HISTORY_IMMUTABLE';
END
$$;
CREATE TRIGGER backoffice_sales_proformas_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_proformas
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_proforma_history();
CREATE TRIGGER backoffice_sales_invoice_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_invoice_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_invoice_foundation_history();

ALTER TABLE public.backoffice_sales_payment_terms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_payment_term_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_proformas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_invoice_quantity_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_down_payment_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_invoice_receivable_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_invoice_audit ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.backoffice_sales_payment_terms,
  public.backoffice_sales_payment_term_lines,public.backoffice_sales_proformas,
  public.backoffice_sales_invoices,public.backoffice_sales_invoice_lines,
  public.backoffice_sales_invoice_quantity_allocations,
  public.backoffice_sales_down_payment_applications,
  public.backoffice_sales_invoice_receivable_schedules,
  public.backoffice_sales_invoice_audit FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_proforma_history(),
  private.trg_guard_backoffice_sales_invoice_foundation_history()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_proforma_history(),
  private.trg_guard_backoffice_sales_invoice_foundation_history()
  TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909156000','backoffice_sales_invoice_accounting_foundation',
  'Zero-backfill Odoo-style Backoffice Payment Terms, non-accounting Pro-Forma, Regular/Down Payment Invoice, quantity holds, DP deduction, receivable schedule and immutable audit foundation; no runtime Invoice, Payment, Event, Journal, Stock, FIFO or POS effect');

NOTIFY pgrst,'reload schema';
COMMIT;
