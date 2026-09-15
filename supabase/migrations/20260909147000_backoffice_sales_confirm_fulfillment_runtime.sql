-- Atomic Backoffice Confirm -> full Reservation + INITIAL/READY Delivery Order.
-- Reservation may exceed On Hand only when its Warehouse opts into negative stock.
-- No Stock Movement, FIFO, Invoice, Payment, cashier-session, or Finance effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909146000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: fulfillment contract correction required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260909147000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260909147000';
  END IF;
  IF to_regprocedure('public.confirm_backoffice_sales_order(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.resolve_bundle_components(uuid,uuid,numeric)') IS NULL
    OR to_regprocedure('private.next_sales_delivery_no(uuid,timestamp with time zone)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical dependency missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_reservations)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_orders)
    OR EXISTS(SELECT 1 FROM public.backoffice_sales_fulfillment_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: fulfillment foundation must remain empty';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
END
$guard$;

ALTER TABLE public.backoffice_sales_reservations
  ADD COLUMN shortage_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  DROP CONSTRAINT backoffice_sales_reservations_quantity_check,
  ADD CONSTRAINT backoffice_sales_reservations_quantity_check CHECK(
    total_ordered_base_qty>0 AND total_reserved_base_qty=total_ordered_base_qty
    AND shortage_base_qty>=0 AND shortage_base_qty<=total_reserved_base_qty
    AND total_released_base_qty>=0 AND total_in_transit_base_qty>=0
    AND total_completed_base_qty>=0
    AND total_released_base_qty+total_in_transit_base_qty
      +total_completed_base_qty<=total_reserved_base_qty);

ALTER TABLE public.backoffice_sales_reservation_lines
  ADD COLUMN stock_uom_id uuid NOT NULL,
  ADD COLUMN stock_uom_name_snapshot text NOT NULL,
  ADD COLUMN quantity_uom numeric(24,6) NOT NULL,
  ADD COLUMN factor_to_base numeric(24,6) NOT NULL,
  ADD COLUMN available_base_qty_snapshot numeric(24,6) NOT NULL,
  ADD COLUMN shortage_base_qty numeric(24,6) NOT NULL,
  ADD COLUMN bundle_component_line_no smallint,
  DROP CONSTRAINT backoffice_sales_reservation_lines_source_unique,
  DROP CONSTRAINT backoffice_sales_reservation_lines_quantity_check,
  ADD CONSTRAINT backoffice_sales_reservation_lines_source_unique
    UNIQUE(company_id,sales_order_line_id,product_id,stock_uom_id),
  ADD CONSTRAINT backoffice_sales_reservation_lines_stock_uom_fk
    FOREIGN KEY(company_id,stock_uom_id)
    REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT,
  ADD CONSTRAINT backoffice_sales_reservation_lines_quantity_check CHECK(
    ordered_base_qty>0 AND reserved_base_qty=ordered_base_qty
    AND quantity_uom>0 AND factor_to_base>0
    AND ordered_base_qty=quantity_uom*factor_to_base
    AND available_base_qty_snapshot>=0
    AND shortage_base_qty=ordered_base_qty-available_base_qty_snapshot
    AND shortage_base_qty>=0
    AND released_base_qty>=0 AND in_transit_base_qty>=0
    AND completed_base_qty>=0
    AND released_base_qty+in_transit_base_qty+completed_base_qty<=reserved_base_qty),
  ADD CONSTRAINT backoffice_sales_reservation_lines_bundle_shape_check CHECK(
    bundle_component_line_no IS NULL OR bundle_component_line_no>0);

COMMENT ON COLUMN public.backoffice_sales_reservation_lines.product_id IS
  'Physical stock Product. For Bundle order lines this is the resolved component Product.';

ALTER TABLE public.backoffice_sales_delivery_order_lines
  DROP CONSTRAINT backoffice_sales_delivery_order_lines_source_unique,
  ADD CONSTRAINT backoffice_sales_delivery_order_lines_source_unique
    UNIQUE(company_id,delivery_order_id,reservation_line_id);

CREATE FUNCTION private.backoffice_sales_stock_requirements(
  p_company_id uuid,p_order_id uuid
) RETURNS TABLE(
  sales_order_line_id uuid,commercial_product_id uuid,stock_product_id uuid,
  stock_uom_id uuid,stock_uom_name text,quantity_uom numeric,
  factor_to_base numeric,quantity_base numeric,bundle_component_line_no smallint
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT line.id,line.product_id,line.product_id,line.uom_id,line.uom_name_snapshot,
    line.ordered_qty,line.base_qty_per_uom,line.ordered_base_qty,NULL::smallint
  FROM public.backoffice_sales_order_lines line
  JOIN public.products product ON product.company_id=line.company_id
    AND product.id=line.product_id AND product.is_active AND NOT product.is_bundle
  WHERE line.company_id=p_company_id AND line.sales_order_id=p_order_id
  UNION ALL
  SELECT line.id,line.product_id,component.component_product_id,
    component.component_uom_id,uom.name,component.total_component_qty,
    component.factor_to_base,component.total_base_qty,component.line_no
  FROM public.backoffice_sales_order_lines line
  JOIN public.products product ON product.company_id=line.company_id
    AND product.id=line.product_id AND product.is_active AND product.is_bundle
  CROSS JOIN LATERAL private.resolve_bundle_components(
    line.company_id,line.product_id,line.ordered_qty) component
  JOIN public.uoms uom ON uom.company_id=line.company_id
    AND uom.id=component.component_uom_id AND uom.is_active
  WHERE line.company_id=p_company_id AND line.sales_order_id=p_order_id
$$;

CREATE FUNCTION private.compose_backoffice_sales_confirm_fulfillment(
  p_order_id uuid,p_confirm_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_company uuid:=public.private_active_company_id();v_actor uuid:=auth.uid();
  v_order public.backoffice_sales_orders%rowtype;v_reservation uuid:=gen_random_uuid();
  v_delivery uuid:=gen_random_uuid();v_delivery_audit_operation uuid:=gen_random_uuid();
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
  IF v_order.status<>'CONFIRMED' OR v_order.fulfillment_status<>'CONFIRMED'
    OR v_order.sales_origin<>'BACKOFFICE_SALES'
    OR v_order.sales_process_mode<>'BACKOFFICE_DELIVERED_QTY_INVOICE' THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_CONFIRM_FULFILLMENT_STATE_INVALID';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_reservations reservation
    WHERE reservation.company_id=v_company AND reservation.sales_order_id=p_order_id) THEN
    RAISE EXCEPTION 'BACKOFFICE_SALES_CONFIRM_FULFILLMENT_DUPLICATE';
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

  INSERT INTO public.backoffice_sales_reservations(
    id,company_id,sales_order_id,warehouse_id,total_ordered_base_qty,
    total_reserved_base_qty,shortage_base_qty,created_by,updated_by)
  VALUES(v_reservation,v_company,p_order_id,v_order.warehouse_id,v_total,v_total,
    v_shortage_total,v_actor,v_actor);

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

  v_delivery_no:=private.next_sales_delivery_no(v_company,v_now);
  INSERT INTO public.backoffice_sales_delivery_orders(
    id,company_id,sales_order_id,reservation_id,delivery_no,sequence_no,
    scheduled_date,recipient_snapshot,total_planned_base_qty,created_by,updated_by)
  VALUES(v_delivery,v_company,p_order_id,v_reservation,v_delivery_no,1,
    v_order.planned_delivery_date,v_order.customer_snapshot,v_total,v_actor,v_actor);

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
    company_id,sales_order_id,reservation_id,operation_id,action,actor_id,after_state)
  VALUES(v_company,p_order_id,v_reservation,p_confirm_operation_id,'RESERVE',v_actor,
    jsonb_build_object('status','OPEN','orderedBaseQty',v_total,
      'reservedBaseQty',v_total,'shortageBaseQty',v_shortage_total,'lineCount',v_line_count));
  INSERT INTO public.backoffice_sales_fulfillment_audit(
    company_id,sales_order_id,delivery_order_id,operation_id,action,actor_id,after_state)
  VALUES(v_company,p_order_id,v_delivery,v_delivery_audit_operation,'CREATE_DELIVERY',v_actor,
    jsonb_build_object('confirmOperationId',p_confirm_operation_id,'deliveryNo',v_delivery_no,
      'deliveryKind','INITIAL','status','READY','plannedBaseQty',v_total));
  UPDATE public.backoffice_sales_orders SET fulfillment_status='PREPARING',
    updated_by=v_actor,updated_at=v_now
  WHERE company_id=v_company AND id=p_order_id;
  RETURN jsonb_build_object('reservationId',v_reservation,'deliveryOrderId',v_delivery,
    'deliveryNo',v_delivery_no,'deliveryStatus','READY','reservedBaseQty',v_total,
    'shortageBaseQty',v_shortage_total,'requirementLineCount',v_line_count);
END
$$;

CREATE OR REPLACE FUNCTION public.confirm_backoffice_sales_order(
  p_order_id uuid,p_expected_version bigint,p_operation_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company uuid:=public.private_active_company_id();v_transition jsonb;
  v_fulfillment jsonb;v_reservation public.backoffice_sales_reservations%rowtype;
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
BEGIN
  v_transition:=private.transition_backoffice_sales_order(
    p_order_id,p_expected_version,p_operation_id,'CONFIRM',NULL);
  SELECT * INTO v_reservation FROM public.backoffice_sales_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.sales_order_id=p_order_id;
  IF NOT FOUND THEN
    IF COALESCE((v_transition->>'exactRetry')::boolean,false) THEN
      RAISE EXCEPTION 'BACKOFFICE_SALES_CONFIRM_FULFILLMENT_STATE_MISMATCH';
    END IF;
    v_fulfillment:=private.compose_backoffice_sales_confirm_fulfillment(
      p_order_id,p_operation_id);
  ELSE
    SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders delivery
    WHERE delivery.company_id=v_company AND delivery.sales_order_id=p_order_id
      AND delivery.delivery_kind='INITIAL' AND delivery.parent_delivery_order_id IS NULL;
    v_fulfillment:=jsonb_build_object('reservationId',v_reservation.id,
      'deliveryOrderId',v_delivery.id,'deliveryNo',v_delivery.delivery_no,
      'deliveryStatus',v_delivery.status,'reservedBaseQty',v_reservation.total_reserved_base_qty,
      'shortageBaseQty',v_reservation.shortage_base_qty,
      'requirementLineCount',(SELECT count(*) FROM public.backoffice_sales_reservation_lines line
        WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id));
  END IF;
  RETURN jsonb_build_object('companyId',v_company,
    'data',private.backoffice_sales_order_snapshot(v_company,p_order_id),
    'fulfillment',v_fulfillment,
    'exactRetry',COALESCE((v_transition->>'exactRetry')::boolean,false));
END
$$;

REVOKE ALL ON FUNCTION private.backoffice_sales_stock_requirements(uuid,uuid),
  private.compose_backoffice_sales_confirm_fulfillment(uuid,uuid)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.backoffice_sales_stock_requirements(uuid,uuid),
  private.compose_backoffice_sales_confirm_fulfillment(uuid,uuid) TO service_role;
REVOKE ALL ON FUNCTION public.confirm_backoffice_sales_order(uuid,bigint,uuid)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirm_backoffice_sales_order(uuid,bigint,uuid)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260909147000','backoffice_sales_confirm_fulfillment_runtime',
  'Atomic new Backoffice SO Confirm creates full component-aware Reservation and INITIAL READY Delivery; Warehouse opt-in controls reservation shortage; no Stock/FIFO/Invoice/Payment/Finance effect');

NOTIFY pgrst,'reload schema';
COMMIT;
