-- Forward-fix: populate canonical_unit_price in the atomic Backoffice line INSERT.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909140000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: commercial parity required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909141000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909141000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
END
$guard$;

DO $patch_atomic_insert$
DECLARE
  v_definition text;
  v_patched text;
  v_column_needle text:='product_id,uom_id,ordered_qty,base_qty_per_uom,unit_price,';
  v_column_replacement text:='product_id,uom_id,ordered_qty,base_qty_per_uom,unit_price,canonical_unit_price,';
  v_value_needle text:='v_unit_price,v_sku,v_product_name,v_uom_code,v_uom_name,v_price,v_actor,v_actor);';
  v_value_replacement text:='v_unit_price,COALESCE(NULLIF(v_price->>''canonicalResolvedUnitPrice'','''')::numeric,v_unit_price),v_sku,v_product_name,v_uom_code,v_uom_name,v_price,v_actor,v_actor);';
BEGIN
  SELECT pg_get_functiondef(
    'public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF (length(v_definition)-length(replace(v_definition,v_column_needle,'')))
       / nullif(length(v_column_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: line INSERT column boundary drift';
  END IF;
  IF (length(v_definition)-length(replace(v_definition,v_value_needle,'')))
       / nullif(length(v_value_needle),0)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: line INSERT value boundary drift';
  END IF;
  v_patched:=replace(v_definition,v_column_needle,v_column_replacement);
  v_patched:=replace(v_patched,v_value_needle,v_value_replacement);
  EXECUTE v_patched;
END
$patch_atomic_insert$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909141000','backoffice_sales_canonical_insert_fix',
  'Populate canonical_unit_price atomically from canonicalResolvedUnitPrice, falling back to resolvedUnitPrice when no Backoffice override exists; no downstream effect');

NOTIFY pgrst,'reload schema';
COMMIT;
