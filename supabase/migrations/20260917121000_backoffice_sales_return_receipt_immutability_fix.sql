-- Forward-fix: enforce all Customer Return Receipt history triggers.
BEGIN;
DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260917120000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917121000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917121000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.trg_guard_backoffice_sales_return_receipt_history()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: immutable guard missing';
  END IF;
END
$guard$;

-- POST is resolved through the catalog approver capability bucket. This does
-- not add a second business approval; it authorizes the same Warehouse actors
-- to perform the single atomic receipt post.
DO $permission$
BEGIN
  UPDATE public.access_permission_catalog SET
    operator_roles=ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],
    approver_roles=ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN'],
    supported_capabilities=ARRAY['VIEW','POST']
  WHERE permission_key='inventory.customer_return_receipts';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Customer Return Receipt permission missing';
  END IF;
END
$permission$;

-- Reinstall the canonical guard as well as its triggers. This repairs a
-- drifted function instead of merely proving that a routine name exists.
CREATE OR REPLACE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_OP='UPDATE' AND TG_TABLE_NAME='backoffice_sales_return_receipts'
    AND current_setting('kgs.backoffice_return_receipt_finalize',true)='1'
    AND NEW.id=OLD.id AND NEW.company_id=OLD.company_id
    AND NEW.receipt_no=OLD.receipt_no AND NEW.return_id=OLD.return_id
    AND NEW.receipt_date=OLD.receipt_date AND NEW.status=OLD.status
    AND NEW.total_received_base_qty=OLD.total_received_base_qty
    AND NEW.total_restocked_base_qty=OLD.total_restocked_base_qty
    AND NEW.total_destroyed_base_qty=OLD.total_destroyed_base_qty
    AND OLD.total_fifo_cost=0 AND OLD.total_destroyed_fifo_cost=0
    AND NEW.total_fifo_cost>=0 AND NEW.total_destroyed_fifo_cost>=0
    AND NEW.notes IS NOT DISTINCT FROM OLD.notes AND NEW.posted_by=OLD.posted_by
    AND NEW.posted_at=OLD.posted_at AND NEW.created_at=OLD.created_at THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'BACKOFFICE_SALES_RETURN_RECEIPT_HISTORY_IMMUTABLE';
END
$$;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipts_immutable
  ON public.backoffice_sales_return_receipts;
CREATE TRIGGER backoffice_sales_return_receipts_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipts
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
ALTER TABLE public.backoffice_sales_return_receipts
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipts_immutable;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_lines_immutable
  ON public.backoffice_sales_return_receipt_lines;
CREATE TRIGGER backoffice_sales_return_receipt_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
ALTER TABLE public.backoffice_sales_return_receipt_lines
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_lines_immutable;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_fifo_immutable
  ON public.backoffice_sales_return_receipt_fifo_restorations;
CREATE TRIGGER backoffice_sales_return_receipt_fifo_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_fifo_restorations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
ALTER TABLE public.backoffice_sales_return_receipt_fifo_restorations
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_fifo_immutable;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_operations_immutable
  ON public.backoffice_sales_return_receipt_operations;
CREATE TRIGGER backoffice_sales_return_receipt_operations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_operations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
ALTER TABLE public.backoffice_sales_return_receipt_operations
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_operations_immutable;

DROP TRIGGER IF EXISTS backoffice_sales_return_receipt_audit_immutable
  ON public.backoffice_sales_return_receipt_audit;
CREATE TRIGGER backoffice_sales_return_receipt_audit_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_return_receipt_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_return_receipt_history();
ALTER TABLE public.backoffice_sales_return_receipt_audit
  ENABLE ALWAYS TRIGGER backoffice_sales_return_receipt_audit_immutable;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917121000','backoffice_sales_return_receipt_immutability_fix',
  'Reinstalls the canonical guard and recreates and ENABLE ALWAYS all five Customer Return Receipt immutable history triggers after behavioral audit-mutation guard failure');
COMMIT;
