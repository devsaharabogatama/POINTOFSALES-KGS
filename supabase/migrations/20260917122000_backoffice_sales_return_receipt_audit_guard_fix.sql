-- Forward-fix: separate final Receipt mutation from reject-only history guards.
BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917121000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260917121000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917122000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917122000';
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

CREATE OR REPLACE FUNCTION private.trg_reject_backoffice_sales_return_receipt_history_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_HISTORY_IMMUTABLE';
END
$$;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_lines_immutable
  ON public.backoffice_sales_return_receipt_lines;
CREATE TRIGGER backoffice_sales_return_receipt_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_reject_backoffice_sales_return_receipt_history_mutation();
ALTER TABLE public.backoffice_sales_return_receipt_lines
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_lines_immutable;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_fifo_immutable
  ON public.backoffice_sales_return_receipt_fifo_restorations;
CREATE TRIGGER backoffice_sales_return_receipt_fifo_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_fifo_restorations
FOR EACH ROW EXECUTE FUNCTION private.trg_reject_backoffice_sales_return_receipt_history_mutation();
ALTER TABLE public.backoffice_sales_return_receipt_fifo_restorations
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_fifo_immutable;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_operations_immutable
  ON public.backoffice_sales_return_receipt_operations;
CREATE TRIGGER backoffice_sales_return_receipt_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_reject_backoffice_sales_return_receipt_history_mutation();
ALTER TABLE public.backoffice_sales_return_receipt_operations
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_operations_immutable;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_audit_immutable
  ON public.backoffice_sales_return_receipt_audit;
CREATE TRIGGER backoffice_sales_return_receipt_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_reject_backoffice_sales_return_receipt_history_mutation();
ALTER TABLE public.backoffice_sales_return_receipt_audit
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_audit_immutable;

REVOKE ALL ON FUNCTION
  private.trg_reject_backoffice_sales_return_receipt_history_mutation()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.trg_reject_backoffice_sales_return_receipt_history_mutation()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917122000','backoffice_sales_return_receipt_audit_guard_fix',
  'Separates the conditional final Receipt guard from reject-only immutable line, FIFO, operation and audit history guards');
COMMIT;
