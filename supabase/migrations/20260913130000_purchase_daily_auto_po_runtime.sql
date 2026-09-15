-- Purchase Daily Replenishment Step 4/6.
-- AUTO_PO creates confirmed Supplier Orders for every ready daily line after
-- cutoff. Blocked lines remain in the same DRAFT batch and never stop ready
-- lines; Receipt/Stock/FIFO/AP/Finance remain outside this gate.
BEGIN;

DO $guard$
DECLARE v_operation_check text;v_audit_check text;v_line_check text;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260913120000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Purchase Step 3 required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260913130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260913130000';
  END IF;
  IF to_regprocedure('private.get_purchase_daily_auto_ro_candidates_core(uuid,date)') IS NULL
    OR to_regprocedure('private.purchase_daily_batch_snapshot(uuid,uuid)') IS NULL
    OR to_regprocedure('public.private_active_company_id()') IS NULL
    OR to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL
    OR to_regclass('private.purchase_daily_batch_no_seq') IS NULL
    OR to_regclass('private.supplier_order_document_no_seq') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Purchase Step 3 drift';
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
  IF to_regprocedure('private.get_purchase_daily_automatic_candidates_core(uuid,date)') IS NOT NULL
    OR to_regprocedure('private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)') IS NOT NULL
    OR to_regprocedure('public.generate_purchase_daily_auto_po(date,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 4 routine collision';
  END IF;
  SELECT pg_get_constraintdef(oid) INTO v_operation_check
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_operations'::regclass
    AND conname='purchase_daily_batch_operations_operation_type_check';
  SELECT pg_get_constraintdef(oid) INTO v_audit_check
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_audit'::regclass
    AND conname='purchase_daily_batch_audit_action_check';
  SELECT pg_get_constraintdef(oid) INTO v_line_check
  FROM pg_constraint WHERE conrelid='public.purchase_daily_batch_lines'::regclass
    AND conname='purchase_daily_batch_line_readiness_check';
  IF v_operation_check IS NULL OR position('GENERATE_AUTO_RO' in v_operation_check)=0
    OR position('CONFIRM_AUTO_RO' in v_operation_check)=0
    OR position('GENERATE_AUTO_PO' in v_operation_check)>0
    OR v_audit_check IS NULL OR position('GENERATE' in v_audit_check)=0
    OR position('REUSE' in v_audit_check)=0 OR position('CONFIRM' in v_audit_check)=0
    OR position('AUTO_PO_GENERATE' in v_audit_check)>0
    OR v_line_check IS NULL OR position('READY' in v_line_check)=0
    OR position('ORDERED' in v_line_check)=0
    OR position('PURCHASE_UOM_QUANTITY_NOT_EXACT' in v_line_check)>0
    OR position('PRODUCT_UOM_SETUP_REQUIRED' in v_line_check)>0 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Step 3 operation/audit contract drift';
  END IF;
END
$guard$;

ALTER TABLE public.purchase_daily_batch_operations
  DROP CONSTRAINT purchase_daily_batch_operations_operation_type_check,
  ADD CONSTRAINT purchase_daily_batch_operations_operation_type_check CHECK(
    operation_type IN('GENERATE_AUTO_RO','CONFIRM_AUTO_RO','GENERATE_AUTO_PO'));
ALTER TABLE public.purchase_daily_batch_audit
  DROP CONSTRAINT purchase_daily_batch_audit_action_check,
  ADD CONSTRAINT purchase_daily_batch_audit_action_check CHECK(
    action IN('GENERATE','REUSE','CONFIRM','AUTO_PO_GENERATE','AUTO_PO_REUSE'));
ALTER TABLE public.purchase_daily_batch_lines
  DROP CONSTRAINT purchase_daily_batch_line_readiness_check,
  ADD CONSTRAINT purchase_daily_batch_line_readiness_check CHECK(readiness_status IN(
    'READY','SUPPLIER_PENDING','WAREHOUSE_SETUP_REQUIRED',
    'OPEN_REQUEST_WAREHOUSE_AMBIGUOUS','PRODUCT_INACTIVE',
    'SOURCE_WAREHOUSE_INACTIVE','PRODUCT_UOM_SETUP_REQUIRED',
    'PURCHASE_UOM_QUANTITY_NOT_EXACT','ORDERED'));

CREATE FUNCTION private.get_purchase_daily_automatic_candidates_core(
  p_company_id uuid,p_business_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_base jsonb;v_item jsonb;v_candidates jsonb:='[]'::jsonb;
  v_daily_open numeric;v_total_open numeric;v_requested numeric;v_status text;
  v_negative integer:=0;v_actionable integer:=0;v_covered integer:=0;v_blocked integer:=0;
  v_allow_decimal boolean;v_precision integer;v_ordered_qty numeric;
BEGIN
  v_base:=private.get_purchase_daily_replenishment_candidates_core(
    p_company_id,p_business_date);
  FOR v_item IN SELECT item FROM jsonb_array_elements(v_base->'candidates') item LOOP
    -- Only unallocated Draft lines are additional coverage. AUTO_PO lines that
    -- already became ORDERED are already counted by the canonical open-PO resolver.
    SELECT COALESCE(sum(line.requested_base_qty),0) INTO v_daily_open
    FROM public.purchase_daily_batch_lines line
    JOIN public.purchase_daily_batches batch ON batch.company_id=line.company_id
      AND batch.id=line.batch_id
    WHERE line.company_id=p_company_id AND batch.status='DRAFT'
      AND line.readiness_status<>'ORDERED'
      AND line.product_id=(v_item->>'productId')::uuid
      AND line.warehouse_id=(v_item->>'sourceWarehouseId')::uuid;
    v_total_open:=(v_item->>'openPurchaseBaseQty')::numeric+v_daily_open;
    v_requested:=private.purchase_uncovered_negative_qty(
      (v_item->>'onHandBaseQty')::numeric,v_total_open);
    v_status:=CASE
      WHEN v_item->>'status' IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS',
        'PRODUCT_INACTIVE','SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED')
        THEN v_item->>'status'
      WHEN v_requested=0 THEN 'FULLY_COVERED'
      WHEN v_item->>'suggestedSupplierId' IS NULL THEN 'SUPPLIER_PENDING'
      ELSE 'READY' END;
    IF v_status='READY' AND v_base->>'mode'='AUTO_PO' THEN
      SELECT uom.allow_decimal,uom.decimal_precision INTO v_allow_decimal,v_precision
      FROM public.uoms uom WHERE uom.company_id=p_company_id AND uom.is_active
        AND uom.id=NULLIF(v_item->>'suggestedPurchaseUomId','')::uuid;
      v_ordered_qty:=v_requested/NULLIF((v_item->>'suggestedFactorToBase')::numeric,0);
      IF NOT FOUND OR v_ordered_qty IS NULL
        OR (NOT v_allow_decimal AND v_ordered_qty<>trunc(v_ordered_qty))
        OR (v_allow_decimal AND v_ordered_qty<>round(v_ordered_qty,v_precision)) THEN
        v_status:='PURCHASE_UOM_QUANTITY_NOT_EXACT';
      END IF;
    END IF;
    IF v_status='SUPPLIER_PENDING' AND v_base->>'mode'='AUTO_PO'
      AND NOT EXISTS(SELECT 1 FROM public.product_uoms product_uom
        WHERE product_uom.company_id=p_company_id
          AND product_uom.product_id=(v_item->>'productId')::uuid
          AND product_uom.uom_id=(v_item->>'baseUomId')::uuid
          AND product_uom.is_active) THEN
      v_status:='PRODUCT_UOM_SETUP_REQUIRED';
    END IF;
    v_item:=v_item||jsonb_build_object('openDailyRoBaseQty',v_daily_open,
      'openPurchaseBaseQty',v_total_open,'requestedBaseQty',v_requested,'status',v_status);
    v_candidates:=v_candidates||jsonb_build_array(v_item);v_negative:=v_negative+1;
    IF v_requested>0 AND v_status IN('READY','SUPPLIER_PENDING') THEN
      v_actionable:=v_actionable+1;
    ELSIF v_status='FULLY_COVERED' THEN v_covered:=v_covered+1;
    ELSIF v_status IN('OPEN_REQUEST_WAREHOUSE_AMBIGUOUS','PRODUCT_INACTIVE',
      'SOURCE_WAREHOUSE_INACTIVE','WAREHOUSE_SETUP_REQUIRED',
      'PRODUCT_UOM_SETUP_REQUIRED','PURCHASE_UOM_QUANTITY_NOT_EXACT') THEN
      v_blocked:=v_blocked+1;
    END IF;
  END LOOP;
  RETURN v_base||jsonb_build_object(
    'generationActive',(v_base->>'mode') IN('AUTO_RO','AUTO_PO'),
    'generationMode',v_base->>'mode',
    'summary',jsonb_build_object('negativeOnHandRows',v_negative,
      'actionableRows',v_actionable,'coveredRows',v_covered,'blockedRows',v_blocked),
    'candidates',v_candidates);
END
$$;

CREATE OR REPLACE FUNCTION private.get_purchase_daily_auto_ro_candidates_core(
  p_company_id uuid,p_business_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  RETURN private.get_purchase_daily_automatic_candidates_core(
    p_company_id,p_business_date);
END
$$;

CREATE OR REPLACE FUNCTION public.get_purchase_daily_replenishment_preview()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_date date;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  SELECT (clock_timestamp() AT TIME ZONE company.timezone)::date INTO v_date
  FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_date IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  RETURN private.get_purchase_daily_auto_ro_candidates_core(v_company,v_date);
END
$$;

CREATE FUNCTION private.generate_purchase_daily_auto_po_core(
  p_company_id uuid,p_business_date date,p_actor_id uuid,p_operation_id uuid,
  p_effective_at timestamptz
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_setting public.company_purchase_replenishment_settings%rowtype;
  v_timezone text;v_local_date date;v_local_time time;v_cutoff timestamptz;
  v_existing public.purchase_daily_batch_operations%rowtype;
  v_batch public.purchase_daily_batches%rowtype;v_batch_id uuid;v_batch_no text;
  v_preview jsonb;v_candidate jsonb;v_hash text;v_result jsonb;v_after jsonb;
  v_line_no integer:=0;v_total numeric(24,6):=0;v_ready_count integer:=0;
  v_blocked_count integer:=0;v_order_count integer:=0;v_order uuid;v_order_line uuid;
  v_order_no text;v_group record;v_row record;v_order_line_no integer;
  v_order_total numeric(24,4);v_order_base numeric(24,6);v_order_lines integer;
  v_uom_id uuid;v_uom_name text;v_factor numeric;v_price numeric;
  v_supplier_product_code text;v_status text;v_before jsonb;
  v_allow_decimal boolean;v_decimal_precision integer;v_ordered_qty numeric;
BEGIN
  IF p_company_id IS NULL OR p_business_date IS NULL OR p_actor_id IS NULL
    OR p_operation_id IS NULL OR p_effective_at IS NULL THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_PO_CONTEXT_REQUIRED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.profiles profile WHERE profile.id=p_actor_id) THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_PO_ACTOR_NOT_FOUND';
  END IF;
  v_hash:=md5(jsonb_build_object('companyId',p_company_id,
    'businessDate',p_business_date,'operation','GENERATE_AUTO_PO')::text);
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.company_id=p_company_id AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.operation_type<>'GENERATE_AUTO_PO' OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::text||':PURCHASE_DAILY_REPLENISHMENT',0));
  SELECT * INTO v_existing FROM public.purchase_daily_batch_operations operation
  WHERE operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.company_id<>p_company_id
      OR v_existing.operation_type<>'GENERATE_AUTO_PO'
      OR v_existing.request_hash<>v_hash THEN
      RAISE EXCEPTION 'IDEMPOTENCY_KEY_CONFLICT';
    END IF;
    RETURN v_existing.result_snapshot||jsonb_build_object('exactRetry',true);
  END IF;
  SELECT setting.* INTO v_setting
  FROM public.company_purchase_replenishment_settings setting
  WHERE setting.company_id=p_company_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND'; END IF;
  SELECT company.timezone INTO v_timezone FROM public.companies company
  WHERE company.id=p_company_id AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF v_setting.replenishment_mode<>'AUTO_PO' THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_PO_MODE_REQUIRED';
  END IF;
  v_local_date:=(p_effective_at AT TIME ZONE v_timezone)::date;
  v_local_time:=(p_effective_at AT TIME ZONE v_timezone)::time;
  IF p_business_date<>v_local_date THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_PO_BUSINESS_DATE_INVALID';
  END IF;
  IF v_local_time<v_setting.cutoff_local_time THEN
    RAISE EXCEPTION 'PURCHASE_AUTO_PO_CUTOFF_NOT_REACHED';
  END IF;
  v_cutoff:=(p_business_date+v_setting.cutoff_local_time) AT TIME ZONE v_timezone;

  SELECT * INTO v_batch FROM public.purchase_daily_batches batch
  WHERE batch.company_id=p_company_id AND batch.business_date=p_business_date FOR UPDATE;
  IF FOUND THEN
    IF v_batch.mode_snapshot<>'AUTO_PO' THEN
      RAISE EXCEPTION 'PURCHASE_DAILY_BATCH_MODE_CONFLICT';
    END IF;
    v_result:=jsonb_build_object('batchId',v_batch.id,'batchNo',v_batch.batch_no,
      'status',v_batch.status,'created',false,'existingBatch',true,
      'readyLineCount',(SELECT count(*) FROM public.purchase_daily_batch_lines line
        WHERE line.company_id=p_company_id AND line.batch_id=v_batch.id
          AND line.readiness_status='ORDERED'),
      'blockedLineCount',(SELECT count(*) FROM public.purchase_daily_batch_lines line
        WHERE line.company_id=p_company_id AND line.batch_id=v_batch.id
          AND line.readiness_status<>'ORDERED'),
      'supplierOrderCount',(SELECT count(*) FROM public.supplier_order_documents document
        WHERE document.company_id=p_company_id
          AND document.purchase_daily_batch_id=v_batch.id),
      'exactRetry',false);
    INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
      operation_type,request_hash,result_snapshot,actor_id)
    VALUES(p_operation_id,p_company_id,v_batch.id,'GENERATE_AUTO_PO',v_hash,v_result,p_actor_id);
    v_after:=private.purchase_daily_batch_snapshot(p_company_id,v_batch.id);
    INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,
      action,actor_id,before_state,after_state)
    VALUES(p_company_id,v_batch.id,p_operation_id,'AUTO_PO_REUSE',p_actor_id,v_after,v_after);
    RETURN v_result;
  END IF;

  PERFORM 1 FROM public.product_stocks stock
  WHERE stock.company_id=p_company_id AND stock.stock_qty<0
  ORDER BY stock.product_id,stock.warehouse_id FOR UPDATE;
  v_preview:=private.get_purchase_daily_automatic_candidates_core(
    p_company_id,p_business_date);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v_preview->'candidates') item
      WHERE (item->>'requestedBaseQty')::numeric>0
        AND item->>'status'<>'FULLY_COVERED') THEN
    v_result:=jsonb_build_object('batchId',NULL,'batchNo',NULL,'status',NULL,
      'created',false,'existingBatch',false,'noDemand',true,
      'readyLineCount',0,'blockedLineCount',0,'supplierOrderCount',0,
      'exactRetry',false);
    INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
      operation_type,request_hash,result_snapshot,actor_id)
    VALUES(p_operation_id,p_company_id,NULL,'GENERATE_AUTO_PO',v_hash,v_result,p_actor_id);
    RETURN v_result;
  END IF;

  v_batch_no:='POB-'||to_char(p_business_date,'YYYYMMDD')||'-'||
    lpad(nextval('private.purchase_daily_batch_no_seq')::text,10,'0');
  INSERT INTO public.purchase_daily_batches(company_id,batch_no,business_date,
    mode_snapshot,status,cutoff_at,generated_by)
  VALUES(p_company_id,v_batch_no,p_business_date,'AUTO_PO','DRAFT',v_cutoff,p_actor_id)
  RETURNING id INTO v_batch_id;

  FOR v_candidate IN SELECT item FROM jsonb_array_elements(v_preview->'candidates') item
    WHERE (item->>'requestedBaseQty')::numeric>0 AND item->>'status'<>'FULLY_COVERED'
    ORDER BY item->>'sourceWarehouseName',item->>'productName',item->>'productId'
  LOOP
    IF v_candidate->>'status' IN('READY','SUPPLIER_PENDING')
      AND NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=p_company_id
          AND warehouse.id=NULLIF(v_candidate->>'destinationWarehouseId','')::uuid
          AND warehouse.is_active AND warehouse.is_purchase_destination
          AND warehouse.warehouse_type IS DISTINCT FROM 'TRANSIT') THEN
      v_candidate:=v_candidate||jsonb_build_object('status','WAREHOUSE_SETUP_REQUIRED');
    END IF;
    IF v_candidate->>'status'='READY' THEN
      SELECT uom.allow_decimal,uom.decimal_precision
      INTO v_allow_decimal,v_decimal_precision
      FROM public.uoms uom
      WHERE uom.company_id=p_company_id AND uom.is_active
        AND uom.id=NULLIF(v_candidate->>'suggestedPurchaseUomId','')::uuid;
      v_ordered_qty:=(v_candidate->>'requestedBaseQty')::numeric /
        NULLIF((v_candidate->>'suggestedFactorToBase')::numeric,0);
      IF NOT FOUND OR v_ordered_qty IS NULL
        OR (NOT v_allow_decimal AND v_ordered_qty<>trunc(v_ordered_qty))
        OR (v_allow_decimal AND v_ordered_qty<>round(v_ordered_qty,v_decimal_precision)) THEN
        v_candidate:=v_candidate||jsonb_build_object(
          'status','PURCHASE_UOM_QUANTITY_NOT_EXACT');
      END IF;
    END IF;
    v_line_no:=v_line_no+1;
    INSERT INTO public.purchase_daily_batch_lines(company_id,batch_id,line_no,
      product_id,warehouse_id,base_uom_id,on_hand_snapshot,
      open_purchase_base_qty_snapshot,requested_base_qty,
      suggested_product_supplier_id,suggested_supplier_id,
      supplier_assignment_status,product_sku_snapshot,product_name_snapshot,
      warehouse_code_snapshot,warehouse_name_snapshot,base_uom_name_snapshot,
      destination_warehouse_id,requires_transfer,
      destination_warehouse_code_snapshot,destination_warehouse_name_snapshot,
      readiness_status)
    VALUES(p_company_id,v_batch_id,v_line_no,(v_candidate->>'productId')::uuid,
      (v_candidate->>'sourceWarehouseId')::uuid,(v_candidate->>'baseUomId')::uuid,
      (v_candidate->>'onHandBaseQty')::numeric,
      (v_candidate->>'openPurchaseBaseQty')::numeric,
      (v_candidate->>'requestedBaseQty')::numeric,
      NULLIF(v_candidate->>'suggestedProductSupplierId','')::uuid,
      NULLIF(v_candidate->>'suggestedSupplierId','')::uuid,
      v_candidate->>'supplierAssignmentStatus',v_candidate->>'productSku',
      v_candidate->>'productName',v_candidate->>'sourceWarehouseCode',
      v_candidate->>'sourceWarehouseName',v_candidate->>'baseUomName',
      NULLIF(v_candidate->>'destinationWarehouseId','')::uuid,
      COALESCE((v_candidate->>'requiresTransfer')::boolean,false),
      NULLIF(v_candidate->>'destinationWarehouseCode',''),
      NULLIF(v_candidate->>'destinationWarehouseName',''),v_candidate->>'status');
    v_total:=v_total+(v_candidate->>'requestedBaseQty')::numeric;
  END LOOP;
  SELECT private.purchase_daily_batch_snapshot(p_company_id,v_batch_id) INTO v_before;

  FOR v_group IN SELECT line.suggested_supplier_id supplier_id
    FROM public.purchase_daily_batch_lines line
    WHERE line.company_id=p_company_id AND line.batch_id=v_batch_id
      AND line.readiness_status IN('READY','SUPPLIER_PENDING')
      AND line.destination_warehouse_id IS NOT NULL
    GROUP BY line.suggested_supplier_id ORDER BY line.suggested_supplier_id NULLS LAST
  LOOP
    v_order_no:='PO-'||to_char(p_business_date,'YYYYMMDD')||'-'||
      lpad(nextval('private.supplier_order_document_no_seq')::text,10,'0');
    INSERT INTO public.supplier_order_documents(company_id,order_no,store_id,
      destination_warehouse_id,supplier_id,order_date,expected_date,ordered_by,
      status,notes,order_source,document_scope,purchase_daily_batch_id,
      supplier_assignment_status)
    VALUES(p_company_id,v_order_no,NULL,NULL,v_group.supplier_id,p_business_date,NULL,
      p_actor_id,'DRAFT','AUTO_PO dari '||v_batch_no,'DAILY_REPLENISHMENT',
      'COMPANY_MULTI_WAREHOUSE',v_batch_id,
      CASE WHEN v_group.supplier_id IS NULL THEN 'SUPPLIER_PENDING' ELSE 'ASSIGNED' END)
    RETURNING id INTO v_order;
    INSERT INTO public.supplier_order_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    SELECT p_company_id,v_order,'CREATE',p_actor_id,NULL,to_jsonb(document)
    FROM public.supplier_order_documents document
    WHERE document.company_id=p_company_id AND document.id=v_order;

    v_order_line_no:=0;v_order_total:=0;v_order_base:=0;v_order_lines:=0;
    FOR v_row IN SELECT line.* FROM public.purchase_daily_batch_lines line
      WHERE line.company_id=p_company_id AND line.batch_id=v_batch_id
        AND line.readiness_status IN('READY','SUPPLIER_PENDING')
        AND line.destination_warehouse_id IS NOT NULL
        AND line.suggested_supplier_id IS NOT DISTINCT FROM v_group.supplier_id
      ORDER BY line.product_name_snapshot,line.id
    LOOP
      IF v_group.supplier_id IS NULL THEN
        v_uom_id:=v_row.base_uom_id;v_uom_name:=v_row.base_uom_name_snapshot;
        v_factor:=1;v_price:=0;v_supplier_product_code:=NULL;
      ELSE
        SELECT relation.purchase_uom_id,uom.name,product_uom.factor_to_base,
          COALESCE(relation.last_purchase_price,relation.reference_purchase_price,
            product_uom.purchase_price,0),relation.supplier_product_code
        INTO v_uom_id,v_uom_name,v_factor,v_price,v_supplier_product_code
        FROM public.product_suppliers relation
        JOIN public.suppliers supplier ON supplier.company_id=relation.company_id
          AND supplier.id=relation.supplier_id AND supplier.is_active
        JOIN public.product_uoms product_uom ON product_uom.company_id=relation.company_id
          AND product_uom.product_id=relation.product_id
          AND product_uom.uom_id=relation.purchase_uom_id
          AND product_uom.is_active AND product_uom.purchase_allowed
        JOIN public.uoms uom ON uom.company_id=product_uom.company_id
          AND uom.id=product_uom.uom_id AND uom.is_active
        WHERE relation.company_id=p_company_id
          AND relation.id=v_row.suggested_product_supplier_id
          AND relation.product_id=v_row.product_id
          AND relation.supplier_id=v_group.supplier_id AND relation.is_active;
        IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_PRODUCT_SUPPLIER_NOT_FOUND'; END IF;
      END IF;
      IF v_factor IS NULL OR v_factor<=0
        OR mod(v_row.requested_base_qty,v_factor)<>0 THEN
        RAISE EXCEPTION 'PURCHASE_AUTO_PO_QUANTITY_UOM_NOT_EXACT';
      END IF;
      v_order_line_no:=v_order_line_no+1;v_order_lines:=v_order_lines+1;
      v_order_base:=v_order_base+v_row.requested_base_qty;
      v_order_total:=v_order_total+round((v_row.requested_base_qty/v_factor)*v_price,4);
      INSERT INTO public.supplier_order_lines(company_id,document_id,line_no,
        client_line_key,product_id,ordered_uom_id,ordered_qty,factor_to_base_snapshot,
        ordered_base_qty,estimated_unit_price,estimated_subtotal,
        product_sku_snapshot,product_name_snapshot,ordered_uom_name_snapshot,
        supplier_product_code_snapshot,source_warehouse_id,destination_warehouse_id)
      VALUES(p_company_id,v_order,v_order_line_no,gen_random_uuid(),v_row.product_id,
        v_uom_id,v_row.requested_base_qty/v_factor,v_factor,v_row.requested_base_qty,
        v_price,round((v_row.requested_base_qty/v_factor)*v_price,4),
        v_row.product_sku_snapshot,v_row.product_name_snapshot,v_uom_name,
        v_supplier_product_code,v_row.warehouse_id,v_row.destination_warehouse_id)
      RETURNING id INTO v_order_line;
      INSERT INTO public.purchase_daily_batch_order_allocations(company_id,batch_id,
        batch_line_id,supplier_order_id,supplier_order_line_id,allocated_base_qty,created_by)
      VALUES(p_company_id,v_batch_id,v_row.id,v_order,v_order_line,
        v_row.requested_base_qty,p_actor_id);
      UPDATE public.purchase_daily_batch_lines SET readiness_status='ORDERED',
        master_version=master_version+1
      WHERE company_id=p_company_id AND id=v_row.id;
    END LOOP;
    UPDATE public.supplier_order_documents SET line_count=v_order_lines,
      total_ordered_base_qty=v_order_base,estimated_total=v_order_total,
      status='CONFIRMED',confirmed_by=p_actor_id,confirmed_at=p_effective_at,
      confirmation_idempotency_key=md5(p_operation_id::text||':'||
        COALESCE(v_group.supplier_id::text,'SUPPLIER_PENDING'))::uuid,
      master_version=master_version+1,updated_at=p_effective_at
    WHERE company_id=p_company_id AND id=v_order;
    INSERT INTO public.supplier_order_audit(company_id,document_id,action,actor_id,
      before_state,after_state)
    SELECT p_company_id,v_order,'CONFIRM',p_actor_id,NULL,to_jsonb(document)
    FROM public.supplier_order_documents document
    WHERE document.company_id=p_company_id AND document.id=v_order;
    v_order_count:=v_order_count+1;
  END LOOP;

  SELECT count(*) FILTER(WHERE readiness_status='ORDERED'),
    count(*) FILTER(WHERE readiness_status<>'ORDERED')
  INTO v_ready_count,v_blocked_count FROM public.purchase_daily_batch_lines line
  WHERE line.company_id=p_company_id AND line.batch_id=v_batch_id;
  v_status:=CASE WHEN v_blocked_count=0 THEN 'READY' ELSE 'DRAFT' END;
  v_result:=jsonb_build_object('batchId',v_batch_id,'batchNo',v_batch_no,
    'status',v_status,'created',true,'existingBatch',false,'noDemand',false,
    'readyLineCount',v_ready_count,'blockedLineCount',v_blocked_count,
    'supplierOrderCount',v_order_count,'partialHold',v_blocked_count>0,
    'requestedTotalBaseQty',v_total,'exactRetry',false);
  INSERT INTO public.purchase_daily_batch_operations(id,company_id,batch_id,
    operation_type,request_hash,result_snapshot,actor_id)
  VALUES(p_operation_id,p_company_id,v_batch_id,'GENERATE_AUTO_PO',v_hash,v_result,p_actor_id);
  UPDATE public.purchase_daily_batches SET status=v_status,
    generation_operation_id=p_operation_id,line_count=v_line_no,
    requested_total_base_qty=v_total,
    confirmed_by=CASE WHEN v_status='READY' THEN p_actor_id ELSE NULL END,
    confirmed_at=CASE WHEN v_status='READY' THEN p_effective_at ELSE NULL END,
    confirmation_operation_id=CASE WHEN v_status='READY' THEN p_operation_id ELSE NULL END,
    master_version=master_version+CASE WHEN v_status='READY' THEN 1 ELSE 0 END,
    updated_at=p_effective_at WHERE company_id=p_company_id AND id=v_batch_id;
  v_after:=private.purchase_daily_batch_snapshot(p_company_id,v_batch_id);
  INSERT INTO public.purchase_daily_batch_audit(company_id,batch_id,operation_id,
    action,actor_id,before_state,after_state)
  VALUES(p_company_id,v_batch_id,p_operation_id,'AUTO_PO_GENERATE',p_actor_id,v_before,v_after);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.generate_purchase_daily_auto_po(
  p_business_date date,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','POST');
  RETURN private.generate_purchase_daily_auto_po_core(v_company,p_business_date,
    v_actor,p_operation_id,clock_timestamp());
END
$$;

REVOKE ALL ON FUNCTION private.get_purchase_daily_automatic_candidates_core(uuid,date),
  private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.get_purchase_daily_automatic_candidates_core(uuid,date),
  private.generate_purchase_daily_auto_po_core(uuid,date,uuid,uuid,timestamptz)
TO service_role;
REVOKE ALL ON FUNCTION public.generate_purchase_daily_auto_po(date,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.generate_purchase_daily_auto_po(date,uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260913130000','purchase_daily_auto_po_runtime',
  'Purchase Step 4/6: atomic AUTO_PO generation processes ready lines into confirmed Supplier Orders after cutoff while blocked lines remain held in the daily batch; no Receipt, Stock, FIFO, AP or Finance effect');
NOTIFY pgrst,'reload schema';
COMMIT;
