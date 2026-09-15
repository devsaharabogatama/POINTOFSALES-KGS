-- Pre-dispatch delta only: same SO/Reservation/DO identities, canonical pricing/stock.
-- No existing-row backfill. No Stock/FIFO/payment/session/Finance posting.
BEGIN;
DO $guard$
BEGIN
 IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915142000') THEN RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260915142000'; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260915141000')
 OR to_regprocedure('private.recompose_office_pre_dispatch_fulfillment(uuid,uuid)') IS NOT NULL
 OR to_regprocedure('private.validate_office_untouched_fulfillment(uuid,uuid)') IS NOT NULL
 OR to_regprocedure('private.save_office_order_before_pre_dispatch_delta(uuid,bigint,uuid,jsonb)') IS NOT NULL
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: pre-dispatch delta dependency/collision'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs WHERE status IN('PREVIEWED','APPROVED','PROCESSING'))
 OR EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION'))
 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance/offline queue'; END IF;
END $guard$;

CREATE FUNCTION private.validate_office_untouched_fulfillment(p_company_id uuid,p_order_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_order public.backoffice_sales_orders%rowtype;
 v_reservation public.backoffice_sales_reservations%rowtype;v_delivery public.backoffice_sales_delivery_orders%rowtype;
BEGIN
 IF auth.uid() IS NULL OR public.private_active_company_id() IS DISTINCT FROM p_company_id THEN
  RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_CONTEXT_INVALID'; END IF;
 SELECT * INTO STRICT v_order FROM public.backoffice_sales_orders WHERE company_id=p_company_id AND id=p_order_id FOR UPDATE;
 PERFORM 1 FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id ORDER BY id FOR UPDATE;
 IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status NOT IN('CONFIRMED','PREPARING')
 OR (SELECT count(*) FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id)<>1
 OR (SELECT count(*) FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id)<>1 THEN
  RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_FULFILLMENT_STATE_INVALID'; END IF;
 SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 IF v_reservation.status NOT IN('OPEN','PARTIALLY_ALLOCATED','ALLOCATED')
 OR v_reservation.total_released_base_qty<>0 OR v_reservation.total_in_transit_base_qty<>0
 OR v_reservation.total_completed_base_qty<>0 OR v_delivery.delivery_kind<>'INITIAL'
 OR v_delivery.status NOT IN('PREPARING','READY') OR v_delivery.total_shipped_base_qty<>0
 OR v_delivery.total_received_base_qty<>0 OR v_delivery.reservation_id<>v_reservation.id
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_dispatches WHERE company_id=p_company_id AND delivery_order_id=v_delivery.id)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_receipt_lines WHERE company_id=p_company_id AND sales_order_id=p_order_id)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines WHERE company_id=p_company_id AND sales_order_id=p_order_id)
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_invoice_lines WHERE company_id=p_company_id AND sales_order_id=p_order_id)
 THEN RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_DEPENDENCY_REQUIRES_CORRECTION'; END IF;
 PERFORM 1 FROM public.backoffice_sales_reservation_lines WHERE company_id=p_company_id AND reservation_id=v_reservation.id ORDER BY id FOR UPDATE;
 PERFORM 1 FROM public.backoffice_sales_delivery_order_lines WHERE company_id=p_company_id AND delivery_order_id=v_delivery.id ORDER BY id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.backoffice_sales_reservation_lines WHERE company_id=p_company_id AND reservation_id=v_reservation.id
   AND (released_base_qty<>0 OR in_transit_base_qty<>0 OR completed_base_qty<>0))
 OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_order_lines WHERE company_id=p_company_id AND delivery_order_id=v_delivery.id
   AND (shipped_base_qty<>0 OR received_base_qty<>0))
 THEN RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_DEPENDENCY_REQUIRES_CORRECTION'; END IF;
END $$;

