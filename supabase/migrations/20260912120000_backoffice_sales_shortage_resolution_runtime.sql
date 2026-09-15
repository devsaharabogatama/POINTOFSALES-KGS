-- Step 4/6.5B: atomic Warehouse resolution for SHORT discrepancies.
-- Overage and Wrong Item remain pending for the next physical-reconstruction gate.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912110000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Warehouse resolution foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912120000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)') IS NOT NULL
    OR to_regprocedure('public.resolve_backoffice_sales_shortage(uuid,bigint,uuid,date,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: shortage resolver collision';
  END IF;
END
$guard$;

-- Forward-fix 5A: every physical transfer effect, including return to source,
-- is backed by its canonical posted Stock Transfer document.
ALTER TABLE public.backoffice_sales_discrepancy_stock_effects
  DROP CONSTRAINT bo_sales_discrepancy_stock_effects_shape_check;
ALTER TABLE public.backoffice_sales_discrepancy_stock_effects
  ADD CONSTRAINT bo_sales_discrepancy_stock_effects_shape_check CHECK(
    effect_type IN('EXPECTED_RETURN_TO_SOURCE','EXPECTED_WRITE_OFF',
      'ACTUAL_TO_TRANSIT','ACTUAL_RETURN_TO_SOURCE','OVERAGE_TO_TRANSIT',
      'OVERAGE_RETURN_TO_SOURCE','OVERAGE_ACCEPTED_SALE')
    AND quantity_base>0 AND total_cost>=0
    AND ((effect_type IN('EXPECTED_RETURN_TO_SOURCE','ACTUAL_TO_TRANSIT',
          'ACTUAL_RETURN_TO_SOURCE','OVERAGE_TO_TRANSIT','OVERAGE_RETURN_TO_SOURCE')
        AND destination_warehouse_id IS NOT NULL
        AND destination_warehouse_id<>source_warehouse_id
        AND destination_stock_movement_id IS NOT NULL
        AND financial_event_id IS NULL
        AND stock_transfer_document_id IS NOT NULL)
      OR (effect_type IN('EXPECTED_WRITE_OFF','OVERAGE_ACCEPTED_SALE')
        AND destination_warehouse_id IS NULL
        AND destination_stock_movement_id IS NULL
        AND financial_event_id IS NOT NULL
        AND stock_transfer_document_id IS NULL)));

-- A Warehouse resolution reserves its idempotency key before Stock mutation.
-- Permit only the single NULL -> completed transition; every completed row
-- remains immutable exactly as before.
CREATE OR REPLACE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF TG_TABLE_NAME='backoffice_sales_discrepancy_operations'
    AND TG_OP='UPDATE' AND OLD.operation_type='WAREHOUSE_RESOLVE'
    AND OLD.result_payload IS NULL AND OLD.completed_at IS NULL
    AND NEW.result_payload IS NOT NULL AND NEW.completed_at IS NOT NULL
    AND NEW.id=OLD.id AND NEW.company_id=OLD.company_id
    AND NEW.discrepancy_id IS NOT DISTINCT FROM OLD.discrepancy_id
    AND NEW.operation_type=OLD.operation_type
    AND NEW.request_payload=OLD.request_payload AND NEW.actor_id=OLD.actor_id
    AND NEW.created_at=OLD.created_at THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'BACKOFFICE_SALES_DISCREPANCY_HISTORY_IMMUTABLE';
END
$$;

CREATE FUNCTION private.resolve_backoffice_sales_shortage_core(
  p_discrepancy_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_backorder_date date DEFAULT NULL,p_notes text DEFAULT NULL
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
  v_effect uuid;v_source_movement uuid;v_destination_movement uuid;
  v_transfer_id uuid;v_transfer_line uuid;v_event uuid;v_category uuid;
  v_source_stock numeric(24,6);v_remaining numeric(24,6);v_take numeric(24,6);
  v_cost numeric(24,4);v_total_cost numeric(24,4);v_base_uom uuid;v_base_name text;
  v_backorder_id uuid;v_backorder_no text;v_backorder_sequence integer;
  v_backorder_total numeric(24,6);v_backorder_line uuid;v_backorder_count integer:=0;
  v_resolved_count integer:=0;v_open_count bigint;v_has_backorder boolean:=false;
  v_case_status text;v_order_fulfillment text;v_before jsonb;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_discrepancy_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_REQUIRED'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'MASTER_VERSION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF length(COALESCE(p_notes,''))>500 THEN RAISE EXCEPTION 'WAREHOUSE_RESOLUTION_NOTES_TOO_LONG'; END IF;

  v_request:=jsonb_build_object('discrepancyId',p_discrepancy_id,
    'requestedBackorderDate',p_backorder_date,
    'notes',NULLIF(btrim(p_notes),''));

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_SHORTAGE_RESOLUTION:'||p_operation_id::text,0));
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
  p_backorder_date:=COALESCE(p_backorder_date,v_today);
  IF p_backorder_date<v_today THEN RAISE EXCEPTION 'BACKORDER_DATE_BEFORE_COMPANY_TODAY'; END IF;

  SELECT * INTO v_case FROM public.backoffice_sales_delivery_discrepancies discrepancy
  WHERE discrepancy.company_id=v_company AND discrepancy.id=p_discrepancy_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_NOT_FOUND'; END IF;
  IF v_case.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_case.status NOT IN('PENDING_WAREHOUSE_RESOLUTION','PENDING_SALES_APPROVAL') THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_NOT_RESOLVABLE';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
      AND line.discrepancy_type='SHORT' AND line.warehouse_resolution_status='PENDING') THEN
    RAISE EXCEPTION 'BACKOFFICE_SHORTAGE_PENDING_LINE_REQUIRED';
  END IF;
  v_before:=to_jsonb(v_case);
  SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.id=v_case.delivery_order_id FOR UPDATE;
  SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=v_case.sales_order_id FOR UPDATE;
  SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id FOR UPDATE;
  IF v_delivery.status<>'IN_TRANSIT' OR v_order.status<>'CONFIRMED' THEN
    RAISE EXCEPTION 'BACKOFFICE_SHORTAGE_SOURCE_STATE_INVALID';
  END IF;

  PERFORM 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
  ORDER BY line.id FOR UPDATE;

  INSERT INTO public.backoffice_sales_discrepancy_operations(id,company_id,
    discrepancy_id,operation_type,request_payload,actor_id)
  VALUES(p_operation_id,v_company,v_case.id,'WAREHOUSE_RESOLVE',v_request,v_actor);

  -- Create a single child DO/SJ for every BACKORDER line in this resolution.
  SELECT COALESCE(sum(line.quantity_base),0) INTO v_backorder_total
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
    AND line.discrepancy_type='SHORT' AND line.requested_resolution='BACKORDER'
    AND line.warehouse_resolution_status='PENDING';
  IF v_backorder_total>0 THEN
    v_has_backorder:=true;v_backorder_id:=gen_random_uuid();
    SELECT COALESCE(max(delivery.sequence_no),0)+1 INTO v_backorder_sequence
    FROM public.backoffice_sales_delivery_orders delivery
    WHERE delivery.company_id=v_company AND delivery.sales_order_id=v_case.sales_order_id;
    v_backorder_no:=private.next_sales_delivery_no(v_company,v_now);
    INSERT INTO public.backoffice_sales_delivery_orders(id,company_id,sales_order_id,
      reservation_id,delivery_no,sequence_no,delivery_kind,parent_delivery_order_id,
      status,scheduled_date,recipient_snapshot,notes,total_planned_base_qty,
      created_by,updated_by)
    VALUES(v_backorder_id,v_company,v_case.sales_order_id,v_delivery.reservation_id,
      v_backorder_no,v_backorder_sequence,'BACKORDER',v_delivery.id,'READY',
      p_backorder_date,v_delivery.recipient_snapshot,NULLIF(btrim(p_notes),''),
      v_backorder_total,v_actor,v_actor);
    INSERT INTO public.backoffice_sales_discrepancy_backorders(company_id,
      discrepancy_id,source_delivery_order_id,backorder_delivery_order_id,
      operation_id,created_by)
    VALUES(v_company,v_case.id,v_delivery.id,v_backorder_id,p_operation_id,v_actor);
  END IF;

  FOR v_line IN
    SELECT line.*,delivery_line.reservation_line_id,delivery_line.base_qty_per_uom,
      delivery_line.product_code_snapshot,delivery_line.product_name_snapshot,
      delivery_line.uom_code_snapshot,delivery_line.uom_name_snapshot
    FROM public.backoffice_sales_delivery_discrepancy_lines line
    JOIN public.backoffice_sales_delivery_order_lines delivery_line
      ON delivery_line.company_id=line.company_id AND delivery_line.id=line.delivery_order_line_id
    WHERE line.company_id=v_company AND line.discrepancy_id=v_case.id
      AND line.discrepancy_type='SHORT' AND line.warehouse_resolution_status='PENDING'
    ORDER BY line.id
  LOOP
    IF v_line.commercial_approval_status<>'NOT_REQUIRED'
      OR v_line.physical_state NOT IN('NOT_LOADED','RETURNING','LOST','DAMAGED') THEN
      RAISE EXCEPTION 'BACKOFFICE_SHORTAGE_LINE_CONTRACT_INVALID';
    END IF;
    SELECT product.uom_id,uom.name INTO STRICT v_base_uom,v_base_name
    FROM public.products product JOIN public.uoms uom
      ON uom.company_id=product.company_id AND uom.id=product.uom_id
    WHERE product.company_id=v_company AND product.id=v_line.expected_product_id;

    IF v_line.physical_state IN('NOT_LOADED','RETURNING') THEN
      v_transfer:=private.save_stock_transfer_document(NULL,NULL,
        (SELECT dispatch.transit_warehouse_id
         FROM public.backoffice_sales_delivery_dispatches dispatch
         WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
         ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1),
        v_reservation.warehouse_id,v_today,
        'Resolution '||v_case.discrepancy_no||' - '||v_line.physical_state,
        jsonb_build_array(jsonb_build_object('productId',v_line.expected_product_id,
          'quantityBase',v_line.quantity_base,'notes',NULLIF(btrim(p_notes),''))));
      v_transfer_id:=(v_transfer->>'documentId')::uuid;
      v_transfer:=private.post_stock_transfer(v_transfer_id,
        (v_transfer->>'masterVersion')::bigint,v_line.id);
      SELECT transfer_line.id INTO STRICT v_transfer_line
      FROM public.stock_transfer_lines transfer_line
      WHERE transfer_line.company_id=v_company AND transfer_line.document_id=v_transfer_id;
      SELECT movement.id INTO STRICT v_source_movement FROM public.stock_movements movement
      WHERE movement.company_id=v_company AND movement.reference_table='stock_transfer_documents'
        AND movement.reference_id=v_transfer_id AND movement.source_line_id=v_transfer_line
        AND movement.movement_type='TRANSFER_OUT'::public.stock_movement_type;
      SELECT movement.id INTO STRICT v_destination_movement FROM public.stock_movements movement
      WHERE movement.company_id=v_company AND movement.reference_table='stock_transfer_documents'
        AND movement.reference_id=v_transfer_id AND movement.source_line_id=v_transfer_line
        AND movement.movement_type='TRANSFER_IN'::public.stock_movement_type;
      SELECT transferred_cost INTO v_total_cost FROM public.stock_transfer_lines
      WHERE company_id=v_company AND id=v_transfer_line;
      v_effect:=gen_random_uuid();
      INSERT INTO public.backoffice_sales_discrepancy_stock_effects(id,company_id,
        discrepancy_id,discrepancy_line_id,operation_id,effect_type,product_id,
        source_warehouse_id,destination_warehouse_id,quantity_base,total_cost,
        source_stock_movement_id,destination_stock_movement_id,
        stock_transfer_document_id,created_by)
      SELECT v_effect,v_company,v_case.id,v_line.id,p_operation_id,
        'EXPECTED_RETURN_TO_SOURCE',v_line.expected_product_id,
        document.source_warehouse_id,document.destination_warehouse_id,
        v_line.quantity_base,v_total_cost,v_source_movement,v_destination_movement,
        v_transfer_id,v_actor FROM public.stock_transfer_documents document
      WHERE document.company_id=v_company AND document.id=v_transfer_id;
      INSERT INTO public.backoffice_sales_discrepancy_fifo_allocations(company_id,
        stock_effect_id,source_batch_id,destination_batch_id,quantity_base,
        unit_cost,total_cost)
      SELECT v_company,v_effect,allocation.source_batch_id,allocation.destination_batch_id,
        allocation.quantity_base,allocation.unit_cost_base,allocation.total_cost
      FROM public.stock_transfer_fifo_allocations allocation
      WHERE allocation.company_id=v_company AND allocation.document_id=v_transfer_id
        AND allocation.line_id=v_transfer_line;
    ELSE
      SELECT stock.stock_qty INTO v_source_stock FROM public.product_stocks stock
      WHERE stock.company_id=v_company AND stock.product_id=v_line.expected_product_id
        AND stock.warehouse_id=(SELECT dispatch.transit_warehouse_id
          FROM public.backoffice_sales_delivery_dispatches dispatch
          WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
          ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1) FOR UPDATE;
      IF COALESCE(v_source_stock,0)<v_line.quantity_base THEN
        RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSIT_FIFO_INSUFFICIENT';
      END IF;
      -- First calculate exact FIFO value without writing. The effect parent
      -- must exist before immutable FIFO lineage can reference it.
      v_remaining:=v_line.quantity_base;v_total_cost:=0;v_effect:=gen_random_uuid();
      v_source_movement:=gen_random_uuid();v_event:=gen_random_uuid();
      FOR v_batch IN
        SELECT batch.* FROM public.product_batches batch
        WHERE batch.company_id=v_company AND batch.product_id=v_line.expected_product_id
          AND batch.warehouse_id=(SELECT dispatch.transit_warehouse_id
            FROM public.backoffice_sales_delivery_dispatches dispatch
            WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
            ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1)
          AND batch.qty_remaining>0 ORDER BY batch.created_at,batch.id FOR UPDATE
      LOOP
        EXIT WHEN v_remaining<=0;v_take:=LEAST(v_remaining,v_batch.qty_remaining);
        v_total_cost:=v_total_cost+round(v_take*v_batch.cogs_unit,4);
        v_remaining:=v_remaining-v_take;
      END LOOP;
      IF v_remaining<>0 THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSIT_FIFO_INSUFFICIENT'; END IF;
      SELECT category.id INTO v_category FROM public.transaction_categories category
      WHERE category.company_id=v_company AND category.system_key='STOCK_LOSS'
        AND category.is_active ORDER BY category.is_system_default DESC,category.id LIMIT 1;
      IF v_category IS NULL THEN RAISE EXCEPTION 'STOCK_LOSS_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
      INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
        event_date,event_version,idempotency_key,amounts,status,error_message,created_by,
        company_id,store_id,system_event_key,transaction_category_id)
      VALUES(v_event,'BO-DISC-LOSS-'||upper(replace(v_effect::text,'-','')),
        'STOCK_LOSS'::public.event_type,'backoffice_sales_discrepancy_stock_effects',
        v_effect,v_now,1,'BACKOFFICE_DISCREPANCY_LOSS|'||v_company||'|'||v_line.id,
        jsonb_build_object('stockLossDebit',v_total_cost,'inventoryCredit',v_total_cost,
          'discrepancyId',v_case.id,'discrepancyLineId',v_line.id,
          'financePostingState','HOLD_FOR_DISCREPANCY_REVIEW'),
        'HOLD'::public.event_status,'BACKOFFICE_DELIVERY_DISCREPANCY_REVIEW_REQUIRED',
        v_actor,v_company,v_order.store_id,'STOCK_LOSS',v_category);
      UPDATE public.product_stocks SET stock_qty=stock_qty-v_line.quantity_base,updated_at=v_now
      WHERE company_id=v_company AND product_id=v_line.expected_product_id
        AND warehouse_id=(SELECT dispatch.transit_warehouse_id
          FROM public.backoffice_sales_delivery_dispatches dispatch
          WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
          ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1);
      INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
        movement_type,reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes)
      VALUES(v_source_movement,v_line.expected_product_id,
        (SELECT dispatch.transit_warehouse_id FROM public.backoffice_sales_delivery_dispatches dispatch
         WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
         ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1),
        -v_line.quantity_base,'ADJUSTMENT'::public.stock_movement_type,
        'backoffice_sales_discrepancy_stock_effects',v_effect,v_company,v_base_uom,
        v_base_name,v_source_stock-v_line.quantity_base,v_actor,v_now,'POSTED',v_line.id,
        COALESCE(NULLIF(btrim(p_notes),''),v_line.physical_state));
      INSERT INTO public.backoffice_sales_discrepancy_stock_effects(id,company_id,
        discrepancy_id,discrepancy_line_id,operation_id,effect_type,product_id,
        source_warehouse_id,quantity_base,total_cost,source_stock_movement_id,
        financial_event_id,created_by)
      VALUES(v_effect,v_company,v_case.id,v_line.id,p_operation_id,'EXPECTED_WRITE_OFF',
        v_line.expected_product_id,
        (SELECT dispatch.transit_warehouse_id FROM public.backoffice_sales_delivery_dispatches dispatch
         WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
         ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1),
        v_line.quantity_base,v_total_cost,v_source_movement,v_event,v_actor);
      v_remaining:=v_line.quantity_base;
      FOR v_batch IN
        SELECT batch.* FROM public.product_batches batch
        WHERE batch.company_id=v_company AND batch.product_id=v_line.expected_product_id
          AND batch.warehouse_id=(SELECT dispatch.transit_warehouse_id
            FROM public.backoffice_sales_delivery_dispatches dispatch
            WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
            ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1)
          AND batch.qty_remaining>0 ORDER BY batch.created_at,batch.id FOR UPDATE
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
    END IF;

    UPDATE public.backoffice_sales_reservation_lines SET
      in_transit_base_qty=in_transit_base_qty-v_line.quantity_base,
      released_base_qty=released_base_qty+CASE WHEN v_line.requested_resolution='ACCEPT_SHORT'
        THEN v_line.quantity_base ELSE 0 END,updated_at=v_now
    WHERE company_id=v_company AND id=v_line.reservation_line_id
      AND in_transit_base_qty>=v_line.quantity_base;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SHORTAGE_RESERVATION_CHANGED'; END IF;

    IF v_line.requested_resolution='BACKORDER' THEN
      v_backorder_count:=v_backorder_count+1;v_backorder_line:=gen_random_uuid();
      INSERT INTO public.backoffice_sales_delivery_order_lines(id,company_id,
        delivery_order_id,sales_order_id,reservation_id,reservation_line_id,
        sales_order_line_id,line_no,product_id,uom_id,product_code_snapshot,
        product_name_snapshot,uom_code_snapshot,uom_name_snapshot,base_qty_per_uom,
        planned_qty_uom,planned_base_qty)
      VALUES(v_backorder_line,v_company,v_backorder_id,v_case.sales_order_id,
        v_delivery.reservation_id,v_line.reservation_line_id,v_line.sales_order_line_id,
        v_backorder_count,v_line.expected_product_id,v_line.uom_id,
        v_line.product_code_snapshot,v_line.product_name_snapshot,
        v_line.uom_code_snapshot,v_line.uom_name_snapshot,v_line.base_qty_per_uom,
        v_line.quantity_base/v_line.base_qty_per_uom,v_line.quantity_base);
      INSERT INTO public.backoffice_sales_discrepancy_backorder_lines(company_id,
        backorder_id,discrepancy_line_id,backorder_delivery_order_line_id,quantity_base)
      VALUES(v_company,(SELECT backorder.id FROM public.backoffice_sales_discrepancy_backorders backorder
        WHERE backorder.company_id=v_company AND backorder.discrepancy_id=v_case.id),
        v_line.id,v_backorder_line,v_line.quantity_base);
    END IF;
    UPDATE public.backoffice_sales_delivery_discrepancy_lines SET
      warehouse_resolution_status='RESOLVED',updated_at=v_now
    WHERE company_id=v_company AND id=v_line.id;
    v_resolved_count:=v_resolved_count+1;
  END LOOP;

  UPDATE public.backoffice_sales_reservations reservation SET
    total_released_base_qty=summary.released_qty,
    total_in_transit_base_qty=summary.transit_qty,
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
  v_order_fulfillment:=CASE WHEN v_has_backorder THEN 'PREPARING'
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
    'masterVersion',v_case.master_version+1,'resolvedShortLineCount',v_resolved_count,
    'backorderCreated',v_has_backorder,'backorderDeliveryOrderId',v_backorder_id,
    'backorderDeliveryNo',v_backorder_no,'backorderScheduledDate',
    CASE WHEN v_has_backorder THEN p_backorder_date END,
    'salesOrderFulfillmentStatus',v_order_fulfillment,'exactRetry',false);
  UPDATE public.backoffice_sales_discrepancy_operations SET
    result_payload=v_result,completed_at=v_now
  WHERE company_id=v_company AND id=p_operation_id
    AND result_payload IS NULL AND completed_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SHORTAGE_OPERATION_CHANGED'; END IF;
  INSERT INTO public.backoffice_sales_discrepancy_audit(company_id,discrepancy_id,
    operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,v_case.id,p_operation_id,'WAREHOUSE_RESOLVE_SHORTAGE',v_actor,
    NULLIF(btrim(p_notes),''),v_before,v_result);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.resolve_backoffice_sales_shortage(
  p_discrepancy_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_backorder_date date DEFAULT NULL,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.resolve_backoffice_sales_shortage_core(p_discrepancy_id,
    p_expected_version,p_operation_id,p_backorder_date,p_notes);
END
$$;

REVOKE ALL ON FUNCTION private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.resolve_backoffice_sales_shortage_core(uuid,bigint,uuid,date,text)
  TO service_role;
REVOKE ALL ON FUNCTION public.resolve_backoffice_sales_shortage(uuid,bigint,uuid,date,text)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.resolve_backoffice_sales_shortage(uuid,bigint,uuid,date,text)
  TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912120000','backoffice_sales_shortage_resolution_runtime',
  'Step 4/6.5B atomically resolves SHORT physical state, returns/writes off exact Transit FIFO, creates linked Backorder DO/SJ, and defaults editable Backorder date to Company today');

NOTIFY pgrst,'reload schema';
COMMIT;
