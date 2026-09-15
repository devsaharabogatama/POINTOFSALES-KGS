-- Forward-fix only: schema-qualify Supabase pgcrypto digest in Draft Invoice
-- exact-retry hashing. No business behavior, row, permission, or search_path change.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909157000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Draft Invoice runtime required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909158000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909158000';
  END IF;
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: extensions.digest(bytea,text) missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_invoices
    UNION ALL SELECT 1 FROM public.backoffice_sales_invoice_operations
    UNION ALL SELECT 1 FROM public.backoffice_sales_invoice_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: failed behavior did not roll back runtime rows';
  END IF;
END
$guard$;

DO $fix$
DECLARE v_signature text;v_before text;v_after text;
  v_needle text:='digest(convert_to(';
BEGIN
  FOREACH v_signature IN ARRAY ARRAY[
    'private.save_backoffice_sales_invoice_draft_core(uuid,bigint,uuid,uuid,jsonb)',
    'public.cancel_backoffice_sales_invoice_draft(uuid,bigint,uuid,text)'
  ] LOOP
    IF to_regprocedure(v_signature) IS NULL THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: routine missing %',v_signature;
    END IF;
    v_before:=pg_get_functiondef(to_regprocedure(v_signature));
    IF v_before LIKE '%extensions.digest(convert_to(%' THEN
      CONTINUE;
    END IF;
    IF (length(v_before)-length(replace(v_before,v_needle,'')))
      / length(v_needle)<>1 THEN
      RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: digest definition drift for %',v_signature;
    END IF;
    v_after:=replace(v_before,v_needle,'extensions.digest(convert_to(');
    EXECUTE v_after;
  END LOOP;
END
$fix$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909158000','backoffice_sales_invoice_draft_digest_fix',
  'Schema-qualify pgcrypto extensions.digest(bytea,text) in Draft Invoice Save/Cancel request hashing; no row, business flow, permission, Stock, Finance, Payment or POS change');

COMMIT;
