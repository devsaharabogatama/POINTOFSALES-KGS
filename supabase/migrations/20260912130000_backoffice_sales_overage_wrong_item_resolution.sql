-- Step 4/6.5C3: atomic Warehouse resolution for Overage and Wrong Item.
-- SQL is rolled out manually to the isolated Development project only.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912125000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted-overage Invoice client required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912130000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912130000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)') IS NOT NULL
    OR to_regprocedure('public.resolve_backoffice_sales_overage_wrong_item(uuid,bigint,uuid,date,text)') IS NOT NULL
    OR to_regprocedure('private.record_backoffice_sales_discrepancy_transfer_effect(uuid,uuid,uuid,text,uuid)') IS NOT NULL
    OR to_regprocedure('private.post_backoffice_sales_exact_return_transfer(uuid,bigint,uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: C3 routine collision';
  END IF;
  IF to_regprocedure('private.post_backoffice_sales_discrepancy_transfer(uuid,bigint,uuid,uuid)') IS NULL
    OR to_regprocedure('private.save_stock_transfer_document(uuid,bigint,uuid,uuid,date,text,jsonb)') IS NULL
    OR to_regprocedure('private.post_stock_transfer(uuid,bigint,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Stock transfer dependency missing';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid='public.backoffice_sales_discrepancy_backorders'::regclass
      AND constraint_row.conname='backoffice_sales_discrepancy_backorders_case_unique') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: discrepancy child lineage constraint drift';
  END IF;
END
$guard$;

-- A mixed case can legitimately create one shortage Backorder and one Wrong
-- Item correction DO. Each source line remains unique in the child-line table.
ALTER TABLE public.backoffice_sales_discrepancy_backorders
  DROP CONSTRAINT backoffice_sales_discrepancy_backorders_case_unique;
ALTER TABLE public.backoffice_sales_discrepancy_backorders
  ADD COLUMN resolution_kind text NOT NULL DEFAULT 'SHORT_BACKORDER',
  ADD CONSTRAINT bo_sales_discrepancy_backorders_kind_check
    CHECK(resolution_kind IN('SHORT_BACKORDER','WRONG_ITEM_CORRECTION')),
  ADD CONSTRAINT bo_sales_discrepancy_backorders_case_kind_unique
    UNIQUE(company_id,discrepancy_id,resolution_kind);

CREATE FUNCTION private.record_backoffice_sales_discrepancy_transfer_effect(
  p_discrepancy_id uuid,p_discrepancy_line_id uuid,p_operation_id uuid,
  p_effect_type text,p_transfer_document_id uuid
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_effect uuid:=gen_random_uuid();v_transfer public.stock_transfer_documents%rowtype;
  v_line public.stock_transfer_lines%rowtype;v_source_movement uuid;
  v_destination_movement uuid;
BEGIN
  SELECT * INTO STRICT v_transfer FROM public.stock_transfer_documents document
  WHERE document.company_id=v_company AND document.id=p_transfer_document_id
    AND document.status='POSTED';
  SELECT * INTO STRICT v_line FROM public.stock_transfer_lines line
  WHERE line.company_id=v_company AND line.document_id=v_transfer.id;
  IF (SELECT count(*) FROM public.stock_transfer_lines line
      WHERE line.company_id=v_company AND line.document_id=v_transfer.id)<>1 THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSFER_LINE_INVALID';
  END IF;
  SELECT movement.id INTO STRICT v_source_movement FROM public.stock_movements movement
  WHERE movement.company_id=v_company AND movement.reference_table='stock_transfer_documents'
    AND movement.reference_id=v_transfer.id AND movement.source_line_id=v_line.id
    AND movement.movement_type='TRANSFER_OUT'::public.stock_movement_type;
  SELECT movement.id INTO STRICT v_destination_movement FROM public.stock_movements movement
  WHERE movement.company_id=v_company AND movement.reference_table='stock_transfer_documents'
    AND movement.reference_id=v_transfer.id AND movement.source_line_id=v_line.id
    AND movement.movement_type='TRANSFER_IN'::public.stock_movement_type;
  INSERT INTO public.backoffice_sales_discrepancy_stock_effects(id,company_id,
    discrepancy_id,discrepancy_line_id,operation_id,effect_type,product_id,
    source_warehouse_id,destination_warehouse_id,quantity_base,total_cost,
    source_stock_movement_id,destination_stock_movement_id,
    stock_transfer_document_id,created_by)
  VALUES(v_effect,v_company,p_discrepancy_id,p_discrepancy_line_id,p_operation_id,
    p_effect_type,v_line.product_id,v_transfer.source_warehouse_id,
    v_transfer.destination_warehouse_id,v_line.quantity_base,v_line.transferred_cost,
    v_source_movement,v_destination_movement,v_transfer.id,v_actor);
  INSERT INTO public.backoffice_sales_discrepancy_fifo_allocations(company_id,
    stock_effect_id,source_batch_id,destination_batch_id,quantity_base,unit_cost,total_cost)
  SELECT v_company,v_effect,allocation.source_batch_id,allocation.destination_batch_id,
    allocation.quantity_base,allocation.unit_cost_base,allocation.total_cost
  FROM public.stock_transfer_fifo_allocations allocation
  WHERE allocation.company_id=v_company AND allocation.document_id=v_transfer.id
    AND allocation.line_id=v_line.id;
  RETURN v_effect;
END
$$;

-- Post a one-line Transit return by consuming only destination batches created
-- by the stated source transfer. This prevents same-Product stock of another DO
-- from being consumed merely because it is older in the shared Transit.
CREATE FUNCTION private.post_backoffice_sales_exact_return_transfer(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid,
  p_source_transfer_document_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_document public.stock_transfer_documents%rowtype;v_line public.stock_transfer_lines%rowtype;
  v_batch record;v_before jsonb;v_after jsonb;v_category uuid;v_result_version bigint;
  v_source_before numeric(24,6);v_destination_before numeric(24,6);
  v_remaining numeric(24,6);v_take numeric(24,6);v_total_cost numeric(24,4):=0;
  v_layers integer:=0;v_destination_batch uuid;v_posted_at timestamptz:=clock_timestamp();
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL OR p_source_transfer_document_id IS NULL THEN
    RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED';
  END IF;
  SELECT * INTO v_document FROM public.stock_transfer_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_TRANSFER_NOT_FOUND'; END IF;
  IF v_document.status='POSTED' THEN
    IF v_document.posting_idempotency_key=p_idempotency_key THEN
      RETURN jsonb_build_object('documentId',v_document.id,'documentNo',v_document.document_no,
        'status','POSTED','masterVersion',v_document.master_version,
        'lineCount',v_document.line_count,'totalQuantityBase',v_document.total_quantity_base,
        'totalCost',v_document.total_cost,'idempotentReplay',true);
    END IF;
    RAISE EXCEPTION 'STOCK_TRANSFER_ALREADY_POSTED';
  END IF;
  IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'CANCELED_STOCK_TRANSFER_IMMUTABLE'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  SELECT * INTO STRICT v_line FROM public.stock_transfer_lines line
  WHERE line.company_id=v_company AND line.document_id=v_document.id;
  IF (SELECT count(*) FROM public.stock_transfer_lines line
      WHERE line.company_id=v_company AND line.document_id=v_document.id)<>1 THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSFER_LINE_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.stock_transfer_documents source
    WHERE source.company_id=v_company AND source.id=p_source_transfer_document_id
      AND source.status='POSTED' AND source.destination_warehouse_id=v_document.source_warehouse_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_EXACT_SOURCE_TRANSFER_INVALID';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':STOCK:'||
    v_line.product_id::text||':'||LEAST(v_document.source_warehouse_id::text,
    v_document.destination_warehouse_id::text),0));
  PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':STOCK:'||
    v_line.product_id::text||':'||GREATEST(v_document.source_warehouse_id::text,
    v_document.destination_warehouse_id::text),0));
  SELECT COALESCE(stock.stock_qty,0) INTO v_source_before FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_line.product_id
    AND stock.warehouse_id=v_document.source_warehouse_id FOR UPDATE;
  SELECT COALESCE(stock.stock_qty,0) INTO v_destination_before FROM public.product_stocks stock
  WHERE stock.company_id=v_company AND stock.product_id=v_line.product_id
    AND stock.warehouse_id=v_document.destination_warehouse_id FOR UPDATE;
  v_source_before:=COALESCE(v_source_before,0);v_destination_before:=COALESCE(v_destination_before,0);
  IF v_source_before<v_line.quantity_base THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSIT_FIFO_INSUFFICIENT';
  END IF;
  v_before:=to_jsonb(v_document);v_remaining:=v_line.quantity_base;
  FOR v_batch IN
    SELECT batch.* FROM public.product_batches batch
    JOIN public.stock_transfer_fifo_allocations allocation
      ON allocation.company_id=batch.company_id AND allocation.destination_batch_id=batch.id
    JOIN public.stock_transfer_lines source_line
      ON source_line.company_id=allocation.company_id AND source_line.id=allocation.line_id
    WHERE batch.company_id=v_company AND batch.product_id=v_line.product_id
      AND batch.warehouse_id=v_document.source_warehouse_id
      AND source_line.document_id=p_source_transfer_document_id AND batch.qty_remaining>0
    ORDER BY allocation.id,batch.id FOR UPDATE OF batch
  LOOP
    EXIT WHEN v_remaining<=0;v_take:=LEAST(v_remaining,v_batch.qty_remaining);
    UPDATE public.product_batches SET qty_remaining=qty_remaining-v_take
    WHERE company_id=v_company AND id=v_batch.id;
    INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
      qty_purchased,qty_remaining,cogs_unit,company_id,opening_stock_line_id,
      stock_transfer_line_id,source_batch_id)
    VALUES(v_line.product_id,v_document.destination_warehouse_id,NULL,v_take,v_take,
      v_batch.cogs_unit,v_company,NULL,v_line.id,v_batch.id)
    RETURNING id INTO v_destination_batch;
    INSERT INTO public.stock_transfer_fifo_allocations(company_id,document_id,line_id,
      source_batch_id,destination_batch_id,quantity_base,unit_cost_base,total_cost)
    VALUES(v_company,v_document.id,v_line.id,v_batch.id,v_destination_batch,v_take,
      v_batch.cogs_unit,round(v_take*v_batch.cogs_unit,4));
    v_total_cost:=v_total_cost+round(v_take*v_batch.cogs_unit,4);
    v_layers:=v_layers+1;v_remaining:=v_remaining-v_take;
  END LOOP;
  IF v_remaining<>0 THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_EXACT_TRANSIT_FIFO_INSUFFICIENT'; END IF;
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_line.product_id,v_document.source_warehouse_id,
    v_source_before-v_line.quantity_base,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=excluded.stock_qty,updated_at=clock_timestamp();
  INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
  VALUES(v_line.product_id,v_document.destination_warehouse_id,v_line.quantity_base,v_company)
  ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
    stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,updated_at=clock_timestamp();
  INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,movement_type,
    reference_table,reference_id,company_id,base_uom_id,base_uom_name_snapshot,
    balance_after_base_qty,actor_id,posted_at,movement_status,source_line_id,notes)
  VALUES
    (v_line.product_id,v_document.source_warehouse_id,-v_line.quantity_base,
      'TRANSFER_OUT'::public.stock_movement_type,'stock_transfer_documents',v_document.id,
      v_company,v_line.base_uom_id,v_line.base_uom_name_snapshot,
      v_source_before-v_line.quantity_base,v_actor,v_posted_at,'POSTED',v_line.id,v_line.notes),
    (v_line.product_id,v_document.destination_warehouse_id,v_line.quantity_base,
      'TRANSFER_IN'::public.stock_movement_type,'stock_transfer_documents',v_document.id,
      v_company,v_line.base_uom_id,v_line.base_uom_name_snapshot,
      v_destination_before+v_line.quantity_base,v_actor,v_posted_at,'POSTED',v_line.id,v_line.notes);
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='STOCK_TRANSFER'
    AND category.is_active AND category.is_system_default ORDER BY category.id LIMIT 1;
  IF v_category IS NULL THEN RAISE EXCEPTION 'STOCK_TRANSFER_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
  UPDATE public.stock_transfer_lines SET transferred_cost=v_total_cost,fifo_layer_count=v_layers
  WHERE company_id=v_company AND id=v_line.id;
  UPDATE public.stock_transfer_documents SET status='POSTED',
    posting_idempotency_key=p_idempotency_key,transaction_category_id=v_category,
    total_cost=v_total_cost,posted_by=v_actor,posted_at=v_posted_at,
    updated_by=v_actor,updated_at=v_posted_at,master_version=master_version+1
  WHERE company_id=v_company AND id=v_document.id RETURNING master_version INTO v_result_version;
  SELECT to_jsonb(document) INTO v_after FROM public.stock_transfer_documents document
  WHERE document.company_id=v_company AND document.id=v_document.id;
  INSERT INTO public.stock_transfer_audit(company_id,document_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_document.id,'POST',v_actor,v_before,v_after);
  RETURN jsonb_build_object('documentId',v_document.id,'documentNo',v_document.document_no,
    'status','POSTED','masterVersion',v_result_version,'lineCount',v_document.line_count,
    'totalQuantityBase',v_document.total_quantity_base,'totalCost',v_total_cost,
    'idempotentReplay',false);
