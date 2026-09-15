-- Optional Backoffice delivered-quantity Sales: immutable process identity.
-- No Company is enabled and no POS/Stock/Finance runtime is replaced here.
BEGIN;

DO $guard$
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260908100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260908100000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260907100000')
    OR to_regclass('public.platform_features') IS NULL
    OR to_regclass('public.company_features') IS NULL
    OR to_regclass('public.sales_headers') IS NULL
    OR to_regclass('public.access_permission_catalog') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical dependencies missing';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='sales_headers'
        AND column_name IN('sales_origin','sales_process_mode'))
    OR EXISTS(SELECT 1 FROM public.platform_features
      WHERE feature_code='backoffice_delivered_qty_sales_enabled')
    OR to_regprocedure('private.trg_guard_sales_process_identity()') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: process identity collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.access_permission_catalog
      WHERE permission_key='sales.sales_documents') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Sales document permission missing';
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

INSERT INTO public.platform_features(
  feature_code,feature_name,module_code,description
) VALUES(
  'backoffice_delivered_qty_sales_enabled',
  'Backoffice Delivered Quantity Sales',
  'SALES',
  'Optional Quotation to Sales Order to accepted Delivery to multiple Invoice process. POS retail remains unchanged.'
);

ALTER TABLE public.sales_headers
  ADD COLUMN sales_origin TEXT NOT NULL DEFAULT 'POS',
  ADD COLUMN sales_process_mode TEXT NOT NULL DEFAULT 'RETAIL_CONFIRM_INVOICE',
  ADD CONSTRAINT sales_headers_origin_check
    CHECK(sales_origin IN('POS','BACKOFFICE_SALES')),
  ADD CONSTRAINT sales_headers_process_mode_check
    CHECK(sales_process_mode IN(
      'RETAIL_CONFIRM_INVOICE','BACKOFFICE_DELIVERED_QTY_INVOICE')),
  ADD CONSTRAINT sales_headers_origin_process_pair_check CHECK(
    (sales_origin='POS' AND sales_process_mode='RETAIL_CONFIRM_INVOICE')
    OR
    (sales_origin='BACKOFFICE_SALES'
      AND sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE')
  );

COMMENT ON COLUMN public.sales_headers.sales_origin IS
  'Immutable business source. Existing and POS-created rows are POS.';
COMMENT ON COLUMN public.sales_headers.sales_process_mode IS
  'Immutable per-order process snapshot; never inferred again from current Company setting.';

CREATE FUNCTION private.trg_guard_sales_process_identity()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND (
    NEW.sales_origin IS DISTINCT FROM OLD.sales_origin
    OR NEW.sales_process_mode IS DISTINCT FROM OLD.sales_process_mode
  ) THEN
    RAISE EXCEPTION 'SALES_PROCESS_IDENTITY_IMMUTABLE';
  END IF;

  IF NEW.sales_origin='BACKOFFICE_SALES' AND NOT EXISTS(
    SELECT 1 FROM public.company_features feature
    WHERE feature.company_id=NEW.company_id
      AND feature.feature_code='backoffice_delivered_qty_sales_enabled'
      AND feature.is_enabled
  ) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_FEATURE_NOT_ENABLED';
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER sales_headers_process_identity_guard
BEFORE INSERT OR UPDATE OF sales_origin,sales_process_mode,company_id
ON public.sales_headers
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_sales_process_identity();

REVOKE ALL ON FUNCTION private.trg_guard_sales_process_identity()
FROM PUBLIC,anon,authenticated;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260908100000','backoffice_sales_process_identity_foundation',
  'Add default-OFF Backoffice Sales entitlement and immutable POS/Backoffice process identity; no Company enablement and no document, Stock, Payment or Finance effect');

COMMIT;
