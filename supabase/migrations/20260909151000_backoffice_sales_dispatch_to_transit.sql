-- Atomic Backoffice Delivery dispatch from the operational Warehouse to its
-- dedicated SALES_DELIVERY_OUTBOUND Transit Warehouse.
-- Reuses the canonical Stock Transfer FIFO/Movement core. Customer receipt,
-- sale-out, Invoice, Revenue/AR, Payment and Finance remain out of scope.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Transit usage foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260909151000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909151000';
  END IF;
  IF to_regprocedure('private.resolve_or_create_warehouse_transit(uuid,uuid,text,uuid)') IS NULL
    OR to_regprocedure('private.save_stock_transfer_document(uuid,bigint,uuid,uuid,date,text,jsonb)') IS NULL
    OR to_regprocedure('private.post_stock_transfer(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.acp_require_permission_capability(uuid,text,text)') IS NULL
    OR to_regprocedure('public.get_inventory_backoffice_delivery_orders(date,date)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Dispatch dependency missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_sales_delivery_dispatches') IS NOT NULL
    OR to_regclass('public.backoffice_sales_delivery_dispatch_lines') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Dispatch relation collision';
  END IF;
END
$guard$;

CREATE TABLE public.backoffice_sales_delivery_dispatches(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  delivery_order_id uuid NOT NULL,
  sales_order_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  request_payload jsonb NOT NULL,
  stock_transfer_document_id uuid NOT NULL,
  source_warehouse_id uuid NOT NULL,
  transit_warehouse_id uuid NOT NULL,
  total_base_qty numeric(24,6) NOT NULL,
  total_cost numeric(24,4) NOT NULL,
  result_payload jsonb NOT NULL,
  notes text,
  dispatched_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  dispatched_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_delivery_dispatches_company_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_dispatches_operation_unique
    UNIQUE(company_id,operation_id),
  CONSTRAINT backoffice_sales_delivery_dispatches_transfer_unique
    UNIQUE(company_id,stock_transfer_document_id),
  CONSTRAINT backoffice_sales_delivery_dispatches_delivery_fk
    FOREIGN KEY(company_id,sales_order_id,delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatches_reservation_fk
    FOREIGN KEY(company_id,reservation_id,sales_order_id)
    REFERENCES public.backoffice_sales_reservations(company_id,id,sales_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatches_transfer_fk
    FOREIGN KEY(company_id,stock_transfer_document_id)
    REFERENCES public.stock_transfer_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatches_source_fk
    FOREIGN KEY(company_id,source_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatches_transit_fk
    FOREIGN KEY(company_id,transit_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatches_shape_check CHECK(
    jsonb_typeof(request_payload)='object'
    AND jsonb_typeof(result_payload)='object'
    AND source_warehouse_id<>transit_warehouse_id
    AND total_base_qty>0 AND total_cost>=0)
);

CREATE TABLE public.backoffice_sales_delivery_dispatch_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  dispatch_id uuid NOT NULL,
  delivery_order_line_id uuid NOT NULL,
  reservation_line_id uuid NOT NULL,
  stock_transfer_line_id uuid NOT NULL,
  product_id uuid NOT NULL,
  quantity_uom numeric(24,6) NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_company_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_source_unique
    UNIQUE(company_id,dispatch_id,delivery_order_line_id),
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_dispatch_fk
    FOREIGN KEY(company_id,dispatch_id)
    REFERENCES public.backoffice_sales_delivery_dispatches(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_delivery_line_fk
    FOREIGN KEY(company_id,delivery_order_line_id)
    REFERENCES public.backoffice_sales_delivery_order_lines(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_reservation_line_fk
    FOREIGN KEY(company_id,reservation_line_id)
    REFERENCES public.backoffice_sales_reservation_lines(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_transfer_line_fk
    FOREIGN KEY(company_id,stock_transfer_line_id)
    REFERENCES public.stock_transfer_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_delivery_dispatch_lines_quantity_check CHECK(
    quantity_uom>0 AND quantity_base>0)
);

CREATE INDEX backoffice_sales_delivery_dispatches_delivery_date
  ON public.backoffice_sales_delivery_dispatches(
    company_id,delivery_order_id,dispatched_at,id);
CREATE INDEX backoffice_sales_delivery_dispatch_lines_delivery_line
  ON public.backoffice_sales_delivery_dispatch_lines(
    company_id,delivery_order_line_id,created_at,id);

CREATE FUNCTION private.trg_guard_backoffice_sales_delivery_dispatch()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RAISE EXCEPTION 'BACKOFFICE_SALES_DELIVERY_DISPATCH_IMMUTABLE';
END
$$;

CREATE TRIGGER backoffice_sales_delivery_dispatches_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_delivery_dispatches
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_delivery_dispatch();
CREATE TRIGGER backoffice_sales_delivery_dispatch_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_delivery_dispatch_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_delivery_dispatch();

ALTER TABLE public.backoffice_sales_delivery_dispatches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_delivery_dispatch_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.backoffice_sales_delivery_dispatches,
  public.backoffice_sales_delivery_dispatch_lines FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.backoffice_sales_delivery_dispatches,
  public.backoffice_sales_delivery_dispatch_lines TO service_role;

CREATE FUNCTION private.dispatch_backoffice_sales_delivery_to_transit(
  p_delivery_order_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
  v_order public.backoffice_sales_orders%rowtype;
  v_reservation public.backoffice_sales_reservations%rowtype;
  v_existing public.backoffice_sales_delivery_dispatches%rowtype;
  v_dispatch_id uuid:=gen_random_uuid();v_transit uuid;v_transfer jsonb;v_posted jsonb;
  v_transfer_id uuid;v_transfer_version bigint;v_request jsonb;v_result jsonb;
  v_transfer_lines jsonb;
  v_line_count integer;v_distinct_count integer;v_total numeric(24,6);
  v_total_shipped numeric(24,6);v_delivery_status text;v_now timestamptz:=clock_timestamp();
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_delivery_order_id IS NULL THEN RAISE EXCEPTION 'BACKOFFICE_DELIVERY_REQUIRED'; END IF;
  IF p_expected_version IS NULL OR p_expected_version<1 THEN
    RAISE EXCEPTION 'MASTER_VERSION_REQUIRED';
  END IF;
  IF p_operation_id IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines)<>'array'
    OR jsonb_array_length(p_lines)=0 OR jsonb_array_length(p_lines)>500 THEN
    RAISE EXCEPTION 'DISPATCH_LINES_INVALID';
  END IF;
  IF length(COALESCE(p_notes,''))>500 THEN RAISE EXCEPTION 'DISPATCH_NOTES_TOO_LONG'; END IF;

  SELECT count(*),count(DISTINCT requested.delivery_line_id),
    jsonb_build_object('deliveryOrderId',p_delivery_order_id,
      'lines',jsonb_agg(jsonb_build_object('deliveryLineId',requested.delivery_line_id,
        'quantityUom',requested.quantity_uom) ORDER BY requested.delivery_line_id),
      'notes',NULLIF(btrim(p_notes),''))
  INTO v_line_count,v_distinct_count,v_request
  FROM (SELECT (item->>'deliveryLineId')::uuid delivery_line_id,
      (item->>'quantityUom')::numeric quantity_uom
    FROM jsonb_array_elements(p_lines) item) requested;
  IF v_line_count<>jsonb_array_length(p_lines) OR v_distinct_count<>v_line_count
    OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) item
      WHERE (item->>'deliveryLineId') IS NULL OR (item->>'quantityUom') IS NULL
        OR (item->>'quantityUom')::numeric<=0) THEN
    RAISE EXCEPTION 'DISPATCH_LINES_INVALID';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    v_company::text||':BACKOFFICE_DELIVERY_DISPATCH:'||p_operation_id::text,0));
  SELECT * INTO v_existing FROM public.backoffice_sales_delivery_dispatches dispatch
  WHERE dispatch.company_id=v_company AND dispatch.operation_id=p_operation_id;
  IF FOUND THEN
    IF v_existing.request_payload IS DISTINCT FROM v_request THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN v_existing.result_payload||jsonb_build_object('exactRetry',true);
  END IF;

  SELECT * INTO v_delivery FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_DELIVERY_NOT_FOUND'; END IF;
  IF v_delivery.status NOT IN('READY','PARTIALLY_SHIPPED') THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_NOT_DISPATCHABLE';
  END IF;
  IF v_delivery.master_version<>p_expected_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=v_delivery.sales_order_id FOR UPDATE;
  SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id
    AND reservation.sales_order_id=v_delivery.sales_order_id FOR UPDATE;
  IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status NOT IN(
      'PREPARING','PARTIALLY_SHIPPED') OR v_reservation.status='RELEASED'
    OR v_reservation.warehouse_id<>v_order.warehouse_id THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_ORDER_STATE_INVALID';
  END IF;
  IF NOT public.private_stock_transfer_operator_allowed(v_company) THEN
    RAISE EXCEPTION 'STOCK_TRANSFER_OPERATOR_REQUIRED';
  END IF;

  IF EXISTS(
    SELECT 1 FROM (SELECT (item->>'deliveryLineId')::uuid delivery_line_id,
        (item->>'quantityUom')::numeric quantity_uom
      FROM jsonb_array_elements(p_lines) item) requested
    LEFT JOIN public.backoffice_sales_delivery_order_lines line
      ON line.company_id=v_company AND line.delivery_order_id=v_delivery.id
     AND line.id=requested.delivery_line_id
    WHERE line.id IS NULL OR requested.quantity_uom*line.base_qty_per_uom>
      line.planned_base_qty-line.shipped_base_qty) THEN
    RAISE EXCEPTION 'DISPATCH_QUANTITY_EXCEEDS_REMAINING';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('productId',grouped.product_id,
      'quantityBase',grouped.quantity_base,'notes','Delivery '||v_delivery.delivery_no)
      ORDER BY grouped.product_id),'[]'::jsonb),COALESCE(sum(grouped.quantity_base),0)
  INTO v_transfer_lines,v_total
  FROM (SELECT line.product_id,
      round(sum(requested.quantity_uom*line.base_qty_per_uom),6) quantity_base
    FROM (SELECT (item->>'deliveryLineId')::uuid delivery_line_id,
        (item->>'quantityUom')::numeric quantity_uom
      FROM jsonb_array_elements(p_lines) item) requested
    JOIN public.backoffice_sales_delivery_order_lines line
      ON line.company_id=v_company AND line.delivery_order_id=v_delivery.id
     AND line.id=requested.delivery_line_id
    GROUP BY line.product_id) grouped;
  IF v_total<=0 THEN RAISE EXCEPTION 'DISPATCH_EMPTY'; END IF;

  v_transit:=private.resolve_or_create_warehouse_transit(v_company,
    v_reservation.warehouse_id,'SALES_DELIVERY_OUTBOUND',v_actor);
  v_transfer:=private.save_stock_transfer_document(NULL,NULL,
    v_reservation.warehouse_id,v_transit,current_date,
    'Backoffice Delivery '||v_delivery.delivery_no||COALESCE(' - '||NULLIF(btrim(p_notes),''),''),
    v_transfer_lines);
  v_transfer_id:=(v_transfer->>'documentId')::uuid;
  v_transfer_version:=(v_transfer->>'masterVersion')::bigint;
  v_posted:=private.post_stock_transfer(v_transfer_id,v_transfer_version,p_operation_id);

  v_total_shipped:=v_delivery.total_shipped_base_qty+v_total;
  IF v_total_shipped<v_delivery.total_planned_base_qty THEN
    v_delivery_status:='PARTIALLY_SHIPPED';
  ELSIF v_total_shipped=v_delivery.total_planned_base_qty THEN
    v_delivery_status:='IN_TRANSIT';
  ELSE
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_SHIPPED_TOTAL_INVALID';
  END IF;
  v_result:=jsonb_build_object('deliveryOrderId',v_delivery.id,
    'deliveryNo',v_delivery.delivery_no,'deliveryStatus',v_delivery_status,
    'masterVersion',v_delivery.master_version+1,'dispatchId',v_dispatch_id,
    'stockTransferDocumentId',v_transfer_id,'transitWarehouseId',v_transit,
    'dispatchedBaseQty',v_total,'totalShippedBaseQty',v_total_shipped,
    'totalCost',(v_posted->>'totalCost')::numeric,'exactRetry',false);

  INSERT INTO public.backoffice_sales_delivery_dispatches(
    id,company_id,delivery_order_id,sales_order_id,reservation_id,operation_id,
    request_payload,stock_transfer_document_id,source_warehouse_id,
    transit_warehouse_id,total_base_qty,total_cost,result_payload,notes,
    dispatched_by,dispatched_at)
  VALUES(v_dispatch_id,v_company,v_delivery.id,v_delivery.sales_order_id,
    v_delivery.reservation_id,p_operation_id,v_request,v_transfer_id,
    v_reservation.warehouse_id,v_transit,v_total,(v_posted->>'totalCost')::numeric,
    v_result,NULLIF(btrim(p_notes),''),v_actor,v_now);

  INSERT INTO public.backoffice_sales_delivery_dispatch_lines(
    company_id,dispatch_id,delivery_order_line_id,reservation_line_id,
    stock_transfer_line_id,product_id,quantity_uom,quantity_base)
  SELECT v_company,v_dispatch_id,line.id,line.reservation_line_id,transfer_line.id,
    line.product_id,requested.quantity_uom,
    round(requested.quantity_uom*line.base_qty_per_uom,6)
  FROM (SELECT (item->>'deliveryLineId')::uuid delivery_line_id,
      (item->>'quantityUom')::numeric quantity_uom
    FROM jsonb_array_elements(p_lines) item) requested
  JOIN public.backoffice_sales_delivery_order_lines line
    ON line.company_id=v_company AND line.delivery_order_id=v_delivery.id
   AND line.id=requested.delivery_line_id
  JOIN public.stock_transfer_lines transfer_line
    ON transfer_line.company_id=v_company AND transfer_line.document_id=v_transfer_id
   AND transfer_line.product_id=line.product_id;

  UPDATE public.backoffice_sales_delivery_order_lines line SET
    shipped_base_qty=line.shipped_base_qty+dispatch_line.quantity_base,
    updated_at=v_now
  FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
  WHERE dispatch_line.company_id=v_company AND dispatch_line.dispatch_id=v_dispatch_id
    AND line.company_id=dispatch_line.company_id
    AND line.id=dispatch_line.delivery_order_line_id;
  UPDATE public.backoffice_sales_reservation_lines reservation_line SET
    in_transit_base_qty=reservation_line.in_transit_base_qty+dispatch_line.quantity_base,
    updated_at=v_now
  FROM public.backoffice_sales_delivery_dispatch_lines dispatch_line
  WHERE dispatch_line.company_id=v_company AND dispatch_line.dispatch_id=v_dispatch_id
    AND reservation_line.company_id=dispatch_line.company_id
    AND reservation_line.id=dispatch_line.reservation_line_id;

  UPDATE public.backoffice_sales_delivery_orders SET
    status=v_delivery_status,total_shipped_base_qty=v_total_shipped,
    departed_by=COALESCE(departed_by,v_actor),departed_at=COALESCE(departed_at,v_now),
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery.id;
  UPDATE public.backoffice_sales_reservations SET
    status='PARTIALLY_FULFILLED',
    total_in_transit_base_qty=(SELECT sum(line.in_transit_base_qty)
      FROM public.backoffice_sales_reservation_lines line
      WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id),
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_reservation.id;
  UPDATE public.backoffice_sales_orders SET fulfillment_status=v_delivery_status,
    updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery.sales_order_id;

  INSERT INTO public.backoffice_sales_fulfillment_audit(
    company_id,sales_order_id,delivery_order_id,operation_id,action,actor_id,
    reason,before_state,after_state)
  VALUES(v_company,v_delivery.sales_order_id,v_delivery.id,p_operation_id,
    CASE WHEN v_delivery_status='IN_TRANSIT' THEN 'DEPART_FULL' ELSE 'DEPART_PARTIAL' END,
    v_actor,NULLIF(btrim(p_notes),''),
    jsonb_build_object('status',v_delivery.status,'masterVersion',v_delivery.master_version,
      'totalShippedBaseQty',v_delivery.total_shipped_base_qty),v_result);
  RETURN v_result;