END
$$;

CREATE FUNCTION private.resolve_backoffice_sales_overage_wrong_item_core(
  p_discrepancy_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_replacement_date date DEFAULT NULL,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_case public.backoffice_sales_delivery_discrepancies%rowtype;
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
  v_order public.backoffice_sales_orders%rowtype;
  v_reservation public.backoffice_sales_reservations%rowtype;
  v_existing public.backoffice_sales_discrepancy_operations%rowtype;
  v_line record;v_batch record;v_transfer jsonb;v_request jsonb;v_result jsonb;
  v_now timestamptz:=clock_timestamp();v_today date;v_timezone text;
  v_transit uuid;v_product uuid;v_qty numeric(24,6);v_remaining numeric(24,6);
  v_take numeric(24,6);v_total_cost numeric(24,4);v_source_stock numeric(24,6);
  v_base_uom uuid;v_base_name text;v_transfer_id uuid;v_transfer_line uuid;
  v_effect uuid;v_movement uuid;v_event uuid;v_category uuid;
  v_reconstruction_effect text;v_return_effect text;v_return_transfer jsonb;
  v_correction_id uuid;v_correction_no text;v_correction_sequence integer;
  v_correction_total numeric(24,6);v_correction_line uuid;v_line_no integer:=0;
  v_resolved_count integer:=0;v_open_count bigint;v_case_status text;
  v_order_fulfillment text;v_before jsonb;
  v_dispatch_transfer uuid;v_accepted_date date;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_discrepancy_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_REQUIRED'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'MASTER_VERSION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF length(COALESCE(p_notes,''))>500 THEN RAISE EXCEPTION 'WAREHOUSE_RESOLUTION_NOTES_TOO_LONG'; END IF;
  v_request:=jsonb_build_object('discrepancyId',p_discrepancy_id,
    'requestedReplacementDate',p_replacement_date,'notes',NULLIF(btrim(p_notes),''));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_OVERAGE_WRONG_ITEM_RESOLUTION:'||p_operation_id::text,0));
  SELECT * INTO v_existing FROM public.backoffice_sales_discrepancy_operations operation
  WHERE operation.company_id=v_company AND operation.id=p_operation_id;
  IF FOUND THEN
    IF v_existing.discrepancy_id<>p_discrepancy_id
      OR v_existing.request_payload IS DISTINCT FROM v_request THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN v_existing.result_payload||jsonb_build_object('exactRetry',true);
  END IF;
  SELECT company.timezone,(v_now AT TIME ZONE company.timezone)::date
  INTO v_timezone,v_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  p_replacement_date:=COALESCE(p_replacement_date,v_today);
  IF p_replacement_date<v_today THEN
    RAISE EXCEPTION 'REPLACEMENT_DATE_BEFORE_COMPANY_TODAY';
  END IF;
  SELECT * INTO v_case FROM public.backoffice_sales_delivery_discrepancies discrepancy
  WHERE discrepancy.company_id=v_company AND discrepancy.id=p_discrepancy_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_NOT_FOUND'; END IF;
  IF v_case.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_case.status<>'PENDING_WAREHOUSE_RESOLUTION' THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_NOT_RESOLVABLE';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
      AND line.discrepancy_type='SHORT' AND line.warehouse_resolution_status='PENDING') THEN
    RAISE EXCEPTION 'BACKOFFICE_SHORTAGE_MUST_RESOLVE_FIRST';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
      AND line.discrepancy_type IN('OVERAGE','WRONG_ITEM')
      AND line.warehouse_resolution_status='PENDING') THEN
    RAISE EXCEPTION 'BACKOFFICE_OVERAGE_WRONG_ITEM_PENDING_LINE_REQUIRED';
  END IF;
  v_before:=to_jsonb(v_case);
  SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.id=v_case.delivery_order_id FOR UPDATE;
  SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=v_case.sales_order_id FOR UPDATE;
  SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id FOR UPDATE;
  SELECT receipt.accepted_date INTO STRICT v_accepted_date
  FROM public.backoffice_sales_delivery_receipts receipt
  WHERE receipt.company_id=v_company AND receipt.id=v_case.receipt_id
    AND receipt.delivery_order_id=v_delivery.id FOR SHARE;
  SELECT dispatch.transit_warehouse_id INTO STRICT v_transit
  FROM public.backoffice_sales_delivery_dispatches dispatch
  WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
  ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1;
  SELECT dispatch.stock_transfer_document_id INTO STRICT v_dispatch_transfer
  FROM public.backoffice_sales_delivery_dispatches dispatch
  WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
  ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1;
  IF v_delivery.status<>'IN_TRANSIT' OR v_order.status<>'CONFIRMED' THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_SOURCE_STATE_INVALID';
  END IF;
  PERFORM 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
  ORDER BY line.id FOR UPDATE;
  INSERT INTO public.backoffice_sales_discrepancy_operations(id,company_id,
    discrepancy_id,operation_type,request_payload,actor_id)
  VALUES(p_operation_id,v_company,v_case.id,'WAREHOUSE_RESOLVE',v_request,v_actor);

  SELECT COALESCE(sum(line.quantity_base),0) INTO v_correction_total
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
    AND line.discrepancy_type='WRONG_ITEM' AND line.requested_resolution='REPLACE_WRONG_ITEM'
    AND line.warehouse_resolution_status='PENDING';
  IF v_correction_total>0 THEN
    v_correction_id:=gen_random_uuid();
    SELECT COALESCE(max(delivery.sequence_no),0)+1 INTO v_correction_sequence
    FROM public.backoffice_sales_delivery_orders delivery
    WHERE delivery.company_id=v_company AND delivery.sales_order_id=v_case.sales_order_id;
    v_correction_no:=private.next_sales_delivery_no(v_company,v_now);
    INSERT INTO public.backoffice_sales_delivery_orders(id,company_id,sales_order_id,
      reservation_id,delivery_no,sequence_no,delivery_kind,parent_delivery_order_id,
      status,scheduled_date,recipient_snapshot,notes,total_planned_base_qty,
      created_by,updated_by)
    VALUES(v_correction_id,v_company,v_case.sales_order_id,v_delivery.reservation_id,
      v_correction_no,v_correction_sequence,'CORRECTION',v_delivery.id,'READY',
      p_replacement_date,v_delivery.recipient_snapshot,NULLIF(btrim(p_notes),''),
      v_correction_total,v_actor,v_actor);
    INSERT INTO public.backoffice_sales_discrepancy_backorders(company_id,
      discrepancy_id,source_delivery_order_id,backorder_delivery_order_id,
      operation_id,created_by,resolution_kind)
    VALUES(v_company,v_case.id,v_delivery.id,v_correction_id,p_operation_id,v_actor,
      'WRONG_ITEM_CORRECTION');
  END IF;

  FOR v_line IN
    SELECT line.*,delivery_line.reservation_line_id,delivery_line.base_qty_per_uom,
      delivery_line.product_code_snapshot,delivery_line.product_name_snapshot,
      delivery_line.uom_code_snapshot,delivery_line.uom_name_snapshot
    FROM public.backoffice_sales_delivery_discrepancy_lines line
    JOIN public.backoffice_sales_delivery_order_lines delivery_line
      ON delivery_line.company_id=line.company_id AND delivery_line.id=line.delivery_order_line_id
    WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
      AND line.discrepancy_type IN('OVERAGE','WRONG_ITEM')
      AND line.warehouse_resolution_status='PENDING'
    ORDER BY line.id
  LOOP
    IF v_line.discrepancy_type='OVERAGE' THEN
      v_product:=v_line.expected_product_id;v_qty:=v_line.quantity_base;
      v_reconstruction_effect:='OVERAGE_TO_TRANSIT';
    ELSE
      IF v_line.requested_resolution<>'REPLACE_WRONG_ITEM'
        OR v_line.actual_product_id IS NULL OR v_line.actual_quantity_base<=0 THEN
        RAISE EXCEPTION 'BACKOFFICE_WRONG_ITEM_LINE_CONTRACT_INVALID';
      END IF;
      v_product:=v_line.actual_product_id;v_qty:=v_line.actual_quantity_base;
      v_reconstruction_effect:='ACTUAL_TO_TRANSIT';
    END IF;
    IF v_line.requested_resolution='ACCEPT_OVERAGE'
      AND v_line.commercial_approval_status<>'APPROVED' THEN
      RAISE EXCEPTION 'BACKOFFICE_OVERAGE_COMMERCIAL_APPROVAL_REQUIRED';
    END IF;
    v_transfer:=private.save_stock_transfer_document(NULL,NULL,
      v_reservation.warehouse_id,v_transit,v_today,
      'Reconstruction '||v_case.discrepancy_no||' - '||v_line.discrepancy_type,
      jsonb_build_array(jsonb_build_object('productId',v_product,
        'quantityBase',v_qty,'notes',NULLIF(btrim(p_notes),''))));
    v_transfer_id:=(v_transfer->>'documentId')::uuid;
    v_transfer:=private.post_backoffice_sales_discrepancy_transfer(v_transfer_id,
      (v_transfer->>'masterVersion')::bigint,gen_random_uuid(),v_line.id);
    PERFORM private.record_backoffice_sales_discrepancy_transfer_effect(v_case.id,
      v_line.id,p_operation_id,v_reconstruction_effect,v_transfer_id);

    IF v_line.requested_resolution='ACCEPT_OVERAGE' THEN
      SELECT product.uom_id,uom.name INTO STRICT v_base_uom,v_base_name
      FROM public.products product JOIN public.uoms uom
        ON uom.company_id=product.company_id AND uom.id=product.uom_id
      WHERE product.company_id=v_company AND product.id=v_product;
      SELECT stock.stock_qty INTO v_source_stock FROM public.product_stocks stock
      WHERE stock.company_id=v_company AND stock.product_id=v_product
        AND stock.warehouse_id=v_transit FOR UPDATE;
      IF COALESCE(v_source_stock,0)<v_qty THEN
        RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSIT_FIFO_INSUFFICIENT';
      END IF;
      v_remaining:=v_qty;v_total_cost:=0;v_effect:=gen_random_uuid();
      v_movement:=gen_random_uuid();v_event:=gen_random_uuid();
      FOR v_batch IN
        SELECT batch.* FROM public.product_batches batch
        JOIN public.stock_transfer_fifo_allocations allocation
          ON allocation.company_id=batch.company_id
         AND allocation.destination_batch_id=batch.id
        JOIN public.stock_transfer_lines transfer_line
          ON transfer_line.company_id=allocation.company_id
         AND transfer_line.id=allocation.line_id
        WHERE batch.company_id=v_company AND transfer_line.document_id=v_transfer_id
          AND batch.qty_remaining>0 ORDER BY batch.created_at,batch.id FOR UPDATE OF batch
      LOOP
        EXIT WHEN v_remaining<=0;v_take:=LEAST(v_remaining,v_batch.qty_remaining);
        v_total_cost:=v_total_cost+round(v_take*v_batch.cogs_unit,4);
        v_remaining:=v_remaining-v_take;
      END LOOP;
      IF v_remaining<>0 THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSIT_FIFO_INSUFFICIENT'; END IF;
      SELECT category.id INTO v_category FROM public.transaction_categories category
      WHERE category.company_id=v_company AND category.system_key='SALE_POSTED'
        AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
      IF v_category IS NULL THEN RAISE EXCEPTION 'SALE_POSTED_TRANSACTION_CATEGORY_REQUIRED'; END IF;
      INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
        event_date,event_version,idempotency_key,amounts,status,error_message,created_by,
        company_id,store_id,system_event_key,transaction_category_id)
      VALUES(v_event,'BO-OVERAGE-COGS-'||upper(replace(v_effect::text,'-','')),
        'SALE_POSTED'::public.event_type,'backoffice_sales_discrepancy_stock_effects',
        v_effect,v_now,1,'BACKOFFICE_ACCEPTED_OVERAGE_COGS|'||v_company||'|'||v_line.id,
        jsonb_build_object('fifoCostTotal',v_total_cost,'acceptedDate',v_accepted_date,
          'salesOrderId',v_case.sales_order_id,'deliveryOrderId',v_delivery.id,
          'discrepancyId',v_case.id,'discrepancyLineId',v_line.id,
          'financePostingState','HOLD_FOR_ACCEPTED_OVERAGE_COGS'),
        'HOLD'::public.event_status,'BACKOFFICE_ACCEPTED_OVERAGE_COGS_REVIEW_REQUIRED',
        v_actor,v_company,v_order.store_id,'BACKOFFICE_ACCEPTED_OVERAGE_COGS',v_category);
      UPDATE public.product_stocks SET stock_qty=stock_qty-v_qty,updated_at=v_now
      WHERE company_id=v_company AND product_id=v_product AND warehouse_id=v_transit;
      INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
        movement_type,reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes)
      VALUES(v_movement,v_product,v_transit,-v_qty,
        'BACKOFFICE_SALE'::public.stock_movement_type,
        'backoffice_sales_discrepancy_stock_effects',v_effect,v_company,v_base_uom,
        v_base_name,v_source_stock-v_qty,v_actor,v_now,'POSTED',v_line.id,
        COALESCE(NULLIF(btrim(p_notes),''),'Accepted overage'));
      INSERT INTO public.backoffice_sales_discrepancy_stock_effects(id,company_id,
        discrepancy_id,discrepancy_line_id,operation_id,effect_type,product_id,
        source_warehouse_id,quantity_base,total_cost,source_stock_movement_id,
        financial_event_id,created_by)
      VALUES(v_effect,v_company,v_case.id,v_line.id,p_operation_id,'OVERAGE_ACCEPTED_SALE',
        v_product,v_transit,v_qty,v_total_cost,v_movement,v_event,v_actor);
      v_remaining:=v_qty;
      FOR v_batch IN
        SELECT batch.* FROM public.product_batches batch
        JOIN public.stock_transfer_fifo_allocations allocation
          ON allocation.company_id=batch.company_id
         AND allocation.destination_batch_id=batch.id
        JOIN public.stock_transfer_lines transfer_line
          ON transfer_line.company_id=allocation.company_id
         AND transfer_line.id=allocation.line_id
        WHERE batch.company_id=v_company AND transfer_line.document_id=v_transfer_id
          AND batch.qty_remaining>0 ORDER BY batch.created_at,batch.id FOR UPDATE OF batch
      LOOP
        EXIT WHEN v_remaining<=0;v_take:=LEAST(v_remaining,v_batch.qty_remaining);
        UPDATE public.product_batches SET qty_remaining=qty_remaining-v_take
        WHERE company_id=v_company AND id=v_batch.id;
        INSERT INTO public.backoffice_sales_discrepancy_fifo_allocations(company_id,
          stock_effect_id,source_batch_id,quantity_base,unit_cost,total_cost)
        VALUES(v_company,v_effect,v_batch.id,v_take,v_batch.cogs_unit,
          round(v_take*v_batch.cogs_unit,4));
        v_remaining:=v_remaining-v_take;
      END LOOP;
      UPDATE public.backoffice_sales_order_lines SET
        approved_overage_base_qty=approved_overage_base_qty+v_qty,
        accepted_base_qty=accepted_base_qty+v_qty,updated_at=v_now
      WHERE company_id=v_company AND id=v_line.sales_order_line_id;
      UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
        accepted_overage_base_qty=v_qty,warehouse_resolution_status='RESOLVED',
        updated_at=v_now WHERE company_id=v_company AND id=v_line.id;
    ELSE
      -- Return reconstructed actual/extra goods to the source Warehouse.
      v_return_effect:=CASE WHEN v_line.discrepancy_type='OVERAGE'
        THEN 'OVERAGE_RETURN_TO_SOURCE' ELSE 'ACTUAL_RETURN_TO_SOURCE' END;
      v_return_transfer:=private.save_stock_transfer_document(NULL,NULL,
        v_transit,v_reservation.warehouse_id,v_today,
        'Return '||v_case.discrepancy_no||' - '||v_line.discrepancy_type,
        jsonb_build_array(jsonb_build_object('productId',v_product,
          'quantityBase',v_qty,'notes',NULLIF(btrim(p_notes),''))));
      v_return_transfer:=private.post_backoffice_sales_exact_return_transfer(
        (v_return_transfer->>'documentId')::uuid,
        (v_return_transfer->>'masterVersion')::bigint,gen_random_uuid(),v_transfer_id);
      PERFORM private.record_backoffice_sales_discrepancy_transfer_effect(v_case.id,
        v_line.id,p_operation_id,v_return_effect,
        (v_return_transfer->>'documentId')::uuid);
      IF v_line.discrepancy_type='WRONG_ITEM' THEN
        -- The original dispatch recorded expected Product. Reverse that phantom
        -- Transit quantity before creating the replacement DO/SJ.
        v_return_transfer:=private.save_stock_transfer_document(NULL,NULL,
          v_transit,v_reservation.warehouse_id,v_today,
          'Expected Product correction '||v_case.discrepancy_no,
          jsonb_build_array(jsonb_build_object('productId',v_line.expected_product_id,
            'quantityBase',v_line.quantity_base,'notes',NULLIF(btrim(p_notes),''))));
        v_return_transfer:=private.post_backoffice_sales_exact_return_transfer(
          (v_return_transfer->>'documentId')::uuid,
          (v_return_transfer->>'masterVersion')::bigint,gen_random_uuid(),v_dispatch_transfer);
        PERFORM private.record_backoffice_sales_discrepancy_transfer_effect(v_case.id,
          v_line.id,p_operation_id,'EXPECTED_RETURN_TO_SOURCE',
          (v_return_transfer->>'documentId')::uuid);
        UPDATE public.backoffice_sales_reservation_lines SET
          in_transit_base_qty=in_transit_base_qty-v_line.quantity_base,updated_at=v_now
        WHERE company_id=v_company AND id=v_line.reservation_line_id
          AND in_transit_base_qty>=v_line.quantity_base;
        IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_WRONG_ITEM_RESERVATION_CHANGED'; END IF;
        v_line_no:=v_line_no+1;v_correction_line:=gen_random_uuid();
        INSERT INTO public.backoffice_sales_delivery_order_lines(id,company_id,
          delivery_order_id,sales_order_id,reservation_id,reservation_line_id,
          sales_order_line_id,line_no,product_id,uom_id,product_code_snapshot,
          product_name_snapshot,uom_code_snapshot,uom_name_snapshot,base_qty_per_uom,
          planned_qty_uom,planned_base_qty)
        VALUES(v_correction_line,v_company,v_correction_id,v_case.sales_order_id,
          v_delivery.reservation_id,v_line.reservation_line_id,v_line.sales_order_line_id,
          v_line_no,v_line.expected_product_id,v_line.uom_id,v_line.product_code_snapshot,
          v_line.product_name_snapshot,v_line.uom_code_snapshot,v_line.uom_name_snapshot,
          v_line.base_qty_per_uom,v_line.quantity_base/v_line.base_qty_per_uom,
          v_line.quantity_base);
        INSERT INTO public.backoffice_sales_discrepancy_backorder_lines(company_id,
          backorder_id,discrepancy_line_id,backorder_delivery_order_line_id,quantity_base)
        SELECT v_company,backorder.id,v_line.id,v_correction_line,v_line.quantity_base
        FROM public.backoffice_sales_discrepancy_backorders backorder
        WHERE backorder.company_id=v_company AND backorder.discrepancy_id=v_case.id
          AND backorder.resolution_kind='WRONG_ITEM_CORRECTION';
      END IF;
      UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
        warehouse_resolution_status='RESOLVED',updated_at=v_now
      WHERE company_id=v_company AND id=v_line.id;
    END IF;
    v_resolved_count:=v_resolved_count+1;
  END LOOP;

  UPDATE public.backoffice_sales_reservations reservation SET
    total_released_base_qty=summary.released_qty,total_in_transit_base_qty=summary.transit_qty,
    total_completed_base_qty=summary.completed_qty,
    status=CASE WHEN summary.released_qty+summary.completed_qty=reservation.total_reserved_base_qty
      THEN 'FULFILLED' ELSE 'PARTIALLY_FULFILLED' END,
    master_version=reservation.master_version+1,updated_by=v_actor,updated_at=v_now
  FROM (SELECT sum(line.released_base_qty) released_qty,
      sum(line.in_transit_base_qty) transit_qty,sum(line.completed_base_qty) completed_qty
    FROM public.backoffice_sales_reservation_lines line
    WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id) summary
  WHERE reservation.company_id=v_company AND reservation.id=v_reservation.id;
  SELECT count(*) INTO v_open_count FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
    AND (line.warehouse_resolution_status='PENDING'
      OR line.commercial_approval_status='PENDING');
  v_case_status:=CASE WHEN v_open_count=0 THEN 'RESOLVED'
    WHEN EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
      WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
        AND line.commercial_approval_status='PENDING') THEN 'PENDING_SALES_APPROVAL'
    ELSE 'PENDING_WAREHOUSE_RESOLUTION' END;
  UPDATE public.backoffice_sales_delivery_discrepancies SET status=v_case_status,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now,
    resolved_by=CASE WHEN v_case_status='RESOLVED' THEN v_actor END,
    resolved_at=CASE WHEN v_case_status='RESOLVED' THEN v_now END
  WHERE company_id=v_company AND id=v_case.id;
  IF v_case_status='RESOLVED' THEN
    UPDATE public.backoffice_sales_delivery_orders SET status='COMPLETED',
      completed_by=v_actor,completed_at=v_now,master_version=master_version+1,
      updated_by=v_actor,updated_at=v_now
    WHERE company_id=v_company AND id=v_delivery.id;
  END IF;
  v_order_fulfillment:=CASE WHEN v_correction_id IS NOT NULL THEN 'PREPARING'
    WHEN v_case_status<>'RESOLVED' THEN 'IN_TRANSIT'
    WHEN NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id
        AND line.released_base_qty+line.completed_base_qty<line.reserved_base_qty)
      AND NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders delivery
        WHERE delivery.company_id=v_company AND delivery.sales_order_id=v_case.sales_order_id
          AND delivery.status NOT IN('COMPLETED','CANCELED')) THEN 'COMPLETED'
    ELSE 'PREPARING' END;
  UPDATE public.backoffice_sales_orders SET fulfillment_status=v_order_fulfillment,
    updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_case.sales_order_id;
  v_result:=jsonb_build_object('discrepancyId',v_case.id,
    'discrepancyNo',v_case.discrepancy_no,'status',v_case_status,
    'masterVersion',v_case.master_version+1,'resolvedLineCount',v_resolved_count,
    'correctionCreated',v_correction_id IS NOT NULL,
    'correctionDeliveryOrderId',v_correction_id,'correctionDeliveryNo',v_correction_no,
    'replacementScheduledDate',CASE WHEN v_correction_id IS NOT NULL THEN p_replacement_date END,
    'salesOrderFulfillmentStatus',v_order_fulfillment,'exactRetry',false);
  UPDATE public.backoffice_sales_discrepancy_operations SET
    result_payload=v_result,completed_at=v_now
  WHERE company_id=v_company AND id=p_operation_id
    AND result_payload IS NULL AND completed_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_OPERATION_CHANGED'; END IF;
  INSERT INTO public.backoffice_sales_discrepancy_audit(company_id,discrepancy_id,
    operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_case.id,p_operation_id,'WAREHOUSE_RESOLVE_OVERAGE_WRONG_ITEM',
    v_actor,v_before,v_result);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.resolve_backoffice_sales_overage_wrong_item(
  p_discrepancy_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_replacement_date date DEFAULT NULL,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.resolve_backoffice_sales_overage_wrong_item_core(
    p_discrepancy_id,p_expected_version,p_operation_id,p_replacement_date,p_notes);
END
$$;

REVOKE ALL ON FUNCTION
  private.record_backoffice_sales_discrepancy_transfer_effect(uuid,uuid,uuid,text,uuid),
  private.post_backoffice_sales_exact_return_transfer(uuid,bigint,uuid,uuid),
  private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.record_backoffice_sales_discrepancy_transfer_effect(uuid,uuid,uuid,text,uuid),
  private.post_backoffice_sales_exact_return_transfer(uuid,bigint,uuid,uuid),
  private.resolve_backoffice_sales_overage_wrong_item_core(uuid,bigint,uuid,date,text)
TO service_role;
REVOKE ALL ON FUNCTION public.resolve_backoffice_sales_overage_wrong_item(
  uuid,bigint,uuid,date,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolve_backoffice_sales_overage_wrong_item(
  uuid,bigint,uuid,date,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912130000','backoffice_sales_overage_wrong_item_resolution',
  'Step 4/6.5C3 atomically reconstructs and resolves Overage/Wrong Item, creates separate accepted-overage COGS HOLD, returns rejected/actual goods, and creates a correction DO/SJ for Wrong Item');
NOTIFY pgrst,'reload schema';
COMMIT;
