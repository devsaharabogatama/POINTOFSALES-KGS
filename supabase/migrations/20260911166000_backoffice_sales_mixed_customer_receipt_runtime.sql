-- Step 4/6.3: atomic mixed Customer Receipt runtime.
-- Accepted quantity is sold out from exact Transit FIFO and becomes Qty To
-- Invoice. Discrepancy quantity remains in Transit and operationally open.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911165000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: physical-state contract required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911166000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911166000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.receive_backoffice_sales_delivery_core(uuid,bigint,uuid,date,text)') IS NULL
    OR to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,text)') IS NULL
    OR to_regprocedure('private.validate_backoffice_sales_receipt_disposition_payload(jsonb)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical receipt dependency missing';
  END IF;
  IF to_regprocedure('private.receive_backoffice_sales_delivery_disposition_core(uuid,bigint,uuid,date,jsonb,text)') IS NOT NULL
    OR to_regprocedure('public.receive_backoffice_sales_delivery(uuid,bigint,uuid,date,jsonb,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: mixed receipt runtime collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancies)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_operations)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_discrepancy_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected pre-runtime discrepancy rows';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_receipts receipt
    WHERE receipt.total_received_base_qty<=0 OR receipt.financial_event_id IS NULL) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: legacy receipt shape drift';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_delivery_receipts
  DROP CONSTRAINT backoffice_sales_delivery_receipts_shape_check;
ALTER TABLE public.backoffice_sales_delivery_receipts
  ADD CONSTRAINT backoffice_sales_delivery_receipts_shape_check CHECK(
    nullif(btrim(receipt_no),'') IS NOT NULL
    AND jsonb_typeof(request_payload)='object'
    AND jsonb_typeof(result_payload)='object'
    AND total_received_base_qty>=0 AND total_fifo_cost>=0
    AND ((total_received_base_qty=0 AND total_fifo_cost=0
          AND financial_event_id IS NULL)
      OR (total_received_base_qty>0 AND financial_event_id IS NOT NULL)));

CREATE FUNCTION private.receive_backoffice_sales_delivery_disposition_core(
  p_delivery_order_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_accepted_date date,p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
  v_order public.backoffice_sales_orders%rowtype;
  v_reservation public.backoffice_sales_reservations%rowtype;
  v_existing public.backoffice_sales_delivery_receipts%rowtype;
  v_validation jsonb;v_request jsonb;v_result jsonb;v_now timestamptz:=clock_timestamp();
  v_company_today date;v_timezone text;v_departed_date date;
  v_receipt_id uuid:=gen_random_uuid();v_event_id uuid;v_discrepancy_id uuid:=gen_random_uuid();
  v_receipt_no text;v_discrepancy_no text;v_discrepancy_status text;
  v_transit uuid;v_total_accepted numeric(24,6);v_total_discrepancy numeric(24,6);
  v_total_cost numeric(24,4):=0;v_line_cost numeric(24,4);v_exact_batch_qty numeric(24,6);
  v_category uuid;v_category_count bigint;v_rule_version bigint;v_rule_count bigint;
  v_delivery_line_count bigint;v_payload_line_count bigint;
  v_updated_count bigint;
  v_line record;v_batch record;v_input_line jsonb;v_item jsonb;v_class jsonb;
  v_accepted numeric(24,6);v_expected_issue numeric(24,6);
  v_remaining numeric(24,6);v_take numeric(24,6);v_stock_before numeric(24,6);
  v_receipt_line_id uuid;v_movement_id uuid;v_base_uom_id uuid;
  v_base_uom_name text;v_base_uom_count bigint;v_reservation_status text;
  v_actual_product uuid;v_actual_uom uuid;v_actual_uom_count bigint;
  v_actual_qty_uom numeric(24,6);v_actual_qty_base numeric(24,6);
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_delivery_order_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_DELIVERY_REQUIRED'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'MASTER_VERSION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_accepted_date IS NULL THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_REQUIRED'; END IF;
  IF length(COALESCE(p_notes,''))>500 THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOTES_TOO_LONG'; END IF;
  v_validation:=private.validate_backoffice_sales_receipt_disposition_payload(p_lines);
  v_total_accepted:=(v_validation->>'acceptedBaseQty')::numeric;
  v_total_discrepancy:=(v_validation->>'discrepancyBaseQty')::numeric;
  IF (v_validation->>'discrepancyCount')::integer=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISCREPANCY_REQUIRED';
  END IF;

  v_request:=jsonb_build_object('deliveryOrderId',p_delivery_order_id,
    'acceptedDate',p_accepted_date,'lines',p_lines,
    'notes',NULLIF(btrim(p_notes),''));
  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_CUSTOMER_RECEIPT:'||p_operation_id::text,0));
  SELECT * INTO v_existing FROM public.backoffice_sales_delivery_receipts receipt
  WHERE receipt.company_id=v_company AND receipt.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_existing.request_payload IS DISTINCT FROM v_request THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN v_existing.result_payload||jsonb_build_object('exactRetry',true);
  END IF;

  SELECT company.timezone,(v_now AT TIME ZONE company.timezone)::date
  INTO v_timezone,v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  IF p_accepted_date>v_company_today THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_FUTURE'; END IF;

  SELECT * INTO v_delivery FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_DELIVERY_NOT_FOUND'; END IF;
  IF v_delivery.master_version<>p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_delivery.status<>'IN_TRANSIT'
    OR v_delivery.total_shipped_base_qty<>v_delivery.total_planned_base_qty
    OR v_delivery.total_received_base_qty<>0 OR v_delivery.departed_at IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_NOT_RECEIVABLE';
  END IF;
  v_departed_date:=(v_delivery.departed_at AT TIME ZONE v_timezone)::date;
  IF p_accepted_date<v_departed_date THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_BEFORE_DISPATCH'; END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_receipts receipt
    WHERE receipt.company_id=v_company AND receipt.delivery_order_id=v_delivery.id) THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_ALREADY_RECEIVED';
  END IF;

  SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=v_delivery.sales_order_id FOR UPDATE;
  SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id
    AND reservation.sales_order_id=v_delivery.sales_order_id FOR UPDATE;
  IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status<>'IN_TRANSIT'
    OR v_reservation.status<>'PARTIALLY_FULFILLED' THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_ORDER_STATE_INVALID';
  END IF;

  PERFORM 1 FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id
  ORDER BY line.line_no FOR UPDATE;
  SELECT count(*) INTO v_delivery_line_count
  FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id;
  SELECT count(*) INTO v_payload_line_count FROM jsonb_array_elements(p_lines);
  IF v_delivery_line_count<>v_payload_line_count THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_SET_INVALID';
  END IF;

  FOR v_line IN SELECT line.* FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id
    ORDER BY line.line_no
  LOOP
    SELECT item.value INTO v_input_line FROM jsonb_array_elements(p_lines) item(value)
    WHERE item.value->>'deliveryLineId'=v_line.id::text;
    IF v_input_line IS NULL OR v_line.shipped_base_qty<>v_line.planned_base_qty
      OR v_line.received_base_qty<>0 THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_LINE_STATE_INVALID';
    END IF;
    v_accepted:=(v_input_line->>'acceptedBaseQty')::numeric;
    SELECT COALESCE(sum((issue.value->>'quantityBase')::numeric)
      FILTER(WHERE upper(issue.value->>'discrepancyType') IN('SHORT','WRONG_ITEM')),0)
    INTO v_expected_issue
    FROM jsonb_array_elements(COALESCE(v_input_line->'discrepancies','[]'::jsonb)) issue(value);
    IF v_accepted+v_expected_issue<>v_line.shipped_base_qty THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_EXPECTED_QUANTITY_MISMATCH';
    END IF;
    FOR v_item IN SELECT value
      FROM jsonb_array_elements(COALESCE(v_input_line->'discrepancies','[]'::jsonb))
    LOOP
      IF length(COALESCE(v_item->>'reason',''))>500 THEN
        RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_REASON_TOO_LONG';
      END IF;
      IF upper(v_item->>'discrepancyType')='WRONG_ITEM' THEN
        v_actual_product:=(v_item->>'actualProductId')::uuid;
        v_actual_uom:=(v_item->>'actualUomId')::uuid;
        v_actual_qty_uom:=(v_item->>'actualQuantityUom')::numeric;
        v_actual_qty_base:=(v_item->>'actualQuantityBase')::numeric;
        SELECT count(*) INTO v_actual_uom_count
        FROM public.product_uoms product_uom
        JOIN public.products product ON product.company_id=product_uom.company_id
          AND product.id=product_uom.product_id
        JOIN public.uoms uom ON uom.company_id=product_uom.company_id
          AND uom.id=product_uom.uom_id
        WHERE product_uom.company_id=v_company AND product_uom.product_id=v_actual_product
          AND product_uom.uom_id=v_actual_uom AND product_uom.is_active
          AND product.is_active AND uom.is_active
          AND round(v_actual_qty_uom*product_uom.factor_to_base,6)=v_actual_qty_base;
        IF v_actual_uom_count<>1 OR v_actual_product=v_line.product_id THEN
          RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTUAL_ITEM_MAPPING_INVALID';
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  SELECT dispatch.transit_warehouse_id INTO STRICT v_transit
  FROM public.backoffice_sales_delivery_dispatches dispatch
  WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
  ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_dispatches dispatch
    WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
      AND dispatch.transit_warehouse_id<>v_transit) THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_WAREHOUSE_MISMATCH';
  END IF;

  -- Lock exact outbound Transit batches and calculate accepted-only FIFO cost.
  PERFORM destination.id
  FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
  JOIN public.stock_transfer_fifo_allocations transfer_allocation
    ON transfer_allocation.company_id=dispatch_line.company_id
   AND transfer_allocation.line_id=dispatch_line.stock_transfer_line_id
  JOIN public.product_batches destination
    ON destination.company_id=transfer_allocation.company_id
   AND destination.id=transfer_allocation.destination_batch_id
  WHERE dispatch_line.company_id=v_company
    AND dispatch_line.delivery_order_line_id IN(SELECT line.id
      FROM public.backoffice_sales_delivery_order_lines line
      WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id)
  ORDER BY destination.id FOR UPDATE OF destination;

  FOR v_line IN SELECT line.* FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id
    ORDER BY line.line_no
  LOOP
    SELECT item.value INTO STRICT v_input_line FROM jsonb_array_elements(p_lines) item(value)
    WHERE item.value->>'deliveryLineId'=v_line.id::text;
    v_accepted:=(v_input_line->>'acceptedBaseQty')::numeric;
    v_remaining:=v_accepted;v_line_cost:=0;
    SELECT COALESCE(sum(destination.qty_remaining),0) INTO v_exact_batch_qty
    FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
    JOIN public.stock_transfer_fifo_allocations transfer_allocation
      ON transfer_allocation.company_id=dispatch_line.company_id
     AND transfer_allocation.line_id=dispatch_line.stock_transfer_line_id
    JOIN public.product_batches destination
      ON destination.company_id=transfer_allocation.company_id
     AND destination.id=transfer_allocation.destination_batch_id
    WHERE dispatch_line.company_id=v_company
      AND dispatch_line.delivery_order_line_id=v_line.id
      AND destination.warehouse_id=v_transit;
    IF v_exact_batch_qty<v_accepted THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_FIFO_INSUFFICIENT';
    END IF;
    FOR v_batch IN SELECT destination.*
      FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
      JOIN public.stock_transfer_fifo_allocations transfer_allocation
        ON transfer_allocation.company_id=dispatch_line.company_id
       AND transfer_allocation.line_id=dispatch_line.stock_transfer_line_id
      JOIN public.product_batches destination
        ON destination.company_id=transfer_allocation.company_id
       AND destination.id=transfer_allocation.destination_batch_id
      WHERE dispatch_line.company_id=v_company
        AND dispatch_line.delivery_order_line_id=v_line.id
        AND destination.warehouse_id=v_transit AND destination.qty_remaining>0
      ORDER BY destination.created_at,destination.id
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.qty_remaining);
      v_line_cost:=v_line_cost+round(v_take*v_batch.cogs_unit,4);
      v_remaining:=v_remaining-v_take;
    END LOOP;
    IF v_remaining<>0 THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_FIFO_INSUFFICIENT'; END IF;
    v_total_cost:=v_total_cost+v_line_cost;
  END LOOP;

  IF v_total_accepted>0 THEN
    SELECT count(DISTINCT category.id),(array_agg(DISTINCT category.id))[1]
    INTO v_category_count,v_category FROM public.transaction_categories category
    WHERE category.company_id=v_company AND category.system_key='BACKOFFICE_CUSTOMER_RECEIPT'
      AND category.is_active;
    IF v_category_count<>1 THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_CATEGORY_MISSING_OR_AMBIGUOUS'; END IF;
    SELECT count(*),max(rule_set.rule_set_version) INTO v_rule_count,v_rule_version
    FROM public.posting_rule_sets rule_set
    WHERE rule_set.company_id=v_company AND rule_set.transaction_category_id=v_category
      AND rule_set.system_key='BACKOFFICE_CUSTOMER_RECEIPT' AND rule_set.status='APPROVED'
      AND rule_set.effective_from<=v_now
      AND (rule_set.effective_to IS NULL OR rule_set.effective_to>v_now);
    IF v_rule_count<>1 OR v_rule_version IS NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_RULE_SET_MISSING_OR_AMBIGUOUS';
    END IF;
    v_event_id:=gen_random_uuid();
  END IF;

  v_receipt_no:='BCR-'||to_char(p_accepted_date,'YYYYMMDD')||'-'
    ||upper(substr(replace(v_receipt_id::text,'-',''),1,12));
  v_discrepancy_no:='BDC-'||to_char(p_accepted_date,'YYYYMMDD')||'-'
    ||upper(substr(replace(v_discrepancy_id::text,'-',''),1,12));
  v_discrepancy_status:=CASE
    WHEN (v_validation->>'requiresSalesApproval')::boolean THEN 'PENDING_SALES_APPROVAL'
    ELSE 'PENDING_WAREHOUSE_RESOLUTION' END;
  v_result:=jsonb_build_object('receiptId',v_receipt_id,'receiptNo',v_receipt_no,
    'deliveryOrderId',v_delivery.id,'deliveryNo',v_delivery.delivery_no,
    'deliveryStatus','IN_TRANSIT','masterVersion',v_delivery.master_version+1,
    'acceptedDate',p_accepted_date,'receivedBaseQty',v_total_accepted,
    'fifoCostTotal',v_total_cost,'financialEventId',v_event_id,
    'financialEventStatus',CASE WHEN v_event_id IS NULL THEN NULL ELSE 'HOLD' END,
    'discrepancyId',v_discrepancy_id,'discrepancyNo',v_discrepancy_no,
    'discrepancyStatus',v_discrepancy_status,'exactRetry',false);

  IF v_event_id IS NOT NULL THEN
    INSERT INTO public.financial_events(id,event_code,event_type,source_table,source_id,
      root_sales_id,event_date,event_version,idempotency_key,payment_method,amounts,
      status,created_by,company_id,store_id,system_event_key,transaction_category_id,
      transaction_rule_version)
    VALUES(v_event_id,'BO-RCV-'||upper(replace(v_receipt_id::text,'-','')),
      'SALE_POSTED'::public.event_type,'backoffice_sales_delivery_receipts',v_receipt_id,
      NULL,v_now,1,'BACKOFFICE_RECEIPT|'||v_company||'|'||p_operation_id,NULL,
      jsonb_build_object('fifoCostTotal',v_total_cost,'acceptedDate',p_accepted_date,
        'deliveryOrderId',v_delivery.id,'salesOrderId',v_delivery.sales_order_id),
      'HOLD'::public.event_status,v_actor,v_company,v_order.store_id,
      'BACKOFFICE_CUSTOMER_RECEIPT',v_category,v_rule_version);
  END IF;

  INSERT INTO public.backoffice_sales_delivery_receipts(id,company_id,receipt_no,
    delivery_order_id,sales_order_id,reservation_id,operation_id,request_payload,
    result_payload,transit_warehouse_id,accepted_date,total_received_base_qty,
    total_fifo_cost,financial_event_id,notes,accepted_by,accepted_at)
  VALUES(v_receipt_id,v_company,v_receipt_no,v_delivery.id,v_delivery.sales_order_id,
    v_delivery.reservation_id,p_operation_id,v_request,v_result,v_transit,
    p_accepted_date,v_total_accepted,v_total_cost,v_event_id,
    NULLIF(btrim(p_notes),''),v_actor,v_now);

  INSERT INTO public.backoffice_sales_delivery_discrepancies(id,company_id,
    discrepancy_no,delivery_order_id,sales_order_id,receipt_id,status,
    total_discrepancy_base_qty,requires_sales_approval,
    requires_warehouse_resolution,created_by,updated_by)
  VALUES(v_discrepancy_id,v_company,v_discrepancy_no,v_delivery.id,
    v_delivery.sales_order_id,v_receipt_id,v_discrepancy_status,v_total_discrepancy,
    (v_validation->>'requiresSalesApproval')::boolean,
    (v_validation->>'requiresWarehouseResolution')::boolean,v_actor,v_actor);

  FOR v_line IN SELECT line.* FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id
    ORDER BY line.line_no
  LOOP
    SELECT item.value INTO STRICT v_input_line FROM jsonb_array_elements(p_lines) item(value)
    WHERE item.value->>'deliveryLineId'=v_line.id::text;
    FOR v_item IN SELECT value
      FROM jsonb_array_elements(COALESCE(v_input_line->'discrepancies','[]'::jsonb))
    LOOP
      v_class:=private.classify_backoffice_sales_discrepancy(
        v_item->>'discrepancyType',v_item->>'requestedResolution',
        v_item->>'physicalState');
      INSERT INTO public.backoffice_sales_delivery_discrepancy_lines(company_id,
        discrepancy_id,delivery_order_id,sales_order_id,delivery_order_line_id,
        sales_order_line_id,expected_product_id,actual_product_id,uom_id,
        discrepancy_type,requested_resolution,quantity_uom,quantity_base,
        commercial_approval_status,warehouse_resolution_status,reason,
        physical_state,actual_uom_id,actual_quantity_uom,actual_quantity_base)
      VALUES(v_company,v_discrepancy_id,v_delivery.id,v_delivery.sales_order_id,
        v_line.id,v_line.sales_order_line_id,v_line.product_id,
        CASE WHEN v_class->>'discrepancyType'='WRONG_ITEM'
          THEN (v_item->>'actualProductId')::uuid END,v_line.uom_id,
        v_class->>'discrepancyType',v_class->>'requestedResolution',
        (v_item->>'quantityBase')::numeric/v_line.base_qty_per_uom,
        (v_item->>'quantityBase')::numeric,
        CASE WHEN (v_class->>'requiresSalesApproval')::boolean
          THEN 'PENDING' ELSE 'NOT_REQUIRED' END,
        CASE WHEN (v_class->>'requiresWarehouseResolution')::boolean
          THEN 'PENDING' ELSE 'NOT_REQUIRED' END,NULLIF(btrim(v_item->>'reason'),''),
        v_class->>'physicalState',
        CASE WHEN v_class->>'discrepancyType'='WRONG_ITEM'
          THEN (v_item->>'actualUomId')::uuid END,
        CASE WHEN v_class->>'discrepancyType'='WRONG_ITEM'
          THEN (v_item->>'actualQuantityUom')::numeric END,
        CASE WHEN v_class->>'discrepancyType'='WRONG_ITEM'
          THEN (v_item->>'actualQuantityBase')::numeric END);
    END LOOP;

    v_accepted:=(v_input_line->>'acceptedBaseQty')::numeric;
    CONTINUE WHEN v_accepted=0;
    SELECT count(DISTINCT transfer_line.base_uom_id),
      (array_agg(DISTINCT transfer_line.base_uom_id))[1],
      (array_agg(DISTINCT transfer_line.base_uom_name_snapshot))[1]
    INTO v_base_uom_count,v_base_uom_id,v_base_uom_name
    FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
    JOIN public.stock_transfer_lines transfer_line
      ON transfer_line.company_id=dispatch_line.company_id
     AND transfer_line.id=dispatch_line.stock_transfer_line_id
    WHERE dispatch_line.company_id=v_company
      AND dispatch_line.delivery_order_line_id=v_line.id;
    IF v_base_uom_count<>1 OR v_base_uom_id IS NULL
      OR NULLIF(btrim(v_base_uom_name),'') IS NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_BASE_UOM_SNAPSHOT_INVALID';
    END IF;
    SELECT stock.stock_qty INTO v_stock_before FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND stock.product_id=v_line.product_id
      AND stock.warehouse_id=v_transit FOR UPDATE;
    IF NOT FOUND OR v_stock_before<v_accepted THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_STOCK_INSUFFICIENT';
    END IF;
    v_receipt_line_id:=gen_random_uuid();v_movement_id:=gen_random_uuid();
    v_remaining:=v_accepted;v_line_cost:=0;
    FOR v_batch IN SELECT destination.*
      FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
      JOIN public.stock_transfer_fifo_allocations transfer_allocation
        ON transfer_allocation.company_id=dispatch_line.company_id
       AND transfer_allocation.line_id=dispatch_line.stock_transfer_line_id
      JOIN public.product_batches destination
        ON destination.company_id=transfer_allocation.company_id
       AND destination.id=transfer_allocation.destination_batch_id
      WHERE dispatch_line.company_id=v_company
        AND dispatch_line.delivery_order_line_id=v_line.id
        AND destination.warehouse_id=v_transit AND destination.qty_remaining>0
      ORDER BY destination.created_at,destination.id FOR UPDATE OF destination
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.qty_remaining);
      v_line_cost:=v_line_cost+round(v_take*v_batch.cogs_unit,4);
      v_remaining:=v_remaining-v_take;
    END LOOP;
    IF v_remaining<>0 THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_FIFO_INSUFFICIENT'; END IF;
    UPDATE public.product_stocks SET stock_qty=stock_qty-v_accepted,updated_at=v_now
    WHERE company_id=v_company AND product_id=v_line.product_id
      AND warehouse_id=v_transit AND stock_qty>=v_accepted;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_STOCK_INSUFFICIENT'; END IF;
    INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_movement_id,v_line.product_id,v_transit,-v_accepted,
      'BACKOFFICE_SALE'::public.stock_movement_type,
      'backoffice_sales_delivery_receipts',v_receipt_id,v_company,v_base_uom_id,
      v_base_uom_name,v_stock_before-v_accepted,v_actor,v_now,'POSTED',
      v_receipt_line_id,NULLIF(btrim(p_notes),''));
    INSERT INTO public.backoffice_sales_delivery_receipt_lines(id,company_id,
      receipt_id,delivery_order_id,sales_order_id,reservation_id,reservation_line_id,
      delivery_order_line_id,sales_order_line_id,product_id,uom_id,received_qty_uom,
      received_base_qty,fifo_cost_total,stock_movement_id)
    VALUES(v_receipt_line_id,v_company,v_receipt_id,v_delivery.id,
      v_delivery.sales_order_id,v_delivery.reservation_id,v_line.reservation_line_id,
      v_line.id,v_line.sales_order_line_id,v_line.product_id,v_line.uom_id,
      v_accepted/v_line.base_qty_per_uom,v_accepted,v_line_cost,v_movement_id);
    v_remaining:=v_accepted;
    FOR v_batch IN SELECT destination.*
      FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
      JOIN public.stock_transfer_fifo_allocations transfer_allocation
        ON transfer_allocation.company_id=dispatch_line.company_id
       AND transfer_allocation.line_id=dispatch_line.stock_transfer_line_id
      JOIN public.product_batches destination
        ON destination.company_id=transfer_allocation.company_id
       AND destination.id=transfer_allocation.destination_batch_id
      WHERE dispatch_line.company_id=v_company
        AND dispatch_line.delivery_order_line_id=v_line.id
        AND destination.warehouse_id=v_transit AND destination.qty_remaining>0
      ORDER BY destination.created_at,destination.id FOR UPDATE OF destination
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.qty_remaining);
      UPDATE public.product_batches SET qty_remaining=qty_remaining-v_take
      WHERE company_id=v_company AND id=v_batch.id;
      INSERT INTO public.backoffice_sales_receipt_fifo_allocations(company_id,
        receipt_id,receipt_line_id,transit_batch_id,quantity_base,unit_cost,total_cost)
      VALUES(v_company,v_receipt_id,v_receipt_line_id,v_batch.id,v_take,
        v_batch.cogs_unit,round(v_take*v_batch.cogs_unit,4));
      v_remaining:=v_remaining-v_take;
    END LOOP;
  END LOOP;

  IF v_total_accepted>0 AND round(COALESCE((SELECT sum(line.fifo_cost_total)
    FROM public.backoffice_sales_delivery_receipt_lines line
    WHERE line.company_id=v_company AND line.receipt_id=v_receipt_id),0),4)
      <>round(v_total_cost,4) THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_COST_RECONCILIATION_FAILED';
  END IF;

  UPDATE public.backoffice_sales_delivery_order_lines delivery_line SET
    received_base_qty=input.accepted_base_qty,updated_at=v_now
  FROM (SELECT (item.value->>'deliveryLineId')::uuid delivery_line_id,
      (item.value->>'acceptedBaseQty')::numeric accepted_base_qty
    FROM jsonb_array_elements(p_lines) item(value)) input
  WHERE delivery_line.company_id=v_company
    AND delivery_line.delivery_order_id=v_delivery.id
    AND delivery_line.id=input.delivery_line_id;
  UPDATE public.backoffice_sales_reservation_lines reservation_line SET
    in_transit_base_qty=reservation_line.in_transit_base_qty-input.accepted_base_qty,
    completed_base_qty=reservation_line.completed_base_qty+input.accepted_base_qty,
    updated_at=v_now
  FROM (SELECT line.reservation_line_id,
      (item.value->>'acceptedBaseQty')::numeric accepted_base_qty
    FROM jsonb_array_elements(p_lines) item(value)
    JOIN public.backoffice_sales_delivery_order_lines line
      ON line.company_id=v_company
     AND line.id=(item.value->>'deliveryLineId')::uuid
    WHERE line.delivery_order_id=v_delivery.id) input
  WHERE reservation_line.company_id=v_company
    AND reservation_line.id=input.reservation_line_id
    AND reservation_line.in_transit_base_qty>=input.accepted_base_qty;
  GET DIAGNOSTICS v_updated_count=ROW_COUNT;
  IF v_updated_count<>v_delivery_line_count THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_RESERVATION_CHANGED';
  END IF;
  UPDATE public.backoffice_sales_order_lines order_line SET
    accepted_base_qty=order_line.accepted_base_qty+input.accepted_base_qty,
    updated_at=v_now
  FROM (SELECT line.sales_order_line_id,
      (item.value->>'acceptedBaseQty')::numeric accepted_base_qty
    FROM jsonb_array_elements(p_lines) item(value)
    JOIN public.backoffice_sales_delivery_order_lines line
      ON line.company_id=v_company
     AND line.id=(item.value->>'deliveryLineId')::uuid
    WHERE line.delivery_order_id=v_delivery.id) input
  WHERE order_line.company_id=v_company AND order_line.id=input.sales_order_line_id;
  GET DIAGNOSTICS v_updated_count=ROW_COUNT;
  IF v_updated_count<>v_delivery_line_count THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_ORDER_LINE_CHANGED';
  END IF;

  UPDATE public.backoffice_sales_delivery_orders SET status='IN_TRANSIT',
    total_received_base_qty=v_total_accepted,master_version=master_version+1,
    updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery.id;
  UPDATE public.backoffice_sales_reservations SET
    total_in_transit_base_qty=(SELECT sum(line.in_transit_base_qty)
      FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id),
    total_completed_base_qty=(SELECT sum(line.completed_base_qty)
      FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id),
    status=CASE WHEN NOT EXISTS(SELECT 1
      FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id
        AND line.released_base_qty+line.completed_base_qty<line.reserved_base_qty)
      THEN 'FULFILLED' ELSE 'PARTIALLY_FULFILLED' END,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_reservation.id RETURNING status INTO v_reservation_status;
  UPDATE public.backoffice_sales_orders SET fulfillment_status='IN_TRANSIT',
    updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery.sales_order_id;

  INSERT INTO public.backoffice_sales_discrepancy_operations(id,company_id,
    discrepancy_id,operation_type,request_payload,result_payload,actor_id,completed_at)
  VALUES(p_operation_id,v_company,v_discrepancy_id,'CUSTOMER_CONFIRM',v_request,
    v_result,v_actor,v_now);
  INSERT INTO public.backoffice_sales_discrepancy_audit(company_id,discrepancy_id,
    operation_id,action,actor_id,before_state,after_state)
  VALUES(v_company,v_discrepancy_id,p_operation_id,'CUSTOMER_CONFIRM',v_actor,NULL,
    jsonb_build_object('status',v_discrepancy_status,'receiptId',v_receipt_id,
      'receivedBaseQty',v_total_accepted,'discrepancyBaseQty',v_total_discrepancy));
  INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,
    delivery_order_id,operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,v_delivery.sales_order_id,v_delivery.id,p_operation_id,
    'RECORD_DISCREPANCY',v_actor,NULLIF(btrim(p_notes),''),
    jsonb_build_object('status',v_delivery.status,'masterVersion',v_delivery.master_version,
      'totalReceivedBaseQty',0),v_result);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.receive_backoffice_sales_delivery(
  p_delivery_order_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_accepted_date date,p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp SET statement_timeout='30s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.receive_backoffice_sales_delivery_disposition_core(
    p_delivery_order_id,p_expected_version,p_operation_id,p_accepted_date,
    p_lines,p_notes);
