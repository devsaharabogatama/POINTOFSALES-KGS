-- Allow a daily Supplier Order line to retain its known shortage source while
-- receipt destination is selected later at Goods Receipt.
BEGIN;
DO $guard$
DECLARE v_definition text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914111000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260914111000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914112000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914112000';
  END IF;
  SELECT pg_get_constraintdef(oid) INTO v_definition FROM pg_constraint
  WHERE conrelid='public.supplier_order_lines'::regclass
    AND conname='supplier_order_line_warehouse_pair_check';
  IF v_definition IS NULL
    OR position('source_warehouse_id IS NOT NULL) AND (destination_warehouse_id IS NOT NULL'
      in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Supplier Order Warehouse pair drift';
  END IF;
  IF to_regclass('public.supplier_order_lines_unset_destination_unique') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unset-destination index collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
      WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
      WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_process_cutover_plans
      WHERE status IN('DRAFT','PREVIEWED','APPLYING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open Sales process cutover plan';
  END IF;
END
$guard$;

ALTER TABLE public.supplier_order_lines
  DROP CONSTRAINT supplier_order_line_warehouse_pair_check,
  ADD CONSTRAINT supplier_order_line_warehouse_pair_check CHECK(
    (source_warehouse_id IS NULL AND destination_warehouse_id IS NULL)
    OR source_warehouse_id IS NOT NULL);

CREATE UNIQUE INDEX supplier_order_lines_unset_destination_unique
  ON public.supplier_order_lines(company_id,document_id,product_id,ordered_uom_id,
    source_warehouse_id)
  WHERE source_warehouse_id IS NOT NULL AND destination_warehouse_id IS NULL;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914112000','purchase_supplier_order_unset_destination',
  'Allows known shortage source with unset receipt destination on Supplier Order lines; explicit destination remains mandatory at Goods Receipt and null-destination duplicates remain prohibited');
NOTIFY pgrst,'reload schema';
COMMIT;
