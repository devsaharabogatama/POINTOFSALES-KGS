-- Purchase Daily Replenishment Step 5/6B.
-- A missing receipt destination does not block AUTO_PO creation. Warehouse
-- selection remains mandatory when Goods Receipt is created.
BEGIN;

DO $guard$
DECLARE v_candidate text;v_generator text;v_receipt text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Step 5A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260914110000';
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
  IF EXISTS(SELECT 1 FROM public.purchase_daily_batch_lines line
      JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
        AND batch.id=line.batch_id
      WHERE batch.mode_snapshot='AUTO_PO' AND batch.status='DRAFT'
        AND line.readiness_status='WAREHOUSE_SETUP_REQUIRED') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: existing Warehouse-blocked AUTO_PO requires explicit reconciliation';
  END IF;

  SELECT pg_get_functiondef(to_regprocedure(
    'private.get_purchase_daily_automatic_candidates_core(uuid,date)')) INTO v_candidate;
  SELECT pg_get_functiondef(to_regprocedure(
    'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)')) INTO v_generator;
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)')) INTO v_receipt;
  IF v_candidate IS NULL OR v_generator IS NULL OR v_receipt IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Purchase runtime missing';
  END IF;
  IF position($old$WHEN v_item->>'status' IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS',
        'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')
        THEN v_item->>'status'$old$ in v_candidate)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AUTO_PO classifier drift';
  END IF;
  IF position($old$IF v_candidate->>'status' IN('READY','SUPPLIER_PENDING')
      AND NOT EXISTS(SELECT 1 FROM public.warehouses warehouse$old$ in v_generator)=0
    OR (length(v_generator)-length(replace(v_generator,
      'AND line.destination_warehouse_id IS NOT NULL','')))/
      length('AND line.destination_warehouse_id IS NOT NULL')<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AUTO_PO generator drift';
  END IF;
  IF position('AND line.destination_warehouse_id=v_warehouse.id;' in v_receipt)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: daily Receipt Warehouse boundary drift';
  END IF;
END
$guard$;

DO $patch$
DECLARE v_definition text;v_old text;
BEGIN
  v_definition:=pg_get_functiondef(to_regprocedure(
    'private.get_purchase_daily_automatic_candidates_core(uuid,date)'));
  v_definition:=replace(v_definition,
    $old$WHEN v_item->>'status' IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS',
        'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')
        THEN v_item->>'status'$old$,
    $new$WHEN v_item->>'status' IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS',
        'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE')
        THEN v_item->>'status'$new$);
  EXECUTE v_definition;

  v_definition:=pg_get_functiondef(to_regprocedure(
    'private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)'));
  v_old:=$old$    IF v_candidate->>'status' IN('READY','SUPPLIER_PENDING')
      AND NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=p_company_id
          AND warehouse.id=NULLIF(v_candidate->>'destinationWarehouseId','')::uuid
          AND warehouse.is_active AND warehouse.is_purchase_destination
          AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT') THEN
      v_candidate:=v_candidate||jsonb_build_object('status','WAREHOUSE_SETUP_REQUIRED');
    END IF;
$old$;
  IF position(v_old in v_definition)=0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: AUTO_PO Warehouse guard drift';
  END IF;
  v_definition:=replace(v_definition,v_old,'');
  v_definition:=replace(v_definition,
    E'\n      AND line.destination_warehouse_id IS NOT NULL','');
  EXECUTE v_definition;

  v_definition:=pg_get_functiondef(to_regprocedure(
    'public.save_purchase_daily_goods_receipt(uuid,bigint,uuid,uuid,text,text,jsonb)'));
  v_definition:=replace(v_definition,
    'AND line.destination_warehouse_id=v_warehouse.id;',
    'AND (line.destination_warehouse_id IS NULL OR line.destination_warehouse_id=v_warehouse.id);');
  EXECUTE v_definition;
END
$patch$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260914110000','purchase_auto_po_receipt_warehouse_boundary_fix',
  'AUTO_PO creates eligible active Product/source-Warehouse lines even when receipt destination is unset; Goods Receipt remains blocked until an active Purchase receiving Warehouse is selected');
NOTIFY pgrst,'reload schema';
COMMIT;