END
$$;

CREATE FUNCTION public.dispatch_backoffice_sales_delivery(
  p_delivery_order_id uuid,p_expected_version bigint,p_operation_id uuid,
  p_lines jsonb,p_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.dispatch_backoffice_sales_delivery_to_transit(
    p_delivery_order_id,p_expected_version,p_operation_id,p_lines,p_notes);
END
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_backoffice_delivery_orders(
  p_date_from date,p_date_to date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();
  v_operations_ready boolean;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  v_operations_ready:=public.private_stock_transfer_operator_allowed(v_company);
  IF p_date_from IS NOT NULL AND p_date_to IS NOT NULL AND p_date_from>p_date_to THEN
    RAISE EXCEPTION 'INVALID_DELIVERY_DATE_RANGE';
  END IF;
  RETURN jsonb_build_object('companyId',v_company,'workspaceVersion',2,
    'operationsReady',v_operations_ready,'dateFrom',p_date_from,'dateTo',p_date_to,
    'data',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'sourceChannel','BACKOFFICE_SALES','salesId',delivery.sales_order_id,
      'salesOrderNo',document.order_no,'deliveryDocumentId',delivery.id,
      'deliveryNo',delivery.delivery_no,'deliveryKind',delivery.delivery_kind,
      'status',delivery.status,'masterVersion',delivery.master_version,
      'invoiceNo',NULL,'createdAt',delivery.created_at,
      'scheduledAt',delivery.scheduled_date,
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
      'operationsReady',v_operations_ready)
      ORDER BY delivery.scheduled_date DESC,delivery.created_at DESC,delivery.id)
    FROM (SELECT candidate.* FROM public.backoffice_sales_delivery_orders candidate
      WHERE candidate.company_id=v_company
        AND (p_date_from IS NULL OR candidate.scheduled_date>=p_date_from)
        AND (p_date_to IS NULL OR candidate.scheduled_date<=p_date_to)
      ORDER BY candidate.scheduled_date DESC,candidate.created_at DESC,candidate.id
      LIMIT 500) delivery
    JOIN public.backoffice_sales_orders document
      ON document.company_id=delivery.company_id AND document.id=delivery.sales_order_id
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=delivery.company_id AND reservation.id=delivery.reservation_id
    LEFT JOIN public.stores store ON store.company_id=document.company_id
      AND store.id=document.store_id
    JOIN public.warehouses warehouse ON warehouse.company_id=document.company_id
      AND warehouse.id=document.warehouse_id),'[]'::jsonb),
    'lines',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',line.id,'delivery_document_id',line.delivery_order_id,
      'line_no',line.line_no,'product_id',line.product_id,
      'product_sku_snapshot',line.product_code_snapshot,
      'product_name_snapshot',line.product_name_snapshot,
      'sale_uom_id',line.uom_id,'sale_uom_name_snapshot',line.uom_name_snapshot,
      'quantity_uom',line.planned_qty_uom,'quantity_base',line.planned_base_qty,
      'remaining_quantity_uom',GREATEST(
        line.planned_base_qty-line.shipped_base_qty,0)/line.base_qty_per_uom,
      'shipped_base_qty',line.shipped_base_qty,
      'received_base_qty',line.received_base_qty)
      ORDER BY line.delivery_order_id,line.line_no)
    FROM public.backoffice_sales_delivery_order_lines line
    JOIN public.backoffice_sales_delivery_orders delivery
      ON delivery.company_id=line.company_id AND delivery.id=line.delivery_order_id
    WHERE line.company_id=v_company
      AND (p_date_from IS NULL OR delivery.scheduled_date>=p_date_from)
      AND (p_date_to IS NULL OR delivery.scheduled_date<=p_date_to)),'[]'::jsonb));
END
$$;

REVOKE ALL ON FUNCTION private.trg_guard_backoffice_sales_delivery_dispatch(),
  private.dispatch_backoffice_sales_delivery_to_transit(uuid,bigint,uuid,jsonb,text)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_guard_backoffice_sales_delivery_dispatch(),
  private.dispatch_backoffice_sales_delivery_to_transit(uuid,bigint,uuid,jsonb,text)
TO service_role;
REVOKE ALL ON FUNCTION public.dispatch_backoffice_sales_delivery(
  uuid,bigint,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dispatch_backoffice_sales_delivery(
  uuid,bigint,uuid,jsonb,text) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909151000','backoffice_sales_dispatch_to_transit',
  'Atomic partial/full Backoffice Delivery dispatch reuses canonical Stock Transfer FIFO and Movement to dedicated outbound Transit; no customer receipt, sale-out, Invoice or Finance effect');

NOTIFY pgrst,'reload schema';
COMMIT;
