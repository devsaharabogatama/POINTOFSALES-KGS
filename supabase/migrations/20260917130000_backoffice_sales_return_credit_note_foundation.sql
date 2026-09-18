-- Backoffice Sales Return Step 3/5: explicit Invoice reconciliation and
-- Customer Credit Note foundation. No automatic Refund is created here.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917122000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Return Receipt guard fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917130000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_sales_credit_notes') IS NOT NULL
    OR to_regclass('public.backoffice_sales_credit_note_lines') IS NOT NULL
    OR to_regclass('public.backoffice_sales_return_invoice_allocations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_credit_note_operations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_credit_note_audit') IS NOT NULL
    OR EXISTS(SELECT 1 FROM public.access_permission_catalog
      WHERE permission_key='finance.customer_credit_notes') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Credit Note foundation collision';
  END IF;
END
$guard$;

INSERT INTO public.access_permission_catalog(
  permission_key,module_key,permission_label,description,view_roles,
  operator_roles,approver_roles,supported_capabilities,required_any_features,
  is_customizable,enforcement_status
) VALUES(
  'finance.customer_credit_notes','FINANCE','Credit Note Customer',
  'Alokasi Retur Customer ke Invoice dan posting Credit Note pengurang piutang',
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','SALES_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE'],
  ARRAY['VIEW','CREATE_DRAFT','EDIT_DRAFT','POST'],
  ARRAY['backoffice_delivered_qty_sales_enabled'],true,'ENFORCED'
);

-- A physical return after posting must not be mixed into the pre-Invoice
-- return ledger. Keeping both ledgers preserves Invoice history and prevents
-- Qty To Invoice from being reduced twice.
ALTER TABLE public.backoffice_sales_order_lines
  DROP CONSTRAINT backoffice_sales_order_lines_invoiceable_quantity_check,
  DROP COLUMN net_delivered_base_qty,
  ADD COLUMN returned_after_invoice_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  ADD COLUMN net_delivered_base_qty numeric(24,6)
    GENERATED ALWAYS AS (
      accepted_base_qty-returned_before_invoice_base_qty-returned_after_invoice_base_qty
    ) STORED,
  ADD CONSTRAINT backoffice_sales_order_lines_invoiceable_quantity_check CHECK(
    approved_overage_base_qty>=0
    AND accepted_base_qty>=0 AND accepted_base_qty<=ordered_base_qty
    AND returned_before_invoice_base_qty>=0
    AND returned_after_invoice_base_qty>=0
    AND returned_before_invoice_base_qty+returned_after_invoice_base_qty<=accepted_base_qty
    AND draft_invoice_allocated_base_qty>=0 AND invoiced_base_qty>=0
    AND draft_invoice_allocated_base_qty+invoiced_base_qty
      <=accepted_base_qty-returned_before_invoice_base_qty
    AND returned_after_invoice_base_qty<=invoiced_base_qty);

ALTER TABLE public.backoffice_sales_invoices
  ADD COLUMN return_adjustment_pending_confirmation boolean NOT NULL DEFAULT false,
  ADD COLUMN return_adjusted_at timestamptz,
  ADD CONSTRAINT backoffice_sales_invoice_return_adjustment_check CHECK(
    (NOT return_adjustment_pending_confirmation)
    OR (status='DRAFT' AND return_adjusted_at IS NOT NULL));

ALTER TABLE public.backoffice_sales_invoice_operations
  DROP CONSTRAINT backoffice_sales_invoice_operations_shape_check,
  ADD CONSTRAINT backoffice_sales_invoice_operations_shape_check CHECK(
    operation_type IN('SAVE_DRAFT','CANCEL_DRAFT','SET_DOWN_PAYMENTS','POST',
      'RETURN_ADJUST_DRAFT')
    AND (expected_version IS NULL OR expected_version>0)
    AND request_hash~'^[0-9a-f]{64}$'
    AND jsonb_typeof(response_snapshot)='object');
ALTER TABLE public.backoffice_sales_invoice_audit
  DROP CONSTRAINT backoffice_sales_invoice_audit_shape_check,
  ADD CONSTRAINT backoffice_sales_invoice_audit_shape_check CHECK(
    action IN('CREATE_DRAFT','UPDATE_DRAFT','CANCEL_DRAFT','POST','REVERSE',
      'RETURN_ADJUST_DRAFT')
    AND (before_state IS NOT NULL OR after_state IS NOT NULL)
    AND (before_state IS NULL OR jsonb_typeof(before_state)='object')
    AND (after_state IS NULL OR jsonb_typeof(after_state)='object'));

