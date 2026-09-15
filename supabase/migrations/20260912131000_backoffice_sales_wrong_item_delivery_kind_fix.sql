-- Forward-fix Step 4/6.5C3: keep the canonical child Delivery kind contract.
-- Target: isolated Development project only. Applied migration 130000 remains immutable.
BEGIN;

DO $guard$
DECLARE
  v_definition text;
  v_constraint text;
  v_old text:='''CORRECTION'',v_delivery.id,''READY''';
  v_new text:='''BACKORDER'',v_delivery.id,''READY''';
  v_old_count integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C3 base migration 20260912130000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912131000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912131000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;

  SELECT pg_get_constraintdef(oid) INTO v_constraint
  FROM pg_constraint
  WHERE conrelid='public.backoffice_sales_delivery_orders'::regclass
    AND conname='backoffice_sales_delivery_orders_kind_check';
  IF v_constraint IS NULL OR position('BACKORDER' in v_constraint)=0
    OR position('CORRECTION' in v_constraint)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Delivery kind constraint drift: %',v_constraint;
  END IF;

  IF to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C3 private resolver missing';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'))
  INTO v_definition;
  v_old_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_old_count<>1 OR position(v_new in v_definition)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C3 Wrong Item Delivery anchor drift (old %, new %)',
      v_old_count,CASE WHEN position(v_new in v_definition)>0 THEN 1 ELSE 0 END;
  END IF;

  EXECUTE replace(v_definition,v_old,v_new);

  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)'))
  INTO v_definition;
  IF position(v_old in v_definition)>0 OR position(v_new in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: C3 Wrong Item Delivery kind not replaced';
  END IF;
END
$guard$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912131000','backoffice_sales_wrong_item_delivery_kind_fix',
  'Forward-fixes C3 Wrong Item replacement Delivery to canonical BACKORDER kind; business identity remains WRONG_ITEM_CORRECTION in discrepancy lineage');

NOTIFY pgrst,'reload schema';
COMMIT;
