-- Additive lineage foundation for pre-dispatch Sales Order replacement.
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended(
  '20260903100000_sales_order_revision_foundation',0));

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260903100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260903100000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260828100000','20260828110000','20260830110000',
        '20260830120000'))<>4
    OR to_regclass('public.sales_stock_reservations') IS NULL
    OR to_regclass('public.sales_payment_verification_requests') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Order cancellation and reservation runtime required';
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

CREATE TABLE public.sales_order_revisions(
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  source_sales_id UUID NOT NULL,
  replacement_sales_id UUID NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  reason TEXT NOT NULL,
  source_master_version_at_start BIGINT NOT NULL,
  start_idempotency_key UUID NOT NULL,
  apply_idempotency_key UUID,
  started_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  applied_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  applied_at TIMESTAMPTZ,
  abandoned_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  abandoned_at TIMESTAMPTZ,
  abandoned_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_order_revisions_company_id_id_unique UNIQUE(company_id,id),
  CONSTRAINT sales_order_revisions_replacement_unique
    UNIQUE(company_id,replacement_sales_id),
  CONSTRAINT sales_order_revisions_start_idempotency_unique
    UNIQUE(company_id,start_idempotency_key),
  CONSTRAINT sales_order_revisions_distinct_sales
    CHECK(source_sales_id<>replacement_sales_id),
  CONSTRAINT sales_order_revisions_reason_not_blank
    CHECK(btrim(reason)<>'' AND length(reason)<=500),
  CONSTRAINT sales_order_revisions_version_positive
    CHECK(source_master_version_at_start>0),
  CONSTRAINT sales_order_revisions_status_check
    CHECK(status IN('PENDING','APPLIED','ABANDONED')),
  CONSTRAINT sales_order_revisions_lifecycle_shape CHECK(
    (status='PENDING' AND apply_idempotency_key IS NULL
      AND applied_by IS NULL AND applied_at IS NULL
      AND abandoned_by IS NULL AND abandoned_at IS NULL
      AND abandoned_reason IS NULL)
    OR (status='APPLIED' AND apply_idempotency_key IS NOT NULL
      AND applied_by IS NOT NULL AND applied_at IS NOT NULL
      AND abandoned_by IS NULL AND abandoned_at IS NULL
      AND abandoned_reason IS NULL)
    OR (status='ABANDONED' AND apply_idempotency_key IS NULL
      AND applied_by IS NULL AND applied_at IS NULL
      AND abandoned_by IS NOT NULL AND abandoned_at IS NOT NULL
      AND btrim(COALESCE(abandoned_reason,''))<>'')),
  CONSTRAINT fk_sales_order_revision_source FOREIGN KEY(company_id,source_sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT fk_sales_order_revision_replacement FOREIGN KEY(company_id,replacement_sales_id)
    REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_sales_order_revision_pending_source
  ON public.sales_order_revisions(company_id,source_sales_id)
  WHERE status='PENDING';
CREATE UNIQUE INDEX uq_sales_order_revision_apply_idempotency
  ON public.sales_order_revisions(company_id,apply_idempotency_key)
  WHERE apply_idempotency_key IS NOT NULL;
CREATE INDEX idx_sales_order_revision_source_history
  ON public.sales_order_revisions(company_id,source_sales_id,created_at DESC);

CREATE TABLE public.sales_order_revision_audit(
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id UUID NOT NULL,
  revision_id UUID NOT NULL,
  action TEXT NOT NULL CHECK(action IN('START','APPLY','ABANDON')),
  actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  idempotency_key UUID,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT fk_sales_order_revision_audit_header
    FOREIGN KEY(company_id,revision_id)
    REFERENCES public.sales_order_revisions(company_id,id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_sales_order_revision_audit_operation
  ON public.sales_order_revision_audit(company_id,revision_id,action,idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE FUNCTION private.trg_guard_sales_order_revision()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='DELETE' THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_IMMUTABLE';
  END IF;
  IF TG_OP='UPDATE' AND COALESCE(
      current_setting('kgs.sales_order_revision_mutation',TRUE),'')<>'1' THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_MUTATION_FORBIDDEN';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=NEW.company_id AND sale.id=NEW.source_sales_id)
    OR NOT EXISTS(SELECT 1 FROM public.sales_headers sale
      WHERE sale.company_id=NEW.company_id AND sale.id=NEW.replacement_sales_id) THEN
    RAISE EXCEPTION 'SALES_ORDER_REVISION_TENANT_MISMATCH';
  END IF;
  NEW.updated_at:=clock_timestamp();
  RETURN NEW;
END
$$;

CREATE TRIGGER sales_order_revision_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_order_revisions
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_sales_order_revision();

CREATE FUNCTION private.trg_sales_order_revision_audit_immutable()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'SALES_ORDER_REVISION_AUDIT_IMMUTABLE';
END
$$;

CREATE TRIGGER sales_order_revision_audit_immutable
BEFORE UPDATE OR DELETE ON public.sales_order_revision_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_sales_order_revision_audit_immutable();

ALTER TABLE public.sales_order_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_revision_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.sales_order_revisions,
  public.sales_order_revision_audit FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_guard_sales_order_revision(),
  private.trg_sales_order_revision_audit_immutable()
FROM PUBLIC,anon,authenticated;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260903100000','sales_order_revision_foundation',
  'Add zero-backfill tenant-scoped Sales Order replacement lineage and immutable audit; no Order, Reservation, document, Stock, payment or Finance mutation');

COMMIT;
