-- Company-scoped AUTO_RO stock matching. Default OFF.
-- Reconciles one Draft in place; never mutates Stock, FIFO, Finance, Receipt, or PO.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260923110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: 20260923110000 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260924100000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='company_purchase_replenishment_settings'
      AND column_name='auto_ro_stock_match_enabled')
    OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
      AND table_name='purchase_daily_batches'
      AND column_name IN('stock_match_fingerprint','stock_matched_at',
        'stock_match_operation_id'))
    OR EXISTS(SELECT 1 FROM pg_constraint constraint_row
      WHERE constraint_row.conname IN(
        'purchase_daily_batches_stock_match_operation_fk',
        'purchase_daily_batches_stock_match_shape'))
    OR to_regprocedure('private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid)') IS NOT NULL
    OR to_regprocedure('private.reconcile_purchase_daily_auto_ro_stock_core(uuid,uuid,bigint,uuid,uuid,timestamptz)') IS NOT NULL
    OR to_regprocedure('public.get_purchase_daily_auto_ro_stock_match(uuid)') IS NOT NULL
    OR to_regprocedure('public.reconcile_purchase_daily_auto_ro_stock(uuid,bigint,uuid)') IS NOT NULL
    OR to_regprocedure('public.confirm_purchase_daily_auto_ro_matched(uuid,bigint,uuid,uuid,boolean,jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: stock-match object collision';
  END IF;
  IF (SELECT count(*) FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid='public.purchase_daily_batch_operations'::regclass
        AND constraint_row.conname='purchase_daily_batch_operations_operation_type_check')<>1
    OR (SELECT count(*) FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid='public.purchase_daily_batch_audit'::regclass
        AND constraint_row.conname='purchase_daily_batch_audit_action_check')<>1
    OR (SELECT count(*) FROM pg_constraint constraint_row
      WHERE constraint_row.conrelid=
        'public.company_purchase_replenishment_setting_audit'::regclass
        AND constraint_row.conname=
          'company_purchase_replenishment_setting_audit_action_check')<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: mutable constraint contract drifted';
  END IF;
  IF to_regprocedure('private.get_purchase_daily_replenishment_candidates_core(uuid,date)') IS NULL
    OR to_regprocedure('private.confirm_purchase_daily_auto_ro_core(uuid,uuid,bigint,uuid,uuid,jsonb,timestamptz)') IS NULL
    OR to_regprocedure('public.confirm_purchase_daily_auto_ro(uuid,bigint,uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical AUTO_RO runtime missing';
  END IF;
END
$guard$;

ALTER TABLE public.company_purchase_replenishment_settings
  ADD COLUMN auto_ro_stock_match_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.purchase_daily_batches
  ADD COLUMN stock_match_fingerprint text,
  ADD COLUMN stock_matched_at timestamptz,
  ADD COLUMN stock_match_operation_id uuid;

ALTER TABLE public.purchase_daily_batch_operations
  DROP CONSTRAINT purchase_daily_batch_operations_operation_type_check,
  ADD CONSTRAINT purchase_daily_batch_operations_operation_type_check CHECK(
    operation_type IN('GENERATE_AUTO_RO','CONFIRM_AUTO_RO','GENERATE_AUTO_PO',
      'CANCEL_BATCH','RECONCILE_AUTO_RO'));

ALTER TABLE public.purchase_daily_batch_audit
  DROP CONSTRAINT purchase_daily_batch_audit_action_check,
  ADD CONSTRAINT purchase_daily_batch_audit_action_check CHECK(
    action IN('GENERATE','REUSE','CONFIRM','AUTO_PO_REUSE','AUTO_PO_GENERATE',
      'CANCEL','RECONCILE'));

ALTER TABLE public.company_purchase_replenishment_setting_audit
  DROP CONSTRAINT company_purchase_replenishment_setting_audit_action_check,
  ADD CONSTRAINT company_purchase_replenishment_setting_audit_action_check CHECK(
    action IN('PROVISION','MODE_CHANGE','DEFAULT_WAREHOUSE_CHANGE',
      'DRAFT_ROLL_FORWARD_POLICY_CHANGE','STOCK_MATCH_POLICY_CHANGE'));

ALTER TABLE public.purchase_daily_batches
  ADD CONSTRAINT purchase_daily_batches_stock_match_operation_fk
  FOREIGN KEY(company_id,stock_match_operation_id)
  REFERENCES public.purchase_daily_batch_operations(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_daily_batches_stock_match_shape CHECK(
    (stock_match_operation_id IS NULL AND stock_match_fingerprint IS NULL
      AND stock_matched_at IS NULL)
    OR (stock_match_operation_id IS NOT NULL AND stock_match_fingerprint IS NOT NULL
      AND btrim(stock_match_fingerprint)<>'' AND stock_matched_at IS NOT NULL));

COMMENT ON COLUMN public.company_purchase_replenishment_settings.auto_ro_stock_match_enabled
IS 'When enabled, Draft AUTO_RO can be reconciled in place against current On Hand, Draft RO coverage, and remaining active PO/Stock Request coverage before confirmation.';

CREATE OR REPLACE FUNCTION private.trg_guard_purchase_daily_batch_line()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_status text;v_internal boolean:=
  COALESCE(current_setting('kgs.auto_ro_stock_match',true),'')='on';
BEGIN
  SELECT batch.status INTO v_status FROM public.purchase_daily_batches batch
  WHERE batch.company_id=CASE WHEN TG_OP='DELETE' THEN OLD.company_id ELSE NEW.company_id END
    AND batch.id=CASE WHEN TG_OP='DELETE' THEN OLD.batch_id ELSE NEW.batch_id END;
  IF v_status IS NULL THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_NOT_FOUND'; END IF;
  IF TG_OP='INSERT' THEN
    IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINES_IMMUTABLE'; END IF;
    RETURN NEW;
  END IF;
  IF TG_OP='DELETE' THEN
    IF v_status='DRAFT' AND v_internal THEN RETURN OLD; END IF;
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINE_DELETE_FORBIDDEN';
  END IF;
  IF v_status<>'DRAFT' THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINES_IMMUTABLE'; END IF;
  IF NEW.company_id IS DISTINCT FROM OLD.company_id OR NEW.id IS DISTINCT FROM OLD.id
    OR NEW.batch_id IS DISTINCT FROM OLD.batch_id OR NEW.line_no IS DISTINCT FROM OLD.line_no
    OR NEW.product_id IS DISTINCT FROM OLD.product_id
    OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
    OR NEW.base_uom_id IS DISTINCT FROM OLD.base_uom_id
    OR (NOT v_internal AND (NEW.on_hand_snapshot IS DISTINCT FROM OLD.on_hand_snapshot
      OR NEW.open_purchase_base_qty_snapshot IS DISTINCT FROM OLD.open_purchase_base_qty_snapshot))
    OR NEW.suggested_product_supplier_id IS DISTINCT FROM OLD.suggested_product_supplier_id
    OR NEW.suggested_supplier_id IS DISTINCT FROM OLD.suggested_supplier_id
    OR NEW.product_sku_snapshot IS DISTINCT FROM OLD.product_sku_snapshot
    OR NEW.product_name_snapshot IS DISTINCT FROM OLD.product_name_snapshot
    OR NEW.warehouse_code_snapshot IS DISTINCT FROM OLD.warehouse_code_snapshot
    OR NEW.warehouse_name_snapshot IS DISTINCT FROM OLD.warehouse_name_snapshot
    OR NEW.base_uom_name_snapshot IS DISTINCT FROM OLD.base_uom_name_snapshot
    OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_LINE_SOURCE_IMMUTABLE';
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.get_purchase_daily_auto_ro_stock_match_core(
  p_company_id uuid,p_batch_id uuid
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_batch public.purchase_daily_batches%rowtype;v_base jsonb;v_item jsonb;
  v_need jsonb:='[]'::jsonb;v_saved jsonb;v_surplus jsonb;v_changes jsonb;
  v_other_ro numeric;v_open numeric;v_required numeric;v_status text;v_fingerprint text;
BEGIN
  SELECT * INTO v_batch FROM public.purchase_daily_batches batch
  WHERE batch.company_id=p_company_id AND batch.id=p_batch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_NOT_FOUND'; END IF;
  IF v_batch.mode_snapshot<>'AUTO_RO' THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_BATCH_REQUIRED'; END IF;
  IF v_batch.status<>'DRAFT' THEN RAISE EXCEPTION 'PURCHASE_AUTO_RO_NOT_DRAFT'; END IF;

  v_base:=private.get_purchase_daily_replenishment_candidates_core(
    p_company_id,v_batch.business_date);
  FOR v_item IN SELECT item FROM jsonb_array_elements(v_base->'candidates') item LOOP
    SELECT COALESCE(sum(line.requested_base_qty),0) INTO v_other_ro
    FROM public.purchase_daily_batch_lines line
    JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
      AND batch.id=line.batch_id
    WHERE line.company_id=p_company_id AND batch.mode_snapshot='AUTO_RO'
      AND batch.status='DRAFT' AND batch.id<>p_batch_id
      AND line.product_id=(v_item->>'productId')::uuid
      AND line.warehouse_id=(v_item->>'sourceWarehouseId')::uuid;
    v_open:=(v_item->>'openPurchaseBaseQty')::numeric+v_other_ro;
    v_required:=private.purchase_uncovered_negative_qty(
      (v_item->>'onHandBaseQty')::numeric,v_open);
    v_status:=CASE
      WHEN v_item->>'status' IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS',
        'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')
        THEN v_item->>'status'
      WHEN v_required=0 THEN 'FULLY_COVERED'
      WHEN v_item->>'suggestedSupplierId' IS NULL THEN 'SUPPLIER_PENDING'
      ELSE 'READY' END;
    IF v_required>0 THEN
      v_need:=v_need||jsonb_build_array(v_item||jsonb_build_object(
        'otherDraftRoBaseQty',v_other_ro,'openPurchaseBaseQty',v_open,
        'requestedBaseQty',v_required,'status',v_status));
    END IF;
  END LOOP;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'lineId',line.id,'productId',line.product_id,'warehouseId',line.warehouse_id,
      'requestedBaseQty',line.requested_base_qty,'onHandBaseQty',line.on_hand_snapshot,
      'openPurchaseBaseQty',line.open_purchase_base_qty_snapshot,
      'productSku',line.product_sku_snapshot,'productName',line.product_name_snapshot,
      'baseUomName',line.base_uom_name_snapshot) ORDER BY line.line_no),'[]'::jsonb)
  INTO v_saved FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=p_company_id AND line.batch_id=p_batch_id;

  WITH saved AS (
    SELECT * FROM jsonb_to_recordset(v_saved) AS row(
      "lineId" uuid,"productId" uuid,"warehouseId" uuid,"requestedBaseQty" numeric,
      "onHandBaseQty" numeric,"openPurchaseBaseQty" numeric,"productSku" text,
      "productName" text,"baseUomName" text)
  ), current_need AS (
    SELECT * FROM jsonb_to_recordset(v_need) AS row(
      "productId" uuid,"sourceWarehouseId" uuid,"requestedBaseQty" numeric,
      "onHandBaseQty" numeric,"openPurchaseBaseQty" numeric,"productSku" text,
      "productName" text,"baseUomName" text)
  ), mismatch AS (
    SELECT COALESCE(saved."productId",current_need."productId") product_id,
      COALESCE(saved."warehouseId",current_need."sourceWarehouseId") warehouse_id,
      COALESCE(saved."productSku",current_need."productSku") product_sku,
      COALESCE(saved."productName",current_need."productName") product_name,
      COALESCE(saved."baseUomName",current_need."baseUomName") uom_name,
      COALESCE(saved."requestedBaseQty",0) old_qty,
      COALESCE(current_need."requestedBaseQty",0) new_qty,
      current_need."onHandBaseQty" current_on_hand,
      current_need."openPurchaseBaseQty" current_open_purchase
    FROM saved FULL JOIN current_need ON current_need."productId"=saved."productId"
      AND current_need."sourceWarehouseId"=saved."warehouseId"
    WHERE saved."productId" IS NULL OR current_need."productId" IS NULL
      OR saved."requestedBaseQty" IS DISTINCT FROM current_need."requestedBaseQty"
      OR saved."onHandBaseQty" IS DISTINCT FROM current_need."onHandBaseQty"
      OR saved."openPurchaseBaseQty" IS DISTINCT FROM current_need."openPurchaseBaseQty"
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'productId',mismatch.product_id,'warehouseId',mismatch.warehouse_id,
    'productSku',mismatch.product_sku,'productName',mismatch.product_name,
    'baseUomName',mismatch.uom_name,'previousQty',mismatch.old_qty,
    'recommendedQty',mismatch.new_qty,'deltaQty',mismatch.new_qty-mismatch.old_qty,
    'currentOnHand',mismatch.current_on_hand,
    'currentOpenCoverage',mismatch.current_open_purchase,
    'latestMovement',movement.payload)
    ORDER BY mismatch.product_name,mismatch.product_id),'[]'::jsonb)
  INTO v_changes FROM mismatch
  LEFT JOIN LATERAL (
    SELECT jsonb_build_object('type',stock_movement.movement_type,
      'quantity',stock_movement.qty_change,
      'postedAt',COALESCE(stock_movement.posted_at,stock_movement.created_at),
      'referenceTable',stock_movement.reference_table,
      'referenceId',stock_movement.reference_id) payload
    FROM public.stock_movements stock_movement
    WHERE stock_movement.company_id=p_company_id
      AND stock_movement.product_id=mismatch.product_id
      AND stock_movement.warehouse_id=mismatch.warehouse_id
      AND stock_movement.movement_status='POSTED'
    ORDER BY COALESCE(stock_movement.posted_at,stock_movement.created_at) DESC,
      stock_movement.id DESC LIMIT 1
  ) movement ON true;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'productId',stock.product_id,'warehouseId',stock.warehouse_id,
    'productSku',product.sku,'productName',product.name,
    'warehouseName',warehouse.name,'baseUomName',uom.name,
    'onHandQty',stock.stock_qty,'latestMovement',movement.payload)
    ORDER BY product.name,stock.product_id),'[]'::jsonb)
  INTO v_surplus FROM public.product_stocks stock
  JOIN public.products product ON product.company_id=stock.company_id
    AND product.id=stock.product_id AND product.is_active
  JOIN public.warehouses warehouse ON warehouse.company_id=stock.company_id
    AND warehouse.id=stock.warehouse_id AND warehouse.is_active
    AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT'
  JOIN public.uoms uom ON uom.company_id=product.company_id AND uom.id=product.uom_id
  LEFT JOIN LATERAL (
    SELECT jsonb_build_object('type',stock_movement.movement_type,
      'quantity',stock_movement.qty_change,
      'postedAt',COALESCE(stock_movement.posted_at,stock_movement.created_at),
      'referenceTable',stock_movement.reference_table,
      'referenceId',stock_movement.reference_id) payload
    FROM public.stock_movements stock_movement
    WHERE stock_movement.company_id=stock.company_id
      AND stock_movement.product_id=stock.product_id
      AND stock_movement.warehouse_id=stock.warehouse_id
      AND stock_movement.movement_status='POSTED'
    ORDER BY COALESCE(stock_movement.posted_at,stock_movement.created_at) DESC,
      stock_movement.id DESC LIMIT 1
  ) movement ON true
  WHERE stock.company_id=p_company_id AND stock.stock_qty>0;

  SELECT md5(COALESCE(jsonb_agg(item ORDER BY item->>'sourceWarehouseId',
    item->>'productId'),'[]'::jsonb)::text) INTO v_fingerprint
  FROM jsonb_array_elements(v_need) item;
  RETURN jsonb_build_object('enabled',true,'batchId',v_batch.id,
    'batchNo',v_batch.batch_no,'batchVersion',v_batch.master_version,
    'matchedAt',v_batch.stock_matched_at,
    'matchOperationId',v_batch.stock_match_operation_id,
    'fingerprint',v_fingerprint,
    'isMatched',v_batch.stock_match_fingerprint IS NOT DISTINCT FROM v_fingerprint,
    'needs',v_need,'changes',v_changes,'surplus',v_surplus,
    'changeCount',jsonb_array_length(v_changes),
    'surplusCount',jsonb_array_length(v_surplus));
