-- Clean Backoffice Customer receipt runtime.
-- Finalizes a fully dispatched DO from its exact outbound Transit batches,
-- updates delivered/to-invoice ledgers and creates a COGS Financial Event HOLD.
-- No Invoice, Revenue, Tax, AR, Payment or synchronous Journal is created here.

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909153000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: receipt Finance mapping required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909154000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909154000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('public.dispatch_backoffice_sales_delivery(uuid,bigint,uuid,jsonb,text)') IS NULL
    OR to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Dispatch dependency missing';
  END IF;
END
$guard$;

ALTER TYPE public.stock_movement_type ADD VALUE IF NOT EXISTS 'BACKOFFICE_SALE';

BEGIN;

CREATE FUNCTION private.receive_backoffice_sales_delivery_core(
  p_delivery_order_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_accepted_date date,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
  v_order public.backoffice_sales_orders%rowtype;
  v_reservation public.backoffice_sales_reservations%rowtype;
  v_existing public.backoffice_sales_delivery_receipts%rowtype;
  v_company_today date;v_timezone text;v_departed_date date;
  v_receipt_id uuid:=gen_random_uuid();v_event_id uuid:=gen_random_uuid();
  v_receipt_no text;v_request jsonb;v_result jsonb;v_now timestamptz:=clock_timestamp();
  v_total_qty numeric(24,6);v_total_cost numeric(24,4);v_exact_batch_qty numeric(24,6);
  v_category uuid;v_category_count bigint;v_rule_version bigint;v_rule_count bigint;
  v_line record;v_batch record;v_remaining numeric(24,6);v_take numeric(24,6);
  v_line_cost numeric(24,4);v_stock_before numeric(24,6);
  v_receipt_line_id uuid;v_movement_id uuid;
  v_base_uom_id uuid;v_base_uom_name text;v_base_uom_count bigint;
  v_reservation_status text;v_open_delivery_count bigint;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_delivery_order_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_DELIVERY_REQUIRED'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN RAISE EXCEPTION 'MASTER_VERSION_REQUIRED'; END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_accepted_date IS NULL THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_REQUIRED'; END IF;
  IF length(COALESCE(p_notes,''))>500 THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_NOTES_TOO_LONG'; END IF;

  v_request:=jsonb_build_object('deliveryOrderId',p_delivery_order_id,
    'acceptedDate',p_accepted_date,'notes',NULLIF(btrim(p_notes),''));
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
  IF v_delivery.status<>'IN_TRANSIT' OR v_delivery.total_shipped_base_qty<>v_delivery.total_planned_base_qty
    OR v_delivery.total_received_base_qty<>0 OR v_delivery.departed_at IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_NOT_RECEIVABLE';
  END IF;
  v_departed_date:=(v_delivery.departed_at AT TIME ZONE v_timezone)::date;
  IF p_accepted_date<v_departed_date THEN RAISE EXCEPTION 'CUSTOMER_RECEIPT_DATE_BEFORE_DISPATCH'; END IF;

  SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=v_delivery.sales_order_id FOR UPDATE;
  SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id
    AND reservation.sales_order_id=v_delivery.sales_order_id FOR UPDATE;
  IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status<>'IN_TRANSIT'
    OR v_reservation.status<>'PARTIALLY_FULFILLED' THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_ORDER_STATE_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_receipts receipt
    WHERE receipt.company_id=v_company AND receipt.delivery_order_id=v_delivery.id) THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_ALREADY_RECEIVED';
  END IF;

  PERFORM 1 FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id
  ORDER BY line.line_no FOR UPDATE;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id
      AND (line.shipped_base_qty<>line.planned_base_qty OR line.received_base_qty<>0)) THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_LINE_STATE_INVALID';
  END IF;

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

  SELECT COALESCE(sum(line.shipped_base_qty),0) INTO v_total_qty
  FROM public.backoffice_sales_delivery_order_lines line
  WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id;
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
  SELECT COALESCE(sum(batch.qty_remaining),0),
    COALESCE(sum(round(batch.qty_remaining*batch.cogs_unit,4)),0)
  INTO v_exact_batch_qty,v_total_cost
  FROM (SELECT DISTINCT destination.id,destination.qty_remaining,destination.cogs_unit
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
      AND destination.warehouse_id=(SELECT dispatch.transit_warehouse_id
        FROM public.backoffice_sales_delivery_dispatches dispatch
        WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
        ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1)
    ) batch;
  IF v_total_qty<=0 OR v_exact_batch_qty<>v_total_qty THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_FIFO_INSUFFICIENT';
  END IF;

  SELECT dispatch.transit_warehouse_id INTO STRICT v_existing.transit_warehouse_id
  FROM public.backoffice_sales_delivery_dispatches dispatch
  WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
  ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_dispatches dispatch
    WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
      AND dispatch.transit_warehouse_id<>v_existing.transit_warehouse_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_WAREHOUSE_MISMATCH';
  END IF;

  v_receipt_no:='BCR-'||to_char(p_accepted_date,'YYYYMMDD')||'-'
    ||upper(substr(replace(v_receipt_id::text,'-',''),1,12));
  v_result:=jsonb_build_object('receiptId',v_receipt_id,'receiptNo',v_receipt_no,
    'deliveryOrderId',v_delivery.id,'deliveryNo',v_delivery.delivery_no,
    'deliveryStatus','COMPLETED','masterVersion',v_delivery.master_version+1,
    'acceptedDate',p_accepted_date,'receivedBaseQty',v_total_qty,
    'fifoCostTotal',v_total_cost,'financialEventId',v_event_id,
    'financialEventStatus','HOLD','exactRetry',false);

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

  INSERT INTO public.backoffice_sales_delivery_receipts(id,company_id,receipt_no,
    delivery_order_id,sales_order_id,reservation_id,operation_id,request_payload,
    result_payload,transit_warehouse_id,accepted_date,total_received_base_qty,
    total_fifo_cost,financial_event_id,notes,accepted_by,accepted_at)
  VALUES(v_receipt_id,v_company,v_receipt_no,v_delivery.id,v_delivery.sales_order_id,
    v_delivery.reservation_id,p_operation_id,v_request,v_result,
    v_existing.transit_warehouse_id,p_accepted_date,v_total_qty,v_total_cost,
    v_event_id,NULLIF(btrim(p_notes),''),v_actor,v_now);

  FOR v_line IN SELECT line.* FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=v_company AND line.delivery_order_id=v_delivery.id
    ORDER BY line.line_no
  LOOP
    v_remaining:=v_line.shipped_base_qty;v_line_cost:=0;
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
      AND stock.warehouse_id=v_existing.transit_warehouse_id FOR UPDATE;
    IF NOT FOUND OR v_stock_before<v_remaining THEN
      RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_STOCK_INSUFFICIENT';
    END IF;
    v_receipt_line_id:=gen_random_uuid();v_movement_id:=gen_random_uuid();
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
        AND destination.warehouse_id=v_existing.transit_warehouse_id
        AND destination.qty_remaining>0
      ORDER BY destination.created_at,destination.id FOR UPDATE OF destination
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=LEAST(v_remaining,v_batch.qty_remaining);
      v_line_cost:=v_line_cost+round(v_take*v_batch.cogs_unit,4);
      v_remaining:=v_remaining-v_take;
    END LOOP;
    IF v_remaining<>0 THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_FIFO_INSUFFICIENT'; END IF;

    UPDATE public.product_stocks SET stock_qty=stock_qty-v_line.shipped_base_qty,
      updated_at=v_now WHERE company_id=v_company AND product_id=v_line.product_id
      AND warehouse_id=v_existing.transit_warehouse_id
      AND stock_qty>=v_line.shipped_base_qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_TRANSIT_STOCK_INSUFFICIENT'; END IF;
    INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_movement_id,v_line.product_id,v_existing.transit_warehouse_id,
      -v_line.shipped_base_qty,'BACKOFFICE_SALE'::public.stock_movement_type,
      'backoffice_sales_delivery_receipts',v_receipt_id,v_company,v_base_uom_id,
      v_base_uom_name,v_stock_before-v_line.shipped_base_qty,v_actor,v_now,
      'POSTED',v_receipt_line_id,NULLIF(btrim(p_notes),''));
    INSERT INTO public.backoffice_sales_delivery_receipt_lines(id,company_id,
      receipt_id,delivery_order_id,sales_order_id,reservation_id,reservation_line_id,
      delivery_order_line_id,sales_order_line_id,product_id,uom_id,received_qty_uom,
      received_base_qty,fifo_cost_total,stock_movement_id)
    VALUES(v_receipt_line_id,v_company,v_receipt_id,v_delivery.id,
      v_delivery.sales_order_id,v_delivery.reservation_id,v_line.reservation_line_id,
      v_line.id,v_line.sales_order_line_id,v_line.product_id,v_line.uom_id,
      v_line.shipped_base_qty/v_line.base_qty_per_uom,v_line.shipped_base_qty,
      v_line_cost,v_movement_id);
    v_remaining:=v_line.shipped_base_qty;
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
        AND destination.warehouse_id=v_existing.transit_warehouse_id
        AND destination.qty_remaining>0
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
  IF round((SELECT sum(line.fifo_cost_total) FROM public.backoffice_sales_delivery_receipt_lines line
    WHERE line.company_id=v_company AND line.receipt_id=v_receipt_id),4)<>round(v_total_cost,4) THEN
    RAISE EXCEPTION 'BACKOFFICE_RECEIPT_COST_RECONCILIATION_FAILED';
  END IF;

  UPDATE public.backoffice_sales_delivery_order_lines SET
    received_base_qty=shipped_base_qty,updated_at=v_now
  WHERE company_id=v_company AND delivery_order_id=v_delivery.id;
  UPDATE public.backoffice_sales_reservation_lines reservation_line SET
    in_transit_base_qty=reservation_line.in_transit_base_qty-receipt_line.received_base_qty,
    completed_base_qty=reservation_line.completed_base_qty+receipt_line.received_base_qty,
    updated_at=v_now
  FROM public.backoffice_sales_delivery_receipt_lines receipt_line
  WHERE receipt_line.company_id=v_company AND receipt_line.receipt_id=v_receipt_id
    AND reservation_line.company_id=receipt_line.company_id
    AND reservation_line.id=receipt_line.reservation_line_id
    AND reservation_line.in_transit_base_qty>=receipt_line.received_base_qty;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_RECEIPT_RESERVATION_CHANGED'; END IF;
  UPDATE public.backoffice_sales_order_lines order_line SET
    accepted_base_qty=order_line.accepted_base_qty+receipt_line.received_base_qty,
    updated_at=v_now
  FROM public.backoffice_sales_delivery_receipt_lines receipt_line
  WHERE receipt_line.company_id=v_company AND receipt_line.receipt_id=v_receipt_id
    AND order_line.company_id=receipt_line.company_id
    AND order_line.id=receipt_line.sales_order_line_id;

  UPDATE public.backoffice_sales_delivery_orders SET status='COMPLETED',
    total_received_base_qty=total_shipped_base_qty,completed_by=v_actor,
    completed_at=v_now,master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery.id;
  UPDATE public.backoffice_sales_reservations SET
    total_in_transit_base_qty=(SELECT sum(line.in_transit_base_qty)
      FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id),
    total_completed_base_qty=(SELECT sum(line.completed_base_qty)
      FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id),
    status=CASE WHEN NOT EXISTS(SELECT 1 FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id
        AND line.released_base_qty+line.completed_base_qty<line.reserved_base_qty)
      THEN 'FULFILLED' ELSE 'PARTIALLY_FULFILLED' END,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_reservation.id RETURNING status INTO v_reservation_status;
  SELECT count(*) INTO v_open_delivery_count FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.sales_order_id=v_delivery.sales_order_id
    AND delivery.status NOT IN('COMPLETED','CANCELED');
  UPDATE public.backoffice_sales_orders SET fulfillment_status=CASE
      WHEN v_reservation_status='FULFILLED' AND v_open_delivery_count=0 THEN 'COMPLETED'
      ELSE 'IN_TRANSIT' END,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery.sales_order_id;
  INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,
    delivery_order_id,operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,v_delivery.sales_order_id,v_delivery.id,p_operation_id,'COMPLETE',
    v_actor,NULLIF(btrim(p_notes),''),jsonb_build_object('status',v_delivery.status,
      'masterVersion',v_delivery.master_version,'totalReceivedBaseQty',0),v_result);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.receive_backoffice_sales_delivery(
  p_delivery_order_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_accepted_date date,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.receive_backoffice_sales_delivery_core(p_delivery_order_id,
    p_expected_version,p_operation_id,p_accepted_date,p_notes);
END
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_backoffice_delivery_orders(
  p_date_from date,p_date_to date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
  v_operations_ready boolean;v_timezone text;v_company_today date;
BEGIN
  PERFORM private.acp_require_permission_capability(v_company,
    'inventory.delivery_documents','VIEW');
  SELECT company.timezone,(clock_timestamp() AT TIME ZONE company.timezone)::date
  INTO v_timezone,v_company_today FROM public.companies company
  WHERE company.id=v_company AND company.status='ACTIVE';
  IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
  v_operations_ready:=public.private_stock_transfer_operator_allowed(v_company);
  IF p_date_from IS NOT NULL AND p_date_to IS NOT NULL AND p_date_from>p_date_to THEN
    RAISE EXCEPTION 'INVALID_DELIVERY_DATE_RANGE';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'workspaceVersion',3,
    'companyDate',v_company_today,'operationsReady',v_operations_ready,
    'dateFrom',p_date_from,'dateTo',p_date_to,
    'data',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'sourceChannel','BACKOFFICE_SALES','salesId',delivery.sales_order_id,
      'salesOrderNo',document.order_no,'deliveryDocumentId',delivery.id,
      'deliveryNo',delivery.delivery_no,'deliveryKind',delivery.delivery_kind,
      'status',delivery.status,'masterVersion',delivery.master_version,
      'invoiceNo',NULL,'createdAt',delivery.created_at,'scheduledAt',delivery.scheduled_date,
      'recipientName',COALESCE(delivery.recipient_snapshot->>'name',
        document.customer_snapshot->>'name','Pelanggan Umum'),
      'recipientPhone',COALESCE(delivery.recipient_snapshot->>'phone',
        document.customer_snapshot->>'phone'),
      'deliveryAddress',COALESCE(delivery.recipient_snapshot->>'address',
        document.customer_snapshot->>'address'),
      'customerName',COALESCE(document.customer_snapshot->>'name','Pelanggan Umum'),
      'storeName',COALESCE(store.store_name,'-'),'warehouseName',warehouse.name,
      'fulfillmentMode','DELIVERY','reservationId',delivery.reservation_id,
      'reservationStatus',reservation.status,
      'totalReservedBaseQty',reservation.total_reserved_base_qty,
      'totalDispatchedBaseQty',delivery.total_shipped_base_qty,
      'totalReceivedBaseQty',delivery.total_received_base_qty,
      'operationsReady',v_operations_ready,'receiptReady',delivery.status='IN_TRANSIT'
        AND delivery.total_shipped_base_qty=delivery.total_planned_base_qty,
      'acceptedDate',receipt.accepted_date,'receiptNo',receipt.receipt_no,
      'receiptFinancialStatus',event.status)
      ORDER BY delivery.scheduled_date DESC,delivery.created_at DESC,delivery.id)
    FROM (SELECT candidate.* FROM public.backoffice_sales_delivery_orders candidate
      WHERE candidate.company_id=v_company
        AND (p_date_from IS NULL OR candidate.scheduled_date>=p_date_from)
        AND (p_date_to IS NULL OR candidate.scheduled_date<=p_date_to)
      ORDER BY candidate.scheduled_date DESC,candidate.created_at DESC,candidate.id LIMIT 500) delivery
    JOIN public.backoffice_sales_orders document ON document.company_id=delivery.company_id
      AND document.id=delivery.sales_order_id
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=delivery.company_id AND reservation.id=delivery.reservation_id
    LEFT JOIN public.stores store ON store.company_id=document.company_id AND store.id=document.store_id
    JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
      AND warehouse.id=document.warehouse_id
    LEFT JOIN public.backoffice_sales_delivery_receipts receipt
      ON receipt.company_id=delivery.company_id AND receipt.delivery_order_id=delivery.id
    LEFT JOIN public.financial_events event ON event.company_id=receipt.company_id
      AND event.id=receipt.financial_event_id),'[]'::jsonb),
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',line.id,
      'delivery_document_id',line.delivery_order_id,'line_no',line.line_no,
      'product_id',line.product_id,'product_sku_snapshot',line.product_code_snapshot,
      'product_name_snapshot',line.product_name_snapshot,'sale_uom_id',line.uom_id,
      'sale_uom_name_snapshot',line.uom_name_snapshot,'quantity_uom',line.planned_qty_uom,
      'quantity_base',line.planned_base_qty,'remaining_quantity_uom',GREATEST(
        line.planned_base_qty-line.shipped_base_qty,0)/line.base_qty_per_uom,
      'shipped_base_qty',line.shipped_base_qty,'received_base_qty',line.received_base_qty)
      ORDER BY line.delivery_order_id,line.line_no)
    FROM public.backoffice_sales_delivery_order_lines line
    JOIN public.backoffice_sales_delivery_orders delivery ON delivery.company_id=line.company_id
      AND delivery.id=line.delivery_order_id
    WHERE line.company_id=v_company
      AND (p_date_from IS NULL OR delivery.scheduled_date>=p_date_from)
      AND (p_date_to IS NULL OR delivery.scheduled_date<=p_date_to)),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION
  private.receive_backoffice_sales_delivery_core(uuid,bigint,uuid,date,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.receive_backoffice_sales_delivery_core(uuid,bigint,uuid,date,text)
TO service_role;
REVOKE ALL ON FUNCTION public.receive_backoffice_sales_delivery(
  uuid,bigint,uuid,date,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.receive_backoffice_sales_delivery(
  uuid,bigint,uuid,date,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909154000','backoffice_sales_customer_receipt_runtime',
  'Atomic clean receipt consumes only exact DO outbound Transit FIFO, completes Reservation/SO, opens Qty To Invoice and creates COGS Financial Event HOLD; no Invoice, Revenue/AR or synchronous Journal');

NOTIFY pgrst,'reload schema';
COMMIT;
