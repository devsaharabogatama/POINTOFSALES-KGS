-- Forward-fix the transient commercial state used while rebuilding a Draft or
-- revising a confirmed Backoffice Sales Order. The amount constraint remains
-- enabled; all totals are reset as one internally consistent zero state before
-- canonical line/commercial calculation writes the final values.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909143000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: activity cancel guard required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909144000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909144000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

DO $patch_atomic_commercial_reset$
DECLARE
  v_definition text;
  v_patched text;
  v_needle text:='subtotal=0,discount_total=0,tax_total=0,grand_total=0,';
  v_replacement text:='subtotal=0,discount_total=0,global_discount=0,tax_total=0,grand_total_before_rounding=0,rounding_direction=''NONE'',rounding_increment=100,rounding_adjustment=0,grand_total=0,';
BEGIN
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF (length(v_definition)-length(replace(v_definition,v_needle,'')))
       / nullif(length(v_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: transient commercial reset boundary drift';
  END IF;
  v_patched:=replace(v_definition,v_needle,v_replacement);
  EXECUTE v_patched;
END
$patch_atomic_commercial_reset$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909144000','backoffice_sales_revision_commercial_reset_fix',
  'Reset all commercial header totals to a constraint-valid zero state before canonical line rebuild; preserve amount constraint and zero downstream effects');

NOTIFY pgrst,'reload schema';
COMMIT;