END
$$;

CREATE FUNCTION public.get_purchase_daily_auto_ro_stock_match(p_batch_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_enabled boolean;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  SELECT setting.auto_ro_stock_match_enabled INTO v_enabled
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company AND setting.replenishment_mode='AUTO_RO';
  IF NOT COALESCE(v_enabled,false) THEN
    RETURN jsonb_build_object('enabled',false,'batchId',p_batch_id);
  END IF;
  RETURN private.get_purchase_daily_auto_ro_stock_match_core(v_company,p_batch_id);
END
$$;

CREATE FUNCTION private.reconcile_purchase_daily_auto_ro_stock_core(
  p_company_id uuid,p_batch_id uuid,p_master_version bigint,p_operation_id uuid,
  p_actor_id uuid,p_effective_at timestamptz
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_batch public.purchase_daily_batches%rowtype;
  v_existing public.purchase_daily_batch_operations%rowtype;
  v_before jsonb;v_preview jsonb;v_item jsonb;v_result jsonb;v_after jsonb;
  v_hash text;v_line integer:=0;v_total numeric:=0;v_count integer:=0;
BEGIN
  IF p_company_id IS NULL OR p_batch_id IS NULL OR p_master_version IS NULL
    OR p_operation_id IS NULL OR p_actor_id IS NULL OR p_effective_at IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_STOCK_MATCH_CONTEXT_REQUIRED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.purchase_daily_batch_operations operation
      WHERE operation.id=p_operation_id AND operation.company_id<>p_company_id) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
  END IF;
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.company_id=p_company_id AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.operation_type<>'RECONCILE_AUTO_RO'
      OR v_existing.batch_id IS DISTINCT FROM p_batch_id
      OR (v_existing.result_snapshot->>'masterVersion')::bigint
        IS DISTINCT FROM p_master_version+1 THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':PURCHASE_DAILY_REPLENISHMENT',0));
  SELECT * INTO v_batch FROM public.purchase_daily_batches batch
  WHERE batch.company_id=p_company_id AND batch.id=p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_NOT_FOUND'; END IF;
  IF v_batch.mode_snapshot<>'AUTO_RO' OR v_batch.status<>'DRAFT' THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_NOT_DRAFT';
  END IF;
  IF v_batch.master_version<>p_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF EXISTS(SELECT 1 FROM public.supplier_order_documents document
      WHERE document.company_id=p_company_id
        AND document.purchase_daily_batch_id=p_batch_id
        AND document.status<>'CANCELED')
    OR EXISTS(SELECT 1 FROM public.purchase_daily_batch_order_allocations allocation
      WHERE allocation.company_id=p_company_id AND allocation.batch_id=p_batch_id) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_STOCK_MATCH_HAS_PO';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.company_purchase_replenishment_settings setting
      WHERE setting.company_id=p_company_id AND setting.replenishment_mode='AUTO_RO'
        AND setting.auto_ro_stock_match_enabled) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_STOCK_MATCH_DISABLED';
  END IF;
  PERFORM 1 FROM public.product_stocks stock WHERE stock.company_id=p_company_id
    ORDER BY stock.product_id,stock.warehouse_id FOR UPDATE;
  v_before:=private.purchase_daily_batch_snapshot(p_company_id,p_batch_id);
  v_preview:=private.get_purchase_daily_auto_ro_stock_match_core(p_company_id,p_batch_id);
  v_hash:=md5(jsonb_build_object('companyId',p_company_id,'batchId',p_batch_id,
    'expectedVersion',p_master_version,'fingerprint',v_preview->>'fingerprint')::text);
  PERFORM set_config('kgs.auto_ro_stock_match','on',true);
  DELETE FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=p_company_id AND line.batch_id=p_batch_id;
  FOR v_item IN SELECT item FROM jsonb_array_elements(v_preview->'needs') item
    ORDER BY item->>'sourceWarehouseName',item->>'productName',item->>'productId'
  LOOP
    v_line:=v_line+1;v_count:=v_count+1;
    v_total:=v_total+(v_item->>'requestedBaseQty')::numeric;
    INSERT INTO public.purchase_daily_batch_lines(company_id,batch_id,line_no,
      product_id,warehouse_id,base_uom_id,on_hand_snapshot,
      open_purchase_base_qty_snapshot,requested_base_qty,
      suggested_product_supplier_id,suggested_supplier_id,
      supplier_assignment_status,product_sku_snapshot,product_name_snapshot,
      warehouse_code_snapshot,warehouse_name_snapshot,base_uom_name_snapshot,
      destination_warehouse_id,requires_transfer,
      destination_warehouse_code_snapshot,destination_warehouse_name_snapshot,
      readiness_status)
    VALUES(p_company_id,p_batch_id,v_line,(v_item->>'productId')::uuid,
      (v_item->>'sourceWarehouseId')::uuid,(v_item->>'baseUomId')::uuid,
      (v_item->>'onHandBaseQty')::numeric,(v_item->>'openPurchaseBaseQty')::numeric,
      (v_item->>'requestedBaseQty')::numeric,
      NULLIF(v_item->>'suggestedProductSupplierId','')::uuid,
      NULLIF(v_item->>'suggestedSupplierId','')::uuid,
      v_item->>'supplierAssignmentStatus',v_item->>'productSku',v_item->>'productName',
      v_item->>'sourceWarehouseCode',v_item->>'sourceWarehouseName',v_item->>'baseUomName',
      NULLIF(v_item->>'destinationWarehouseId','')::uuid,
      COALESCE((v_item->>'requiresTransfer')::boolean,false),
      NULLIF(v_item->>'destinationWarehouseCode',''),
      NULLIF(v_item->>'destinationWarehouseName',''),v_item->>'status');
  END LOOP;
  v_result:=jsonb_build_object('batchId',p_batch_id,'batchNo',v_batch.batch_no,
    'masterVersion',p_master_version+1,'matchOperationId',p_operation_id,
    'fingerprint',v_preview->>'fingerprint','lineCount',v_count,
    'requestedTotalBaseQty',v_total,'appliedChanges',v_preview->'changes',
    'surplus',v_preview->'surplus','exactRetry',false,
    'batchLines',(SELECT COALESCE(jsonb_agg(to_jsonb(line) ORDER BY line.line_no),
      '[]'::jsonb) FROM public.purchase_daily_batch_lines line
      WHERE line.company_id=p_company_id AND line.batch_id=p_batch_id));
  INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
    operation_type,request_hash,result_snapshot,actor_id)
  VALUES(p_operation_id,p_company_id,p_batch_id,'RECONCILE_AUTO_RO',v_hash,v_result,p_actor_id);
  UPDATE public.purchase_daily_batches SET line_count=v_count,
    requested_total_base_qty=v_total,stock_match_fingerprint=v_preview->>'fingerprint',
    stock_matched_at=p_effective_at,stock_match_operation_id=p_operation_id,
    master_version=master_version+1,updated_at=p_effective_at
  WHERE company_id=p_company_id AND id=p_batch_id;
  v_after:=private.purchase_daily_batch_snapshot(p_company_id,p_batch_id);
  INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,
    action,actor_id,before_state,after_state)
  VALUES(p_company_id,p_batch_id,p_operation_id,'RECONCILE',p_actor_id,v_before,v_after);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.reconcile_purchase_daily_auto_ro_stock(
  p_batch_id uuid,p_master_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','POST');
  RETURN private.reconcile_purchase_daily_auto_ro_stock_core(v_company,p_batch_id,
    p_master_version,p_operation_id,v_actor,clock_timestamp());
END
$$;

CREATE FUNCTION public.confirm_purchase_daily_auto_ro_matched(
  p_batch_id uuid,p_master_version bigint,p_operation_id uuid,
  p_stock_match_operation_id uuid,p_accept_variance boolean,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_batch public.purchase_daily_batches%rowtype;v_preview jsonb;v_variance jsonb;
  v_core_allocations jsonb;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','POST');
  IF EXISTS(SELECT 1 FROM public.purchase_daily_batch_operations operation
      WHERE operation.company_id=v_company AND operation.id=p_operation_id) THEN
    SELECT COALESCE(jsonb_agg(item||jsonb_build_object(
      '_stockMatchOperationId',p_stock_match_operation_id,
      '_acceptVariance',COALESCE(p_accept_variance,false))),'[]'::jsonb)
    INTO v_core_allocations FROM jsonb_array_elements(p_allocations) item;
    RETURN private.confirm_purchase_daily_auto_ro_core(v_company,p_batch_id,
      p_master_version,p_operation_id,v_actor,v_core_allocations,clock_timestamp());
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.company_purchase_replenishment_settings setting
      WHERE setting.company_id=v_company AND setting.replenishment_mode='AUTO_RO'
        AND setting.auto_ro_stock_match_enabled) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_STOCK_MATCH_DISABLED';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':PURCHASE_DAILY_REPLENISHMENT',0));
  SELECT * INTO v_batch FROM public.purchase_daily_batches batch
  WHERE batch.company_id=v_company AND batch.id=p_batch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_NOT_FOUND'; END IF;
  IF v_batch.status<>'DRAFT' OR v_batch.mode_snapshot<>'AUTO_RO' THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_NOT_DRAFT';
  END IF;
  IF v_batch.stock_match_operation_id IS DISTINCT FROM p_stock_match_operation_id THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_STOCK_MATCH_REQUIRED';
  END IF;
  PERFORM 1 FROM public.product_stocks stock WHERE stock.company_id=v_company
    ORDER BY stock.product_id,stock.warehouse_id FOR UPDATE;
  v_preview:=private.get_purchase_daily_auto_ro_stock_match_core(v_company,p_batch_id);
  IF NOT COALESCE((v_preview->>'isMatched')::boolean,false)
    OR jsonb_array_length(v_preview->'changes')>0 THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_REFRESH_REQUIRED'
      USING DETAIL=jsonb_build_object('changes',v_preview->'changes')::text;
  END IF;
  WITH supplied AS (
    SELECT (item->>'batchLineId')::uuid line_id,
      sum((item->>'orderedQty')::numeric*product_uom.factor_to_base) ordered_base_qty
    FROM jsonb_array_elements(p_allocations) item
    JOIN public.purchase_daily_batch_lines line ON line.company_id=v_company
      AND line.batch_id=p_batch_id AND line.id=(item->>'batchLineId')::uuid
    JOIN public.product_uoms product_uom ON product_uom.company_id=line.company_id
      AND product_uom.product_id=line.product_id
      AND product_uom.uom_id=(item->>'purchaseUomId')::uuid
    GROUP BY (item->>'batchLineId')::uuid
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('batchLineId',line.id,
    'productSku',line.product_sku_snapshot,'productName',line.product_name_snapshot,
    'recommendedBaseQty',line.requested_base_qty,
    'orderedBaseQty',COALESCE(supplied.ordered_base_qty,0),
    'projectedDifference',COALESCE(supplied.ordered_base_qty,0)-line.requested_base_qty)
    ORDER BY line.line_no),'[]'::jsonb)
  INTO v_variance FROM public.purchase_daily_batch_lines line
  LEFT JOIN supplied ON supplied.line_id=line.id
  WHERE line.company_id=v_company AND line.batch_id=p_batch_id
    AND COALESCE(supplied.ordered_base_qty,0)<>line.requested_base_qty;
  IF jsonb_array_length(v_variance)>0 AND NOT COALESCE(p_accept_variance,false) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_VARIANCE_CONFIRMATION_REQUIRED'
      USING DETAIL=jsonb_build_object('variances',v_variance)::text;
  END IF;
  SELECT COALESCE(jsonb_agg(item||jsonb_build_object(
    '_stockMatchOperationId',p_stock_match_operation_id,
    '_acceptVariance',COALESCE(p_accept_variance,false))),'[]'::jsonb)
  INTO v_core_allocations FROM jsonb_array_elements(p_allocations) item;
  RETURN private.confirm_purchase_daily_auto_ro_core(v_company,p_batch_id,
    p_master_version,p_operation_id,v_actor,v_core_allocations,clock_timestamp());
