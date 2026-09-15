-- Step 5/6.2 forward-fix: discrepancy LOST/DAMAGED is not a Stock Adjustment document.
DO $pre_enum_guard$
DECLARE v_definition text;v_constraint text;v_old_count integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912135000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 5/6.2 base migration required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912136000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912136000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  SELECT pg_get_constraintdef(constraint_state.oid) INTO v_constraint
  FROM pg_constraint constraint_state
  WHERE constraint_state.conrelid='public.stock_movements'::regclass
    AND constraint_state.conname='stock_movements_adjustment_snapshot_complete';
  IF v_constraint IS NULL OR position('ADJUSTMENT' in v_constraint)=0
    OR position('stock_adjustment_documents' in v_constraint)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Stock Adjustment constraint drift';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)'))
  INTO v_definition;
  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: shortage resolver missing';
  END IF;
  v_old_count:=(length(v_definition)-length(replace(v_definition,
    '''ADJUSTMENT''::public.stock_movement_type','')))
    /length('''ADJUSTMENT''::public.stock_movement_type');
  IF v_old_count<>1
    OR position('''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type' in v_definition)>0
    OR position('backoffice_sales_discrepancy_stock_effects' in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: shortage resolver movement anchor drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.stock_movements movement
    WHERE movement.reference_table='backoffice_sales_discrepancy_stock_effects'
      AND movement.movement_type='ADJUSTMENT'::public.stock_movement_type) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: committed invalid discrepancy Adjustment movement exists';
  END IF;
END
$pre_enum_guard$;

ALTER TYPE public.stock_movement_type
  ADD VALUE IF NOT EXISTS 'BACKOFFICE_DISCREPANCY_LOSS';

BEGIN;
DO $patch$
DECLARE
  v_definition text;
  v_old text:='''ADJUSTMENT''::public.stock_movement_type';
  v_new text:='''BACKOFFICE_DISCREPANCY_LOSS''::public.stock_movement_type';
  v_old_count integer;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912136000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912136000';
  END IF;
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)'))
  INTO STRICT v_definition;
  v_old_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_old_count<>1 OR position(v_new in v_definition)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: shortage resolver changed after enum provision';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
  SELECT pg_get_functiondef(to_regprocedure(
    'private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)'))
  INTO STRICT v_definition;
  IF position(v_old in v_definition)>0 OR position(v_new in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_POSTCONDITION_FAILED: discrepancy loss movement type not replaced';
  END IF;
END
$patch$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912136000','backoffice_sales_discrepancy_loss_movement_type_fix',
  'Forward-fixes LOST/DAMAGED shortage Stock Movement from reserved ADJUSTMENT to BACKOFFICE_DISCREPANCY_LOSS while preserving discrepancy source, Stock, FIFO and Finance lineage');
NOTIFY pgrst,'reload schema';
COMMIT;