CREATE OR REPLACE FUNCTION private.recompose_office_pre_dispatch_fulfillment(p_order_id uuid, p_confirm_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_order public.backoffice_sales_orders%rowtype;v_reservation uuid:=(SELECT id FROM public.backoffice_sales_reservations WHERE company_id=v_company AND sales_order_id=p_order_id);
  v_delivery uuid:=(SELECT id FROM public.backoffice_sales_delivery_orders WHERE company_id=v_company AND sales_order_id=p_order_id AND delivery_kind='INITIAL');v_delivery_audit_operation uuid:=gen_random_uuid();
  v_delivery_no text;v_now timestamptz:=clock_timestamp();v_warehouse_negative boolean;
  v_total numeric(24,6);v_shortage_total numeric(24,6):=0;v_line_count integer;
  v_product record;v_requirement record;v_on_hand numeric(24,6);
  v_pos_reserved numeric(24,6);v_backoffice_reserved numeric(24,6);
  v_available numeric(24,6);v_available_remaining numeric(24,6);
  v_line_available numeric(24,6);v_availability jsonb:='{}'::jsonb;
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  SELECT document.* INTO v_order FROM public.backoffice_sales_orders document
  WHERE document.company_id=v_company AND document.id=p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_NOT_FOUND'; END IF;
  IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status NOT IN('CONFIRMED','PREPARING')
    OR v_order.sales_origin<>'BACKOFFICE_SALES'
    OR v_order.sales_process_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_CONFIRM_FULFILLMENT_STATE_INVALID';
  END IF;
  IF NULLIF(current_setting('kgs.office_pre_dispatch_revision_order',true),'') IS DISTINCT FROM p_order_id::text
    OR v_reservation IS NULL OR v_delivery IS NULL
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_reservation_lines WHERE company_id=v_company AND reservation_id=v_reservation)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_order_lines WHERE company_id=v_company AND delivery_order_id=v_delivery) THEN
    RAISE EXCEPTION 'OFFICE_PRE_DISPATCH_RECOMPOSE_CONTEXT_INVALID';
  END IF;
  SELECT warehouse.allow_negative_stock INTO v_warehouse_negative
  FROM public.warehouses warehouse WHERE warehouse.company_id=v_company
    AND warehouse.id=v_order.warehouse_id AND warehouse.is_active
    AND warehouse.is_sale_source FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BACKOFFICE_SALES_WAREHOUSE_SCOPE_INVALID'; END IF;

  PERFORM 1 FROM public.backoffice_sales_order_lines line
  WHERE line.company_id=v_company AND line.sales_order_id=p_order_id FOR SHARE;
  SELECT count(*),sum(requirement.quantity_base) INTO v_line_count,v_total
  FROM private.backoffice_sales_stock_requirements(v_company,p_order_id) requirement;
  IF v_line_count=0 OR v_total IS NULL OR v_total<=0 THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_STOCK_REQUIREMENT_MISSING';
  END IF;

  FOR v_product IN
    SELECT requirement.stock_product_id,sum(requirement.quantity_base) requested_base_qty
    FROM private.backoffice_sales_stock_requirements(v_company,p_order_id) requirement
    GROUP BY requirement.stock_product_id ORDER BY requirement.stock_product_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(
      v_company::text||':'||v_order.warehouse_id::text||':'||v_product.stock_product_id::text,0));
    SELECT stock.stock_qty INTO v_on_hand FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND stock.warehouse_id=v_order.warehouse_id
      AND stock.product_id=v_product.stock_product_id FOR UPDATE;
    v_on_hand:=COALESCE(v_on_hand,0);
    SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-line.dispatched_base_qty),0)
      INTO v_pos_reserved
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND line.warehouse_id=v_order.warehouse_id
      AND line.stock_product_id=v_product.stock_product_id
      AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED');
    SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-
      line.in_transit_base_qty-line.completed_base_qty),0) INTO v_backoffice_reserved
    FROM public.backoffice_sales_reservation_lines line
    JOIN public.backoffice_sales_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND line.warehouse_id=v_order.warehouse_id
      AND line.product_id=v_product.stock_product_id
      AND reservation.status<>'RELEASED';
    v_available:=v_on_hand-v_pos_reserved-v_backoffice_reserved;
    IF v_product.requested_base_qty>GREATEST(v_available,0) AND NOT v_warehouse_negative THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_NEGATIVE_RESERVATION_REQUIRES_WAREHOUSE_OPT_IN';
    END IF;
    v_shortage_total:=v_shortage_total+
      GREATEST(v_product.requested_base_qty-GREATEST(v_available,0),0);
    v_availability:=v_availability||jsonb_build_object(
      v_product.stock_product_id::text,GREATEST(v_available,0));
  END LOOP;

  UPDATE public.backoffice_sales_reservations SET warehouse_id=v_order.warehouse_id,
    total_ordered_base_qty=v_total,total_reserved_base_qty=v_total,shortage_base_qty=v_shortage_total,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_reservation;

  FOR v_requirement IN
    SELECT requirement.* FROM private.backoffice_sales_stock_requirements(v_company,p_order_id) requirement
    ORDER BY requirement.stock_product_id,requirement.sales_order_line_id,
      requirement.bundle_component_line_no NULLS FIRST
  LOOP
    v_available_remaining:=COALESCE((v_availability->>v_requirement.stock_product_id::text)::numeric,0);
    v_line_available:=LEAST(v_requirement.quantity_base,v_available_remaining);
    v_availability:=jsonb_set(v_availability,ARRAY[v_requirement.stock_product_id::text],
      to_jsonb(v_available_remaining-v_line_available),true);
    INSERT INTO public.backoffice_sales_reservation_lines(
      company_id,reservation_id,sales_order_id,sales_order_line_id,product_id,
      warehouse_id,ordered_base_qty,reserved_base_qty,stock_uom_id,
      stock_uom_name_snapshot,quantity_uom,factor_to_base,
      available_base_qty_snapshot,shortage_base_qty,bundle_component_line_no)
    VALUES(v_company,v_reservation,p_order_id,v_requirement.sales_order_line_id,
      v_requirement.stock_product_id,v_order.warehouse_id,v_requirement.quantity_base,
      v_requirement.quantity_base,v_requirement.stock_uom_id,v_requirement.stock_uom_name,
      v_requirement.quantity_uom,v_requirement.factor_to_base,v_line_available,
      v_requirement.quantity_base-v_line_available,v_requirement.bundle_component_line_no);
  END LOOP;

  UPDATE public.backoffice_sales_delivery_orders SET scheduled_date=v_order.planned_delivery_date,
    recipient_snapshot=v_order.customer_snapshot,total_planned_base_qty=v_total,
    master_version=master_version+1,updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=v_delivery RETURNING delivery_no INTO v_delivery_no;

  INSERT INTO public.backoffice_sales_delivery_order_lines(
    company_id,delivery_order_id,sales_order_id,reservation_id,reservation_line_id,
    sales_order_line_id,line_no,product_id,uom_id,product_code_snapshot,
    product_name_snapshot,uom_code_snapshot,uom_name_snapshot,base_qty_per_uom,
    planned_qty_uom,planned_base_qty)
  SELECT v_company,v_delivery,p_order_id,v_reservation,reservation_line.id,
    reservation_line.sales_order_line_id,
    row_number() OVER(ORDER BY order_line.line_no,
      reservation_line.bundle_component_line_no NULLS FIRST,reservation_line.id)::integer,
    reservation_line.product_id,reservation_line.stock_uom_id,product.sku,product.name,
    uom.code,reservation_line.stock_uom_name_snapshot,reservation_line.factor_to_base,
    reservation_line.quantity_uom,reservation_line.ordered_base_qty
  FROM public.backoffice_sales_reservation_lines reservation_line
  JOIN public.backoffice_sales_order_lines order_line
    ON order_line.company_id=reservation_line.company_id
   AND order_line.id=reservation_line.sales_order_line_id
  JOIN public.products product ON product.company_id=reservation_line.company_id
    AND product.id=reservation_line.product_id
  JOIN public.uoms uom ON uom.company_id=reservation_line.company_id
    AND uom.id=reservation_line.stock_uom_id
  WHERE reservation_line.company_id=v_company
    AND reservation_line.reservation_id=v_reservation;

  INSERT INTO public.backoffice_sales_fulfillment_audit(
    company_id,sales_order_id,reservation_id,operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,p_order_id,v_reservation,p_confirm_operation_id,'UPDATE_PLAN',v_actor,
    'Revisi SO sebelum pengiriman',
    current_setting('kgs.office_revision_before_reservation',true)::jsonb,
    jsonb_build_object('header',(SELECT to_jsonb(header) FROM public.backoffice_sales_reservations header WHERE id=v_reservation),
      'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE company_id=v_company AND reservation_id=v_reservation)));
  INSERT INTO public.backoffice_sales_fulfillment_audit(
    company_id,sales_order_id,delivery_order_id,operation_id,action,actor_id,reason,before_state,after_state)
  VALUES(v_company,p_order_id,v_delivery,v_delivery_audit_operation,'UPDATE_PLAN',v_actor,
    'Revisi SO sebelum pengiriman',
    current_setting('kgs.office_revision_before_delivery',true)::jsonb,
    jsonb_build_object('header',(SELECT to_jsonb(header) FROM public.backoffice_sales_delivery_orders header WHERE id=v_delivery),
      'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_delivery_order_lines line WHERE company_id=v_company AND delivery_order_id=v_delivery)));
  UPDATE public.backoffice_sales_orders SET fulfillment_status='PREPARING',
    updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=p_order_id;
  RETURN jsonb_build_object('reservationId',v_reservation,'deliveryOrderId',v_delivery,
    'deliveryNo',v_delivery_no,'deliveryStatus','READY','reservedBaseQty',v_total,
    'shortageBaseQty',v_shortage_total,'requirementLineCount',v_line_count);
END
$function$;


ALTER FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb)
 RENAME TO save_office_order_before_pre_dispatch_delta;
ALTER FUNCTION public.save_office_order_before_pre_dispatch_delta(uuid,bigint,uuid,jsonb) SET SCHEMA private;
CREATE FUNCTION public.save_backoffice_sales_order_draft(p_order_id uuid,p_expected_version bigint,p_operation_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp SET statement_timeout='15s' AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_order public.backoffice_sales_orders%rowtype;
 v_response jsonb;v_retry jsonb;v_hash text;
BEGIN
 PERFORM private.acp_require_permission_capability(v_company,'sales.backoffice_orders',
  CASE WHEN p_order_id IS NULL THEN 'CREATE_DRAFT' ELSE 'EDIT_DRAFT' END);
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text,20260911130000));
 PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':sales-process-cutover',0));
 IF p_operation_id IS NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_PAYLOAD_INVALID'; END IF;
 v_hash:=encode(extensions.digest(convert_to(jsonb_build_object('orderId',p_order_id,
  'expectedVersion',p_expected_version,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
 v_retry:=private.backoffice_operation_retry(v_company,p_operation_id,'SAVE_DRAFT',v_hash);
 IF v_retry IS NOT NULL THEN RETURN v_retry; END IF;
 SELECT * INTO v_order FROM public.backoffice_sales_orders WHERE company_id=v_company AND id=p_order_id FOR UPDATE;
 IF v_order.status='CONFIRMED' AND EXISTS(SELECT 1 FROM public.backoffice_sales_reservations WHERE company_id=v_company AND sales_order_id=p_order_id) THEN
  IF v_order.master_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  PERFORM private.validate_office_untouched_fulfillment(v_company,p_order_id);
  PERFORM set_config('kgs.office_revision_before_reservation',(SELECT jsonb_build_object(
   'header',to_jsonb(header),'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line
    WHERE line.company_id=v_company AND line.reservation_id=header.id))::text
   FROM public.backoffice_sales_reservations header WHERE company_id=v_company AND sales_order_id=p_order_id),true);
  PERFORM set_config('kgs.office_revision_before_delivery',(SELECT jsonb_build_object(
   'header',to_jsonb(header),'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_delivery_order_lines line
    WHERE line.company_id=v_company AND line.delivery_order_id=header.id))::text
   FROM public.backoffice_sales_delivery_orders header WHERE company_id=v_company AND sales_order_id=p_order_id),true);
  -- Only unconsumed mutable lines; snapshots are captured above and audited by recompose.
  DELETE FROM public.backoffice_sales_delivery_order_lines WHERE company_id=v_company AND sales_order_id=p_order_id;
  DELETE FROM public.backoffice_sales_reservation_lines WHERE company_id=v_company AND sales_order_id=p_order_id;
  PERFORM set_config('kgs.office_pre_dispatch_revision_order',p_order_id::text,true);
 END IF;
 v_response:=private.save_office_order_before_pre_dispatch_delta(p_order_id,p_expected_version,p_operation_id,p_payload);
 PERFORM set_config('kgs.office_pre_dispatch_revision_order','',true);
 PERFORM set_config('kgs.office_revision_before_reservation','',true);
 PERFORM set_config('kgs.office_revision_before_delivery','',true);
 RETURN v_response;
END $$;

CREATE FUNCTION private.release_office_untouched_fulfillment(p_company_id uuid,p_order_id uuid,p_operation_id uuid,p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_reservation public.backoffice_sales_reservations%rowtype;v_delivery public.backoffice_sales_delivery_orders%rowtype;
 v_before jsonb;v_after jsonb;v_actor uuid:=auth.uid();v_now timestamptz:=clock_timestamp();
BEGIN
 PERFORM private.validate_office_untouched_fulfillment(p_company_id,p_order_id);
 SELECT * INTO STRICT v_reservation FROM public.backoffice_sales_reservations WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders WHERE company_id=p_company_id AND sales_order_id=p_order_id;
 v_before:=jsonb_build_object('header',to_jsonb(v_reservation),'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE company_id=p_company_id AND reservation_id=v_reservation.id));
 UPDATE public.backoffice_sales_reservation_lines SET released_base_qty=reserved_base_qty,updated_at=v_now WHERE company_id=p_company_id AND reservation_id=v_reservation.id;
 UPDATE public.backoffice_sales_reservations SET status='RELEASED',total_released_base_qty=total_reserved_base_qty,
  released_by=v_actor,released_at=v_now,release_reason=p_reason,master_version=master_version+1,updated_by=v_actor,updated_at=v_now WHERE company_id=p_company_id AND id=v_reservation.id;
 v_after:=jsonb_build_object('header',(SELECT to_jsonb(header) FROM public.backoffice_sales_reservations header WHERE id=v_reservation.id),
  'lines',(SELECT jsonb_agg(to_jsonb(line) ORDER BY id) FROM public.backoffice_sales_reservation_lines line WHERE company_id=p_company_id AND reservation_id=v_reservation.id));
 INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,reservation_id,operation_id,action,actor_id,reason,before_state,after_state)
 VALUES(p_company_id,p_order_id,v_reservation.id,md5(p_operation_id::text||':RELEASE')::uuid,'RELEASE',v_actor,p_reason,v_before,v_after);
 UPDATE public.backoffice_sales_delivery_orders document SET status='CANCELED',canceled_by=v_actor,canceled_at=v_now,cancel_reason=p_reason,
  master_version=document.master_version+1,updated_by=v_actor,updated_at=v_now WHERE document.company_id=p_company_id AND document.id=v_delivery.id RETURNING to_jsonb(document) INTO v_after;
 INSERT INTO public.backoffice_sales_fulfillment_audit(company_id,sales_order_id,delivery_order_id,operation_id,action,actor_id,reason,before_state,after_state)
 VALUES(p_company_id,p_order_id,v_delivery.id,md5(p_operation_id::text||':CANCEL_DO')::uuid,'CANCEL',v_actor,p_reason,to_jsonb(v_delivery),v_after);
END $$;

DO $patch$
DECLARE v_definition text;v_marker text;
BEGIN
 v_definition:=pg_get_functiondef('public.save_backoffice_sales_order_draft_before_pricelist_header(uuid,bigint,uuid,jsonb)'::regprocedure);
 v_marker:=$m$IF v_document.status='CONFIRMED' AND v_document.fulfillment_status<>'CONFIRMED' THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC'; END IF;$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: core revision guard drift'; END IF;
 v_definition:=replace(v_definition,v_marker,$m$IF v_document.status='CONFIRMED' AND v_document.fulfillment_status<>'CONFIRMED'
  AND NOT (v_document.fulfillment_status='PREPARING'
   AND NULLIF(current_setting('kgs.office_pre_dispatch_revision_order',true),'')=v_document.id::text)
 THEN RAISE EXCEPTION 'BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC'; END IF;$m$);
 v_marker:=$m$v_after:=private.backoffice_sales_order_snapshot(v_company,v_document.id);$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: core snapshot boundary drift'; END IF;
 v_definition:=replace(v_definition,v_marker,$m$IF NULLIF(current_setting('kgs.office_pre_dispatch_revision_order',true),'')=v_document.id::text THEN
  PERFORM private.recompose_office_pre_dispatch_fulfillment(v_document.id,p_operation_id);
 END IF;
 v_after:=private.backoffice_sales_order_snapshot(v_company,v_document.id);$m$);
 EXECUTE v_definition;
 v_definition:=pg_get_functiondef('private.transition_backoffice_sales_order(uuid,bigint,uuid,text,text)'::regprocedure);
 v_marker:=$m$IF NOT (v_document.status IN('DRAFT','SENT') OR (v_document.status='CONFIRMED' AND v_document.fulfillment_status='CONFIRMED')) THEN RAISE EXCEPTION 'BACKOFFICE_SALES_CANCEL_STATE_INVALID'; END IF;$m$;
 IF position(v_marker IN v_definition)=0 THEN RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Cancel guard drift'; END IF;
 v_definition:=replace(v_definition,v_marker,$m$IF v_document.status='CONFIRMED' AND EXISTS(SELECT 1 FROM public.backoffice_sales_reservations WHERE company_id=v_company AND sales_order_id=p_order_id) THEN
  IF nullif(btrim(COALESCE(p_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;
  PERFORM private.release_office_untouched_fulfillment(v_company,p_order_id,p_operation_id,btrim(p_reason));
 ELSIF NOT (v_document.status IN('DRAFT','SENT') OR (v_document.status='CONFIRMED' AND v_document.fulfillment_status='CONFIRMED')) THEN
  RAISE EXCEPTION 'BACKOFFICE_SALES_CANCEL_STATE_INVALID'; END IF;$m$);
 EXECUTE v_definition;
END $patch$;
DO $acl$
DECLARE v_signature text;
BEGIN
 FOREACH v_signature IN ARRAY ARRAY[
 'private.validate_office_untouched_fulfillment(uuid,uuid)',
 'private.recompose_office_pre_dispatch_fulfillment(uuid,uuid)',
 'private.release_office_untouched_fulfillment(uuid,uuid,uuid,text)',
 'private.save_office_order_before_pre_dispatch_delta(uuid,bigint,uuid,jsonb)']
 LOOP EXECUTE 'REVOKE ALL ON FUNCTION '||v_signature||' FROM PUBLIC,anon,authenticated';
 EXECUTE 'GRANT EXECUTE ON FUNCTION '||v_signature||' TO service_role'; END LOOP;
END $acl$;
REVOKE ALL ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_backoffice_sales_order_draft(uuid,bigint,uuid,jsonb) TO authenticated,service_role;
INSERT INTO private.kgs_schema_migrations(version,migration_name,notes) VALUES('20260915142000','office_pre_dispatch_fulfillment_delta',
 'Same-number public SO revision/cancel before dispatch; canonical stock computation, existing parent IDs, immutable full fulfillment snapshots; no backfill/final effects.');
NOTIFY pgrst,'reload schema';
COMMIT;
