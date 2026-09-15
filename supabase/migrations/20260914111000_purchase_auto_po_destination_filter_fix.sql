-- Remove the one destination filter left by 20260914110000.
BEGIN;
DO $fix$
DECLARE v_definition text;v_occurrences integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260914110000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914111000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914111000';
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
  v_definition:=pg_get_functiondef(to_regprocedure(
    'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)'));
  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AUTO_PO generator missing';
  END IF;
  v_occurrences:=(length(v_definition)-length(replace(v_definition,
    'AND line.destination_warehouse_id IS NOT NULL','')))/
    length('AND line.destination_warehouse_id IS NOT NULL');
  IF v_occurrences<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: expected exactly one remaining destination filter, found %',v_occurrences;
  END IF;
  v_definition:=replace(v_definition,
    'AND line.destination_warehouse_id IS NOT NULL','');
  EXECUTE v_definition;
END
$fix$;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914111000','purchase_auto_po_destination_filter_fix',
  'Removes the single destination-not-null filter left in AUTO_PO line selection by 20260914110000');
NOTIFY pgrst,'reload schema';
COMMIT;