CREATE FUNCTION private.trg_confirm_return_adjusted_invoice()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF OLD.status='DRAFT' AND NEW.status='POSTED'
    AND OLD.return_adjustment_pending_confirmation THEN
    NEW.return_adjustment_pending_confirmation:=false;
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER backoffice_sales_invoice_return_confirmation
BEFORE UPDATE ON public.backoffice_sales_invoices
FOR EACH ROW EXECUTE FUNCTION private.trg_confirm_return_adjusted_invoice();

ALTER TABLE public.backoffice_sales_invoice_receivable_schedules
  DROP CONSTRAINT backoffice_sales_invoice_schedules_shape_check,
  ADD COLUMN credited_amount numeric(24,4) NOT NULL DEFAULT 0,
  ADD CONSTRAINT backoffice_sales_invoice_schedules_shape_check CHECK(
    installment_no>0 AND amount_due>0 AND allocated_payment_amount>=0
    AND credited_amount>=0
    AND allocated_payment_amount+credited_amount<=amount_due
    AND status IN('DRAFT','OPEN','PARTIALLY_PAID','PAID','CANCELED'));

CREATE SEQUENCE private.backoffice_sales_credit_note_no_seq AS bigint START WITH 1;
REVOKE ALL ON SEQUENCE private.backoffice_sales_credit_note_no_seq
  FROM PUBLIC,anon,authenticated;
GRANT USAGE,SELECT ON SEQUENCE private.backoffice_sales_credit_note_no_seq TO service_role;