END
$$;

-- Qty accepted is independently invoiceable while the discrepancy remains open.
DO $patch_invoice_gate$
DECLARE
  v_definition text;v_old text;v_new text;v_occurrences integer;
BEGIN
  SELECT pg_get_functiondef(to_regprocedure(
    'public.save_backoffice_sales_invoice_draft(uuid,bigint,uuid,uuid,jsonb)'))
  INTO STRICT v_definition;
  v_old:=$old$AND document.status='CONFIRMED' AND document.fulfillment_status='COMPLETED'
      AND document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'$old$;
  v_new:=$new$AND document.status='CONFIRMED'
      AND document.sales_process_mode='BACKOFFICE_DELIVERED_QTY_INVOICE'
      AND (document.fulfillment_status='COMPLETED'
        OR (document.fulfillment_status='IN_TRANSIT'
          AND upper(btrim(COALESCE(p_payload->>'invoiceType','')))='REGULAR'
          AND EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines invoiceable_line
            WHERE invoiceable_line.company_id=document.company_id
              AND invoiceable_line.sales_order_id=document.id
              AND invoiceable_line.to_invoice_base_qty>0)))$new$;
  v_occurrences:=(length(v_definition)-length(replace(v_definition,v_old,'')))
    /length(v_old);
  IF v_occurrences<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Invoice gate drift';
  END IF;
  EXECUTE replace(v_definition,v_old,v_new);
END
$patch_invoice_gate$;

REVOKE ALL ON FUNCTION
  private.receive_backoffice_sales_delivery_disposition_core(
    uuid,bigint,uuid,date,jsonb,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.receive_backoffice_sales_delivery_disposition_core(
    uuid,bigint,uuid,date,jsonb,text) TO service_role;
REVOKE ALL ON FUNCTION public.receive_backoffice_sales_delivery(
  uuid,bigint,uuid,date,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.receive_backoffice_sales_delivery(
  uuid,bigint,uuid,date,jsonb,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911166000','backoffice_sales_mixed_customer_receipt_runtime',
  'Step 4/6.3 atomic accepted-only Transit FIFO sale-out, immediate Qty To Invoice and open discrepancy persistence; clean receipt compatibility preserved');

NOTIFY pgrst,'reload schema';
COMMIT;
