-- Forward-fix: qualify pgcrypto digest without widening SECURITY DEFINER search_path.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260908120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice order runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260908121000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260908121000';
  END IF;
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: extensions.digest missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.company_features
    WHERE feature_code='backoffice_delivered_qty_sales_enabled' AND is_enabled) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Sales feature must remain disabled';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_orders)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_order_operations) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: runtime must remain unused';
  END IF;
END
$guard$;

DO $fix$
DECLARE v_signature text;v_before text;v_after text;
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)',
    'private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)'
  ] LOOP
    v_before:=pg_get_functiondef(to_regprocedure(v_signature));
    IF (length(v_before)-length(replace(v_before,'digest(convert_to(','')))
      / length('digest(convert_to(') <> 1 THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: digest definition drift for %',v_signature;
    END IF;
    v_after:=replace(v_before,'digest(convert_to(','extensions.digest(convert_to(');
    EXECUTE v_after;
  END LOOP;
END
$fix$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260908121000','backoffice_sales_order_runtime_digest_fix',
  'Schema-qualify pgcrypto digest in Backoffice Sales exact-operation hashing; no data or downstream effect');

COMMIT;