CREATE TABLE public.backoffice_sales_credit_notes(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  return_id uuid NOT NULL,
  source_invoice_id uuid NOT NULL,
  customer_id uuid NOT NULL,
  store_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  credit_note_no text NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT',
  credit_note_date date NOT NULL,
  currency_code text NOT NULL,
  reason text NOT NULL,
  charge_total numeric(24,4) NOT NULL DEFAULT 0,
  discount_total numeric(24,4) NOT NULL DEFAULT 0,
  tax_total numeric(24,4) NOT NULL DEFAULT 0,
  delivery_fee_amount numeric(24,4) NOT NULL DEFAULT 0,
  grand_total numeric(24,4) NOT NULL DEFAULT 0,
  ar_reduction_amount numeric(24,4) NOT NULL DEFAULT 0,
  refund_liability_amount numeric(24,4) NOT NULL DEFAULT 0,
  financial_event_id uuid,
  source_invoice_snapshot jsonb NOT NULL,
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
  CONSTRAINT backoffice_sales_credit_notes_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_credit_notes_number_unique UNIQUE(company_id,credit_note_no),
  CONSTRAINT backoffice_sales_credit_notes_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_notes_invoice_fk FOREIGN KEY(company_id,source_invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_notes_customer_fk FOREIGN KEY(company_id,customer_id)
    REFERENCES public.customers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_notes_store_fk FOREIGN KEY(company_id,store_id)
    REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_notes_warehouse_fk FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_notes_event_fk FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_notes_shape_check CHECK(
    status IN('DRAFT','POSTED','CANCELED','REVERSED')
    AND currency_code~'^[A-Z]{3}$' AND nullif(btrim(reason),'') IS NOT NULL
    AND jsonb_typeof(source_invoice_snapshot)='object' AND master_version>0
    AND charge_total>=0 AND discount_total>=0 AND tax_total>=0
    AND delivery_fee_amount>=0
    AND grand_total=charge_total-discount_total+tax_total+delivery_fee_amount
    AND grand_total>=0 AND (status='DRAFT' OR grand_total>0)
    AND ar_reduction_amount>=0 AND refund_liability_amount>=0
    AND ar_reduction_amount+refund_liability_amount
      =CASE WHEN status IN('POSTED','REVERSED') THEN grand_total ELSE 0 END
    AND ((status='DRAFT' AND posted_at IS NULL AND posted_by IS NULL
          AND canceled_at IS NULL AND canceled_by IS NULL AND financial_event_id IS NULL)
      OR (status='POSTED' AND posted_at IS NOT NULL AND posted_by IS NOT NULL
          AND canceled_at IS NULL AND canceled_by IS NULL AND financial_event_id IS NOT NULL)
      OR (status='CANCELED' AND posted_at IS NULL AND posted_by IS NULL
          AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
          AND nullif(btrim(cancel_reason),'') IS NOT NULL)
      OR (status='REVERSED' AND posted_at IS NOT NULL AND posted_by IS NOT NULL
          AND canceled_at IS NOT NULL AND canceled_by IS NOT NULL
          AND financial_event_id IS NOT NULL AND nullif(btrim(cancel_reason),'') IS NOT NULL))));

CREATE UNIQUE INDEX backoffice_sales_credit_note_active_source
  ON public.backoffice_sales_credit_notes(company_id,return_id,source_invoice_id)
  WHERE status='DRAFT';
CREATE INDEX backoffice_sales_credit_notes_invoice_status
  ON public.backoffice_sales_credit_notes(company_id,source_invoice_id,status,created_at,id);

CREATE TABLE public.backoffice_sales_credit_note_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  credit_note_id uuid NOT NULL,
  return_id uuid NOT NULL,
  return_receipt_line_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  source_invoice_line_id uuid NOT NULL,
  line_no integer NOT NULL,
  product_id uuid NOT NULL,
  uom_id uuid NOT NULL,
  quantity_uom numeric(24,6) NOT NULL,
  base_qty_per_uom numeric(24,6) NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  unit_price numeric(24,4) NOT NULL,
  discount_amount numeric(24,4) NOT NULL,
  tax_amount numeric(24,4) NOT NULL,
  line_amount numeric(24,4) NOT NULL,
  source_snapshot jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_credit_note_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_credit_note_lines_number_unique UNIQUE(company_id,credit_note_id,line_no),
  CONSTRAINT backoffice_sales_credit_note_lines_header_fk FOREIGN KEY(company_id,credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_lines_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_lines_receipt_fk
    FOREIGN KEY(company_id,return_receipt_line_id)
    REFERENCES public.backoffice_sales_return_receipt_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_lines_order_line_fk
    FOREIGN KEY(company_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_lines_invoice_line_fk
    FOREIGN KEY(company_id,source_invoice_line_id)
    REFERENCES public.backoffice_sales_invoice_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_lines_product_fk FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_lines_uom_fk FOREIGN KEY(company_id,uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_lines_shape_check CHECK(
    line_no>0 AND quantity_uom>0 AND base_qty_per_uom>0
    AND quantity_base=round(quantity_uom*base_qty_per_uom,6)
    AND unit_price>=0 AND discount_amount>=0 AND tax_amount>=0 AND line_amount>=0
    AND line_amount+discount_amount>0 AND jsonb_typeof(source_snapshot)='object'));

CREATE TABLE public.backoffice_sales_return_invoice_allocations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  return_id uuid NOT NULL,
  return_receipt_line_id uuid NOT NULL,
  sales_order_line_id uuid NOT NULL,
  allocation_type text NOT NULL,
  invoice_id uuid,
  invoice_line_id uuid,
  credit_note_id uuid,
  allocated_base_qty numeric(24,6) NOT NULL,
  invoice_line_snapshot jsonb,
  operation_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_return_invoice_alloc_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_return_invoice_alloc_source_unique
    UNIQUE(company_id,operation_id,return_receipt_line_id,allocation_type,invoice_line_id),
  CONSTRAINT backoffice_sales_return_invoice_alloc_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_invoice_alloc_receipt_fk
    FOREIGN KEY(company_id,return_receipt_line_id)
    REFERENCES public.backoffice_sales_return_receipt_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_invoice_alloc_order_line_fk
    FOREIGN KEY(company_id,sales_order_line_id)
    REFERENCES public.backoffice_sales_order_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_invoice_alloc_invoice_fk FOREIGN KEY(company_id,invoice_id)
    REFERENCES public.backoffice_sales_invoices(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_invoice_alloc_credit_note_fk
    FOREIGN KEY(company_id,credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_return_invoice_alloc_shape_check CHECK(
    allocation_type IN('UNINVOICED','DRAFT_INVOICE','POSTED_INVOICE')
    AND allocated_base_qty>0
    AND ((allocation_type='UNINVOICED' AND invoice_id IS NULL
          AND invoice_line_id IS NULL AND credit_note_id IS NULL
          AND invoice_line_snapshot IS NULL)
      OR (allocation_type='DRAFT_INVOICE' AND invoice_id IS NOT NULL
          AND invoice_line_id IS NOT NULL AND credit_note_id IS NULL
          AND jsonb_typeof(invoice_line_snapshot)='object')
      OR (allocation_type='POSTED_INVOICE' AND invoice_id IS NOT NULL
          AND invoice_line_id IS NOT NULL AND credit_note_id IS NOT NULL
          AND jsonb_typeof(invoice_line_snapshot)='object'))));

CREATE INDEX backoffice_sales_return_invoice_alloc_receipt
  ON public.backoffice_sales_return_invoice_allocations(company_id,return_receipt_line_id,id);
CREATE INDEX backoffice_sales_return_invoice_alloc_invoice
  ON public.backoffice_sales_return_invoice_allocations(company_id,invoice_id,invoice_line_id,id);

CREATE TABLE public.backoffice_sales_credit_note_operations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  operation_type text NOT NULL,
  return_id uuid NOT NULL,
  credit_note_id uuid,
  expected_version bigint,
  request_hash text NOT NULL,
  response_snapshot jsonb NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_credit_note_operations_identity_unique UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_credit_note_operations_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_operations_note_fk FOREIGN KEY(company_id,credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_operations_shape_check CHECK(
    operation_type IN('ALLOCATE_RETURN','EDIT_DRAFT','POST')
    AND (expected_version IS NULL OR expected_version>0)
    AND request_hash~'^[0-9a-f]{64}$' AND jsonb_typeof(response_snapshot)='object'));

CREATE TABLE public.backoffice_sales_credit_note_audit(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  return_id uuid NOT NULL,
  credit_note_id uuid,
  operation_id uuid NOT NULL,
  action text NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  before_state jsonb,
  after_state jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_credit_note_audit_return_fk FOREIGN KEY(company_id,return_id)
    REFERENCES public.backoffice_sales_returns(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_audit_note_fk FOREIGN KEY(company_id,credit_note_id)
    REFERENCES public.backoffice_sales_credit_notes(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_audit_operation_fk FOREIGN KEY(company_id,operation_id)
    REFERENCES public.backoffice_sales_credit_note_operations(company_id,operation_id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_credit_note_audit_shape_check CHECK(
    action IN('ALLOCATE_RETURN','CREATE_DRAFT','EDIT_DRAFT','POST')
    AND (before_state IS NULL OR jsonb_typeof(before_state)='object')
    AND jsonb_typeof(after_state)='object'));

CREATE FUNCTION private.trg_guard_backoffice_sales_credit_note_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_CREDIT_NOTE_HISTORY_IMMUTABLE';
END
$$;

CREATE TRIGGER backoffice_sales_credit_note_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_credit_note_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_credit_note_history();
CREATE TRIGGER backoffice_sales_return_invoice_allocations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_invoice_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_credit_note_history();
CREATE TRIGGER backoffice_sales_credit_note_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_credit_note_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_credit_note_history();
CREATE TRIGGER backoffice_sales_credit_note_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_credit_note_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_credit_note_history();

ALTER TABLE public.backoffice_sales_credit_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_credit_note_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_return_invoice_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_credit_note_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_credit_note_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.backoffice_sales_credit_notes,
  public.backoffice_sales_credit_note_lines,
  public.backoffice_sales_return_invoice_allocations,
  public.backoffice_sales_credit_note_operations,
  public.backoffice_sales_credit_note_audit FROM PUBLIC,anon,authenticated;
GRANT ALL ON TABLE public.backoffice_sales_credit_notes,
  public.backoffice_sales_credit_note_lines,
  public.backoffice_sales_return_invoice_allocations,
  public.backoffice_sales_credit_note_operations,
  public.backoffice_sales_credit_note_audit TO service_role;

REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_credit_note_history()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_credit_note_history()
  TO service_role;
REVOKE ALL ON FUNCTION private.trg_confirm_return_adjusted_invoice()
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_confirm_return_adjusted_invoice()
  TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917130000','backoffice_sales_return_credit_note_foundation',
  'Step 3/5 explicit Return allocation, Draft Invoice adjustment marker, posted-return ledger and Customer Credit Note immutable foundation; no Refund settlement');
NOTIFY pgrst,'reload schema';
COMMIT;