END
$$;

CREATE OR REPLACE FUNCTION public.confirm_purchase_daily_auto_ro(
  p_batch_id uuid,p_master_version bigint,p_operation_id uuid,p_allocations jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_effective timestamptz:=clock_timestamp();v_roll_forward boolean:=false;
  v_stock_match boolean:=false;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','POST');
  SELECT setting.auto_ro_draft_roll_forward_enabled,
    setting.auto_ro_stock_match_enabled INTO v_roll_forward,v_stock_match
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=v_company AND setting.replenishment_mode='AUTO_RO';
  IF COALESCE(v_stock_match,false)
    AND NOT EXISTS(SELECT 1 FROM public.purchase_daily_batch_operations operation
      WHERE operation.company_id=v_company AND operation.id=p_operation_id
        AND operation.operation_type='CONFIRM_AUTO_RO') THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_RO_STOCK_MATCH_REQUIRED';
  END IF;
  IF COALESCE(v_roll_forward,false) THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(
      v_company::text||':PURCHASE_DAILY_REPLENISHMENT',0));
    IF NOT EXISTS(SELECT 1 FROM public.purchase_daily_batch_operations operation
        WHERE operation.company_id=v_company AND operation.id=p_operation_id) THEN
      PERFORM private.assert_purchase_daily_auto_ro_fresh(
        v_company,p_batch_id,v_effective);
    END IF;
  END IF;
  RETURN private.confirm_purchase_daily_auto_ro_core(v_company,p_batch_id,
    p_master_version,p_operation_id,v_actor,p_allocations,v_effective);
END
$$;

REVOKE ALL ON FUNCTION private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid),
  private.reconcile_purchase_daily_auto_ro_stock_core(uuid,uuid,bigint,uuid,uuid,timestamptz)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.get_purchase_daily_auto_ro_stock_match_core(uuid,uuid),
  private.reconcile_purchase_daily_auto_ro_stock_core(uuid,uuid,bigint,uuid,uuid,timestamptz)
TO service_role;
REVOKE ALL ON FUNCTION public.get_purchase_daily_auto_ro_stock_match(uuid),
  public.reconcile_purchase_daily_auto_ro_stock(uuid,bigint,uuid),
  public.confirm_purchase_daily_auto_ro_matched(uuid,bigint,uuid,uuid,boolean,jsonb)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_daily_auto_ro_stock_match(uuid),
  public.reconcile_purchase_daily_auto_ro_stock(uuid,bigint,uuid),
  public.confirm_purchase_daily_auto_ro_matched(uuid,bigint,uuid,uuid,boolean,jsonb)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260924100000','purchase_auto_ro_stock_match',
  'Default-OFF in-place Draft AUTO_RO stock matching with RO/PO lineage de-duplication, Carry Forward read model, explicit variance acceptance, audit, and concurrency-safe confirmation');

COMMIT;
