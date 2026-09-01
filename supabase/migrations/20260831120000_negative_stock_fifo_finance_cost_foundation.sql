-- NSC-1: immutable cost-settlement and Supplier Invoice batch-allocation
-- foundation. No historical stock, FIFO, event, or journal amount is changed.

BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260831120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260831120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs run
    WHERE run.status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active finance queue';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260805220000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260806100000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260814140000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260828260000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: NSC dependencies missing';
  END IF;
  IF to_regclass('public.inventory_cost_adjustment_sources') IS NOT NULL
    OR to_regclass('public.supplier_invoice_batch_cost_allocations') IS NOT NULL
  THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: NSC foundation exists';
  END IF;
END
$guard$;

CREATE TABLE public.inventory_cost_adjustment_sources(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  adjustment_type TEXT NOT NULL,
  source_document_table TEXT NOT NULL,
  source_document_id UUID NOT NULL,
  source_financial_event_id UUID NOT NULL,
  total_quantity_base NUMERIC(24,6) NOT NULL DEFAULT 0,
  planned_cost_variance NUMERIC(20,4) NOT NULL DEFAULT 0,
  inventory_variance NUMERIC(20,4) NOT NULL DEFAULT 0,
  hpp_variance NUMERIC(20,4) NOT NULL DEFAULT 0,
  inventory_account_id UUID NOT NULL,
  offset_account_id UUID NOT NULL,
  variance_account_id UUID,
  status TEXT NOT NULL DEFAULT 'PLANNED',
  idempotency_key TEXT NOT NULL,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  applied_at TIMESTAMPTZ,
  posted_at TIMESTAMPTZ,
  master_version BIGINT NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT inventory_cost_adjustment_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT inventory_cost_adjustment_document_unique
    UNIQUE(company_id,adjustment_type,source_document_id),
  CONSTRAINT inventory_cost_adjustment_event_unique
    UNIQUE(company_id,source_financial_event_id),
  CONSTRAINT inventory_cost_adjustment_idempotency_unique
    UNIQUE(company_id,idempotency_key),
  CONSTRAINT fk_inventory_cost_adjustment_event
    FOREIGN KEY(company_id,source_financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_inventory_cost_adjustment_inventory_account
    FOREIGN KEY(company_id,inventory_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_inventory_cost_adjustment_offset_account
    FOREIGN KEY(company_id,offset_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_inventory_cost_adjustment_variance_account
    FOREIGN KEY(company_id,variance_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT inventory_cost_adjustment_type_check CHECK(
    adjustment_type IN(
      'NEGATIVE_REPLENISHMENT','SUPPLIER_INVOICE_REVALUATION')),
  CONSTRAINT inventory_cost_adjustment_source_check CHECK(
    (adjustment_type='NEGATIVE_REPLENISHMENT'
      AND source_document_table='goods_receipt_documents'
      AND variance_account_id IS NULL)
    OR (adjustment_type='SUPPLIER_INVOICE_REVALUATION'
      AND source_document_table='supplier_invoice_documents'
      AND variance_account_id IS NOT NULL)),
  CONSTRAINT inventory_cost_adjustment_status_check CHECK(
    status IN('PLANNED','APPLIED','POSTED','NO_EFFECT')),
  CONSTRAINT inventory_cost_adjustment_quantity_check
    CHECK(total_quantity_base>=0),
  CONSTRAINT inventory_cost_adjustment_application_check CHECK(
    (status='PLANNED' AND applied_at IS NULL AND posted_at IS NULL)
    OR (status='APPLIED' AND applied_at IS NOT NULL AND posted_at IS NULL
      AND ((adjustment_type='NEGATIVE_REPLENISHMENT'
          AND inventory_variance+hpp_variance=0
          AND hpp_variance=planned_cost_variance)
        OR (adjustment_type='SUPPLIER_INVOICE_REVALUATION'
          AND planned_cost_variance=inventory_variance+hpp_variance)))
    OR (status='POSTED' AND applied_at IS NOT NULL AND posted_at IS NOT NULL
      AND ((adjustment_type='NEGATIVE_REPLENISHMENT'
          AND inventory_variance+hpp_variance=0
          AND hpp_variance=planned_cost_variance)
        OR (adjustment_type='SUPPLIER_INVOICE_REVALUATION'
          AND planned_cost_variance=inventory_variance+hpp_variance)))
    OR (status='NO_EFFECT' AND planned_cost_variance=0
      AND inventory_variance=0 AND hpp_variance=0
      AND posted_at IS NULL)),
  CONSTRAINT inventory_cost_adjustment_identity_check CHECK(
    btrim(source_document_table)<>'' AND btrim(idempotency_key)<>''
    AND master_version>0)
);

CREATE INDEX idx_inventory_cost_adjustment_status
  ON public.inventory_cost_adjustment_sources(company_id,status,created_at,id);

CREATE TABLE public.supplier_invoice_batch_cost_allocations(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL,
  document_id UUID NOT NULL,
  supplier_invoice_allocation_id UUID NOT NULL,
  receipt_line_id UUID NOT NULL,
  product_batch_id UUID NOT NULL,
  allocated_base_qty NUMERIC(24,6) NOT NULL,
  price_variance_total NUMERIC(20,4) NOT NULL,
  remaining_base_qty_snapshot NUMERIC(24,6),
  sold_base_qty_snapshot NUMERIC(24,6),
  inventory_variance NUMERIC(20,4),
  hpp_variance NUMERIC(20,4),
  previous_cogs_unit NUMERIC(24,10),
  revalued_cogs_unit NUMERIC(24,10),
  application_status TEXT NOT NULL DEFAULT 'PLANNED',
  applied_financial_event_id UUID,
  applied_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT supplier_invoice_batch_cost_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT supplier_invoice_batch_cost_source_unique
    UNIQUE(company_id,supplier_invoice_allocation_id,product_batch_id),
  CONSTRAINT fk_supplier_invoice_batch_cost_document
    FOREIGN KEY(company_id,document_id)
    REFERENCES public.supplier_invoice_documents(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_supplier_invoice_batch_cost_allocation
    FOREIGN KEY(company_id,supplier_invoice_allocation_id)
    REFERENCES public.supplier_invoice_allocations(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT fk_supplier_invoice_batch_cost_receipt_line
    FOREIGN KEY(company_id,receipt_line_id)
    REFERENCES public.goods_receipt_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_supplier_invoice_batch_cost_batch
    FOREIGN KEY(company_id,product_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_supplier_invoice_batch_cost_event
    FOREIGN KEY(company_id,applied_financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT supplier_invoice_batch_cost_quantity_check
    CHECK(allocated_base_qty>0),
  CONSTRAINT supplier_invoice_batch_cost_status_check
    CHECK(application_status IN('PLANNED','APPLIED')),
  CONSTRAINT supplier_invoice_batch_cost_application_check CHECK(
    (application_status='PLANNED'
      AND remaining_base_qty_snapshot IS NULL
      AND sold_base_qty_snapshot IS NULL
      AND inventory_variance IS NULL AND hpp_variance IS NULL
      AND previous_cogs_unit IS NULL AND revalued_cogs_unit IS NULL
      AND applied_financial_event_id IS NULL AND applied_at IS NULL)
    OR (application_status='APPLIED'
      AND remaining_base_qty_snapshot>=0 AND sold_base_qty_snapshot>=0
      AND remaining_base_qty_snapshot+sold_base_qty_snapshot=allocated_base_qty
      AND price_variance_total=inventory_variance+hpp_variance
      AND previous_cogs_unit>=0 AND revalued_cogs_unit>=0
      AND applied_financial_event_id IS NOT NULL AND applied_at IS NOT NULL))
);

CREATE INDEX idx_supplier_invoice_batch_cost_document
  ON public.supplier_invoice_batch_cost_allocations(
    company_id,document_id,application_status,id);
CREATE INDEX idx_supplier_invoice_batch_cost_batch
  ON public.supplier_invoice_batch_cost_allocations(
    company_id,product_batch_id,application_status,id);

ALTER TABLE public.inventory_cost_adjustment_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoice_batch_cost_allocations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.inventory_cost_adjustment_sources,
  public.supplier_invoice_batch_cost_allocations
FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.inventory_cost_adjustment_sources,
  public.supplier_invoice_batch_cost_allocations TO service_role;

UPDATE public.system_events event SET
  conditional_account_functions=ARRAY(
    SELECT DISTINCT function_key
    FROM unnest(COALESCE(event.conditional_account_functions,ARRAY[]::TEXT[])
      ||ARRAY['COGS']::TEXT[])
      function_key
    ORDER BY function_key)
WHERE event.system_key='GOODS_RECEIPT'
  AND NOT ('COGS'=ANY(COALESCE(event.conditional_account_functions,
    ARRAY[]::TEXT[])));

UPDATE public.system_events event SET
  conditional_account_functions=ARRAY(
    SELECT DISTINCT function_key
    FROM unnest(COALESCE(event.conditional_account_functions,ARRAY[]::TEXT[])
      ||ARRAY['INVENTORY_ASSET','COGS']::TEXT[]) function_key
    ORDER BY function_key)
WHERE event.system_key='SUPPLIER_INVOICE'
  AND (NOT ('INVENTORY_ASSET'=ANY(COALESCE(
      event.conditional_account_functions,ARRAY[]::TEXT[])))
    OR NOT ('COGS'=ANY(COALESCE(
      event.conditional_account_functions,ARRAY[]::TEXT[]))));

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260831120000','negative_stock_fifo_finance_cost_foundation',
  'Immutable negative replenishment and Supplier Invoice batch-cost allocation foundation; no historical value mutation');

COMMIT;
