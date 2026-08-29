-- ODR-3C atomic partial/full Delivery Dispatch.
-- Dispatch owns Reservation, On Hand, FIFO and Stock Movement only.
-- Finance events and journals remain ODR-5.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-3B required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828140000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservations) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active reservation requires reviewed cutover';
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION private.trg_g4_guard_negative_sale_movement()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.balance_after_base_qty<0 AND NOT (
    EXISTS(SELECT 1 FROM public.pos_negative_stock_authorizations authz
      WHERE authz.company_id=NEW.company_id
        AND authz.sales_id=NEW.reference_id
        AND authz.stock_product_id=NEW.product_id
        AND authz.warehouse_id=NEW.warehouse_id
        AND authz.balance_after_base_qty=NEW.balance_after_base_qty)
    OR EXISTS(SELECT 1 FROM public.sales_dispatch_allocations allocation
      JOIN public.sales_stock_reservation_lines reservation_line
        ON reservation_line.company_id=allocation.company_id
       AND reservation_line.id=allocation.reservation_line_id
      WHERE allocation.company_id=NEW.company_id
        AND allocation.id=NEW.source_line_id
        AND allocation.allocation_kind='NEGATIVE'
        AND reservation_line.stock_product_id=NEW.product_id
        AND reservation_line.warehouse_id=NEW.warehouse_id
        AND reservation_line.negative_policy_version IS NOT NULL
        AND reservation_line.negative_permission_version IS NOT NULL)
  ) THEN RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'; END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.dispatch_sales_delivery_core(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_idempotency_key UUID,p_lines JSONB,p_notes TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_delivery public.sales_delivery_documents%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;
  v_sale public.sales_headers%ROWTYPE;v_line RECORD;v_res_line RECORD;v_batch RECORD;
  v_request JSONB;v_existing JSONB;v_result JSONB;v_now TIMESTAMPTZ:=clock_timestamp();
  v_prior_min NUMERIC(24,12);v_prior_max NUMERIC(24,12);
  v_remaining_uom NUMERIC(24,6);v_dispatch_uom NUMERIC(24,6);
  v_dispatch_base NUMERIC(24,6);v_remaining NUMERIC(24,6);v_take NUMERIC(24,6);
  v_stock_after NUMERIC(24,6);v_line_cost NUMERIC(20,4);v_total_cost NUMERIC(20,4):=0;
  v_total_dispatch NUMERIC(24,6):=0;v_reservation_dispatched NUMERIC(24,6);
  v_reservation_remaining NUMERIC(24,6);v_delivery_status TEXT;v_order_status TEXT;
  v_action TEXT;v_allocation_no INTEGER:=0;v_allocation_id UUID;
  v_first_allocation UUID;v_negative_allocation UUID;v_movement UUID;
  v_negative_qty NUMERIC(24,6);v_negative_cost NUMERIC(20,4);
  v_authorization UUID;v_permission UUID;v_negative_reason TEXT;
  v_bundle_allocation UUID;v_price NUMERIC(20,4);v_payload_hash TEXT;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF p_lines IS NOT NULL AND (jsonb_typeof(p_lines)<>'array'
    OR jsonb_array_length(p_lines)=0) THEN RAISE EXCEPTION 'DISPATCH_LINES_INVALID'; END IF;
  IF p_lines IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) item
    WHERE jsonb_typeof(item)<>'object' OR NOT (item?'deliveryLineId')
      OR NOT (item?'quantityUom')
      OR COALESCE((item->>'quantityUom')::NUMERIC,0)<=0) THEN
    RAISE EXCEPTION 'DISPATCH_LINES_INVALID';
  END IF;
  IF p_lines IS NOT NULL AND EXISTS(SELECT 1 FROM jsonb_array_elements(p_lines) item
    GROUP BY item->>'deliveryLineId' HAVING count(*)>1) THEN
    RAISE EXCEPTION 'DUPLICATE_DISPATCH_LINE';
  END IF;
  v_request:=COALESCE(p_lines,jsonb_build_object('mode','FULL_REMAINING'));
  v_payload_hash:=encode(digest(v_request::TEXT,'sha256'),'hex');

  SELECT audit.after_state INTO v_existing
  FROM public.sales_stock_reservation_audit audit
  WHERE audit.company_id=v_company
    AND audit.action IN('DISPATCH_PARTIAL','DISPATCH_FULL')
    AND audit.idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_existing->>'requestHash' IS DISTINCT FROM v_payload_hash
      OR v_existing->>'deliveryDocumentId' IS DISTINCT FROM p_delivery_document_id::TEXT THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN (v_existing->'result')||jsonb_build_object('exactRetry',TRUE);
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_audit audit
    WHERE audit.company_id=v_company AND audit.idempotency_key=p_idempotency_key) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;

  SELECT delivery.* INTO v_delivery FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND'; END IF;
  IF v_delivery.reservation_id IS NULL THEN RAISE EXCEPTION 'LEGACY_DELIVERY_DISPATCH_BOUNDARY'; END IF;
  IF v_delivery.master_version<>p_master_version THEN RAISE EXCEPTION 'MASTER_VERSION_CONFLICT'; END IF;
  IF v_delivery.status NOT IN('READY','PARTIALLY_DISPATCHED') THEN
    RAISE EXCEPTION 'SALES_DELIVERY_NOT_DISPATCHABLE';
  END IF;
  IF NOT (public.private_user_has_any_company_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN']::TEXT[])
    OR public.private_user_has_any_store_role(v_delivery.store_id,
      ARRAY['STORE_MANAGER']::TEXT[])) THEN
    RAISE EXCEPTION 'DELIVERY_WAREHOUSE_SCOPE_DENIED';
  END IF;
  SELECT reservation.* INTO STRICT v_reservation
  FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id
    AND reservation.sales_id=v_delivery.sales_id FOR UPDATE;
  SELECT sale.* INTO STRICT v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=v_delivery.sales_id FOR UPDATE;
  IF v_reservation.status NOT IN('OPEN','PARTIALLY_DISPATCHED')
    OR v_sale.document_status<>'DRAFT'
    OR v_sale.order_runtime_status NOT IN('RESERVED','PARTIALLY_DISPATCHED') THEN
    RAISE EXCEPTION 'SALES_ORDER_NOT_DISPATCHABLE';
  END IF;
  IF p_lines IS NOT NULL AND (SELECT count(*) FROM jsonb_array_elements(p_lines))<>
    (SELECT count(*) FROM jsonb_array_elements(p_lines) item
      JOIN public.sales_delivery_lines delivery_line
        ON delivery_line.company_id=v_company
       AND delivery_line.delivery_document_id=v_delivery.id
       AND delivery_line.id=(item->>'deliveryLineId')::UUID) THEN
    RAISE EXCEPTION 'DISPATCH_LINE_SCOPE_INVALID';
  END IF;

  FOR v_line IN
    WITH requested AS (
      SELECT (item->>'deliveryLineId')::UUID delivery_line_id,
        (item->>'quantityUom')::NUMERIC quantity_uom
      FROM jsonb_array_elements(COALESCE(p_lines,'[]'::JSONB)) item
    )
    SELECT delivery_line.*,requested.quantity_uom requested_uom
    FROM public.sales_delivery_lines delivery_line
    JOIN public.sales_delivery_documents scoped_delivery
      ON scoped_delivery.company_id=delivery_line.company_id
     AND scoped_delivery.id=delivery_line.delivery_document_id
    LEFT JOIN requested ON requested.delivery_line_id=delivery_line.id
    LEFT JOIN LATERAL (SELECT min(reservation_line.dispatched_base_qty/
        reservation_line.reserved_base_qty) dispatched_ratio
      FROM public.sales_stock_reservation_lines reservation_line
      WHERE reservation_line.company_id=delivery_line.company_id
        AND reservation_line.reservation_id=scoped_delivery.reservation_id
        AND reservation_line.sales_detail_id=delivery_line.sales_detail_id) lineage ON TRUE
    WHERE delivery_line.company_id=v_company
      AND delivery_line.delivery_document_id=v_delivery.id
      AND (p_lines IS NULL OR requested.delivery_line_id IS NOT NULL)
      AND (p_lines IS NOT NULL OR COALESCE(lineage.dispatched_ratio,0)<1)
    ORDER BY delivery_line.line_no,delivery_line.id
  LOOP
    SELECT min(reservation_line.dispatched_base_qty/reservation_line.reserved_base_qty),
      max(reservation_line.dispatched_base_qty/reservation_line.reserved_base_qty)
    INTO v_prior_min,v_prior_max
    FROM public.sales_stock_reservation_lines reservation_line
    WHERE reservation_line.company_id=v_company
      AND reservation_line.reservation_id=v_reservation.id
      AND reservation_line.sales_detail_id=v_line.sales_detail_id;
    IF v_prior_min IS NULL OR abs(v_prior_max-v_prior_min)>0.000001 THEN
      RAISE EXCEPTION 'RESERVATION_COMMERCIAL_LINEAGE_INVALID';
    END IF;
    v_remaining_uom:=round(v_line.quantity_uom*(1-v_prior_min),6);
    v_dispatch_uom:=COALESCE(v_line.requested_uom,v_remaining_uom);
    IF v_dispatch_uom<=0 OR v_dispatch_uom>v_remaining_uom+0.000001 THEN
      RAISE EXCEPTION 'DISPATCH_QUANTITY_EXCEEDS_REMAINING';
    END IF;

    FOR v_res_line IN
      SELECT reservation_line.*,requirement.commercial_product_id,
        requirement.stock_uom_id,requirement.stock_sku,requirement.stock_name,
        requirement.stock_uom_name_snapshot,requirement.quantity_uom,
        product.is_bundle commercial_is_bundle
      FROM public.sales_stock_reservation_lines reservation_line
      JOIN public.sale_stock_requirements requirement
        ON requirement.company_id=reservation_line.company_id
       AND requirement.id=reservation_line.stock_requirement_id
      JOIN public.products product ON product.company_id=requirement.company_id
       AND product.id=requirement.commercial_product_id
      WHERE reservation_line.company_id=v_company
        AND reservation_line.reservation_id=v_reservation.id
        AND reservation_line.sales_detail_id=v_line.sales_detail_id
      ORDER BY reservation_line.id FOR UPDATE OF reservation_line
    LOOP
      v_dispatch_base:=CASE WHEN abs(v_dispatch_uom-v_remaining_uom)<=0.000001
        THEN v_res_line.reserved_base_qty-v_res_line.released_base_qty-
          v_res_line.dispatched_base_qty
        ELSE round(v_res_line.reserved_base_qty*v_dispatch_uom/v_line.quantity_uom,6) END;
      IF v_dispatch_base<=0 OR v_dispatch_base>
        v_res_line.reserved_base_qty-v_res_line.released_base_qty-
          v_res_line.dispatched_base_qty+0.000001 THEN
        RAISE EXCEPTION 'DISPATCH_RESERVATION_QUANTITY_INVALID';
      END IF;
      v_bundle_allocation:=NULL;
      IF v_res_line.commercial_is_bundle THEN
        SELECT allocation.id INTO v_bundle_allocation
        FROM public.bundle_sale_allocations allocation
        WHERE allocation.company_id=v_company
          AND allocation.stock_requirement_id=v_res_line.stock_requirement_id;
        IF v_bundle_allocation IS NULL THEN
          SELECT COALESCE(product_uom.sale_price,
            product.cogs*product_uom.factor_to_base,0)
          INTO v_price FROM public.product_uoms product_uom
          JOIN public.products product ON product.company_id=product_uom.company_id
            AND product.id=product_uom.product_id
          WHERE product_uom.company_id=v_company
            AND product_uom.product_id=v_res_line.stock_product_id
            AND product_uom.uom_id=v_res_line.stock_uom_id AND product_uom.is_active;
          IF v_price IS NULL OR v_price<0 THEN RAISE EXCEPTION 'BUNDLE_COMPONENT_PRICE_REFERENCE_INVALID'; END IF;
          INSERT INTO public.bundle_sale_allocations(id,company_id,sales_id,
            sales_detail_id,stock_requirement_id,bundle_product_id,
            component_product_id,component_uom_id,component_product_sku_snapshot,
            component_product_name_snapshot,component_uom_name_snapshot,
            component_qty_per_bundle,bundle_quantity,component_quantity_uom,
            component_quantity_base,standalone_unit_price_snapshot,allocation_weight)
          VALUES(gen_random_uuid(),v_company,v_sale.id,v_line.sales_detail_id,
            v_res_line.stock_requirement_id,v_res_line.commercial_product_id,
            v_res_line.stock_product_id,v_res_line.stock_uom_id,v_res_line.stock_sku,
            v_res_line.stock_name,v_res_line.stock_uom_name_snapshot,
            v_res_line.quantity_uom/v_line.quantity_uom,v_line.quantity_uom,
            v_res_line.quantity_uom,v_res_line.reserved_base_qty,v_price,
            v_price*v_res_line.quantity_uom) RETURNING id INTO v_bundle_allocation;
        END IF;
      END IF;

      PERFORM pg_advisory_xact_lock(hashtextextended(v_company::TEXT||':'||
        v_res_line.warehouse_id::TEXT||':'||v_res_line.stock_product_id::TEXT,0));
      v_remaining:=v_dispatch_base;v_line_cost:=0;v_first_allocation:=NULL;
      v_negative_allocation:=NULL;v_negative_qty:=0;v_movement:=gen_random_uuid();
      FOR v_batch IN SELECT batch.* FROM public.product_batches batch
        WHERE batch.company_id=v_company AND batch.product_id=v_res_line.stock_product_id
          AND batch.warehouse_id=v_res_line.warehouse_id AND batch.qty_remaining>0
        ORDER BY batch.created_at,batch.id FOR UPDATE
      LOOP
        EXIT WHEN v_remaining<=0;
        v_take:=LEAST(v_remaining,v_batch.qty_remaining);
        UPDATE public.product_batches SET qty_remaining=qty_remaining-v_take
        WHERE company_id=v_company AND id=v_batch.id;
        INSERT INTO public.sale_fifo_allocations(company_id,sales_id,sales_detail_id,
          stock_requirement_id,bundle_sale_allocation_id,stock_product_id,
          product_batch_id,quantity_base,fifo_unit_cost,fifo_cost_total)
        VALUES(v_company,v_sale.id,v_line.sales_detail_id,
          v_res_line.stock_requirement_id,v_bundle_allocation,
          v_res_line.stock_product_id,v_batch.id,v_take,v_batch.cogs_unit,
          round(v_take*v_batch.cogs_unit,4))
        ON CONFLICT(company_id,stock_requirement_id,product_batch_id) DO UPDATE SET
          quantity_base=public.sale_fifo_allocations.quantity_base+EXCLUDED.quantity_base,
          fifo_cost_total=public.sale_fifo_allocations.fifo_cost_total+EXCLUDED.fifo_cost_total;
        v_allocation_no:=v_allocation_no+1;v_allocation_id:=gen_random_uuid();
        INSERT INTO public.sales_dispatch_allocations(id,company_id,
          delivery_document_id,delivery_line_id,reservation_id,reservation_line_id,
          dispatch_idempotency_key,allocation_no,allocation_kind,
          dispatched_base_qty,fifo_batch_id,stock_movement_id,unit_cost_snapshot,
          created_by,created_at)
        VALUES(v_allocation_id,v_company,v_delivery.id,v_line.id,v_reservation.id,
          v_res_line.id,p_idempotency_key,v_allocation_no,'FIFO',v_take,
          v_batch.id,v_movement,v_batch.cogs_unit,v_actor,v_now);
        v_first_allocation:=COALESCE(v_first_allocation,v_allocation_id);
        v_line_cost:=v_line_cost+round(v_take*v_batch.cogs_unit,4);
        v_remaining:=v_remaining-v_take;
      END LOOP;
      IF v_remaining>0 THEN
        IF v_res_line.negative_policy_version IS NULL
          OR v_res_line.negative_permission_version IS NULL
          OR v_res_line.commercial_is_bundle THEN
          RAISE EXCEPTION 'FIFO_STOCK_CHANGED';
        END IF;
        v_negative_qty:=v_remaining;
        v_negative_cost:=private.resolve_pos_negative_stock_provisional_cost(
          v_company,v_res_line.stock_product_id,v_res_line.warehouse_id);
        v_allocation_no:=v_allocation_no+1;v_negative_allocation:=gen_random_uuid();
        INSERT INTO public.sales_dispatch_allocations(id,company_id,
          delivery_document_id,delivery_line_id,reservation_id,reservation_line_id,
          dispatch_idempotency_key,allocation_no,allocation_kind,
          dispatched_base_qty,stock_movement_id,created_by,created_at)
        VALUES(v_negative_allocation,v_company,v_delivery.id,v_line.id,
          v_reservation.id,v_res_line.id,p_idempotency_key,v_allocation_no,
          'NEGATIVE',v_remaining,v_movement,v_actor,v_now);
        v_line_cost:=v_line_cost+round(v_remaining*v_negative_cost,4);
        v_remaining:=0;
      END IF;

      INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
      VALUES(v_res_line.stock_product_id,v_res_line.warehouse_id,-v_dispatch_base,v_company)
      ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
        stock_qty=public.product_stocks.stock_qty-v_dispatch_base,
        updated_at=clock_timestamp() RETURNING stock_qty INTO v_stock_after;

      IF v_negative_qty>0 THEN
        SELECT permission.id INTO v_permission
        FROM public.pos_negative_stock_permissions permission
        WHERE permission.company_id=v_company
          AND permission.warehouse_id=v_res_line.warehouse_id
          AND permission.user_id=v_reservation.confirmed_by
        ORDER BY (permission.master_version=v_res_line.negative_permission_version) DESC,
          permission.updated_at DESC LIMIT 1;
        IF v_permission IS NULL THEN RAISE EXCEPTION 'NEGATIVE_STOCK_PERMISSION_SNAPSHOT_MISSING'; END IF;
        SELECT COALESCE(audit.after_state->>'negativeReason','Reservation-approved negative stock')
        INTO v_negative_reason FROM public.sales_stock_reservation_audit audit
        WHERE audit.company_id=v_company AND audit.reservation_id=v_reservation.id
          AND audit.action='CONFIRM' ORDER BY audit.created_at LIMIT 1;
        v_negative_reason:=COALESCE(v_negative_reason,
          'Reservation-approved negative stock');
        INSERT INTO public.pos_negative_stock_authorizations(company_id,sales_id,
          sales_detail_id,stock_product_id,warehouse_id,permission_id,actor_id,
          reason,requested_base_qty,available_base_qty,shortage_base_qty,
          balance_after_base_qty,provisional_unit_cost,policy_version,permission_version)
        VALUES(v_company,v_sale.id,v_line.sales_detail_id,v_res_line.stock_product_id,
          v_res_line.warehouse_id,v_permission,v_reservation.confirmed_by,
          v_negative_reason,v_negative_qty,GREATEST(v_stock_after+v_dispatch_base,0),
          v_negative_qty,v_stock_after,v_negative_cost,
          v_res_line.negative_policy_version,v_res_line.negative_permission_version)
        ON CONFLICT(company_id,sales_id,stock_product_id) DO UPDATE SET
          requested_base_qty=public.pos_negative_stock_authorizations.requested_base_qty+
            EXCLUDED.requested_base_qty,
          shortage_base_qty=public.pos_negative_stock_authorizations.shortage_base_qty+
            EXCLUDED.shortage_base_qty,
          balance_after_base_qty=EXCLUDED.balance_after_base_qty
        RETURNING id,provisional_unit_cost INTO v_authorization,v_negative_cost;
        INSERT INTO public.negative_stock_sale_allocations(company_id,authorization_id,
          sales_id,sales_detail_id,stock_requirement_id,stock_product_id,warehouse_id,
          shortage_base_qty,provisional_unit_cost,provisional_cost_total)
        VALUES(v_company,v_authorization,v_sale.id,v_line.sales_detail_id,
          v_res_line.stock_requirement_id,v_res_line.stock_product_id,
          v_res_line.warehouse_id,v_negative_qty,v_negative_cost,
          round(v_negative_qty*v_negative_cost,4))
        ON CONFLICT(company_id,stock_requirement_id) DO UPDATE SET
          shortage_base_qty=public.negative_stock_sale_allocations.shortage_base_qty+
            EXCLUDED.shortage_base_qty,
          provisional_cost_total=public.negative_stock_sale_allocations.provisional_cost_total+
            EXCLUDED.provisional_cost_total,reconciled_at=NULL;
      END IF;

      INSERT INTO public.stock_movements(id,product_id,warehouse_id,qty_change,
        movement_type,reference_table,reference_id,company_id,base_uom_id,
        base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
        movement_status,source_line_id,notes)
      SELECT v_movement,v_res_line.stock_product_id,v_res_line.warehouse_id,
        -v_dispatch_base,'SALE'::public.stock_movement_type,'sales_headers',v_sale.id,
        v_company,product.uom_id,uom.name,v_stock_after,v_actor,v_now,'POSTED',
        COALESCE(v_negative_allocation,v_first_allocation),
        'ODR Dispatch '||v_delivery.delivery_no||' / '||p_idempotency_key::TEXT
      FROM public.products product JOIN public.uoms uom
        ON uom.company_id=product.company_id AND uom.id=product.uom_id
      WHERE product.company_id=v_company AND product.id=v_res_line.stock_product_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_MOVEMENT_SNAPSHOT_INCOMPLETE'; END IF;

      UPDATE public.sales_stock_reservation_lines SET
        dispatched_base_qty=dispatched_base_qty+v_dispatch_base,updated_at=v_now
      WHERE company_id=v_company AND id=v_res_line.id;
      UPDATE public.sales_details SET fifo_cost_total=fifo_cost_total+v_line_cost,
        cogs_total=cogs_total+v_line_cost,
        cogs_unit=round((cogs_total+v_line_cost)/NULLIF(qty,0),4)
      WHERE company_id=v_company AND id=v_line.sales_detail_id;
      IF v_bundle_allocation IS NOT NULL THEN
        UPDATE public.bundle_sale_allocations SET fifo_cost_total=fifo_cost_total+v_line_cost
        WHERE company_id=v_company AND id=v_bundle_allocation;
      END IF;
      v_total_dispatch:=v_total_dispatch+v_dispatch_base;
      v_total_cost:=v_total_cost+v_line_cost;
    END LOOP;
  END LOOP;
  IF v_total_dispatch<=0 THEN RAISE EXCEPTION 'DISPATCH_EMPTY'; END IF;

  SELECT sum(line.dispatched_base_qty),sum(line.reserved_base_qty-
    line.released_base_qty-line.dispatched_base_qty)
  INTO v_reservation_dispatched,v_reservation_remaining
  FROM public.sales_stock_reservation_lines line
  WHERE line.company_id=v_company AND line.reservation_id=v_reservation.id;
  IF v_reservation_remaining=0 THEN
    v_delivery_status:='DISPATCHED';v_order_status:='DISPATCHED';v_action:='DISPATCH_FULL';
  ELSE
    v_delivery_status:='PARTIALLY_DISPATCHED';v_order_status:='PARTIALLY_DISPATCHED';
    v_action:='DISPATCH_PARTIAL';
  END IF;
  UPDATE public.sales_stock_reservations SET
    status=CASE WHEN v_reservation_remaining=0 THEN 'CONSUMED' ELSE 'PARTIALLY_DISPATCHED' END,
    total_dispatched_base_qty=v_reservation_dispatched,
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=v_reservation.id;
  PERFORM set_config('kgs.sld_delivery_status_mutation','1',TRUE);
  UPDATE public.sales_delivery_documents SET status=v_delivery_status,
    total_dispatched_base_qty=v_reservation_dispatched,
    dispatch_version=dispatch_version+1,master_version=master_version+1,
    dispatched_by=COALESCE(dispatched_by,v_actor),
    dispatched_at=COALESCE(dispatched_at,v_now)
  WHERE company_id=v_company AND id=v_delivery.id;
  PERFORM set_config('kgs.sld_delivery_status_mutation','',TRUE);
  UPDATE public.sales_headers SET order_runtime_status=v_order_status,
    sj_status='SHIPPED'::public.sj_status,reservation_version=reservation_version+1,
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=v_sale.id;

  v_result:=jsonb_build_object('deliveryDocumentId',v_delivery.id,
    'deliveryNo',v_delivery.delivery_no,'reservationId',v_reservation.id,
    'deliveryStatus',v_delivery_status,'orderRuntimeStatus',v_order_status,
    'dispatchedBaseQty',v_total_dispatch,'reservationDispatchedBaseQty',
      v_reservation_dispatched,'remainingReservedBaseQty',v_reservation_remaining,
    'fifoCostTotal',v_total_cost,'masterVersion',v_delivery.master_version+1,
    'dispatchVersion',v_delivery.dispatch_version+1,'exactRetry',FALSE);
  INSERT INTO public.sales_stock_reservation_audit(company_id,reservation_id,sales_id,
    action,actor_id,idempotency_key,before_state,after_state)
  VALUES(v_company,v_reservation.id,v_sale.id,v_action,v_actor,p_idempotency_key,
    jsonb_build_object('reservationStatus',v_reservation.status,
      'deliveryStatus',v_delivery.status,'dispatchedBaseQty',
      v_reservation.total_dispatched_base_qty),jsonb_build_object(
      'deliveryDocumentId',v_delivery.id,'requestHash',v_payload_hash,
      'request',v_request,'notes',NULLIF(btrim(p_notes),''),'result',v_result));
  INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
    sales_id,action,actor_id,before_state,after_state)
  VALUES(v_company,'SALES_DELIVERY',v_delivery.id,v_sale.id,'DISPATCH',v_actor,
    jsonb_build_object('status',v_delivery.status,'masterVersion',v_delivery.master_version),
    jsonb_build_object('status',v_delivery_status,
      'dispatchedBaseQty',v_total_dispatch,'idempotencyKey',p_idempotency_key,
      'masterVersion',v_delivery.master_version+1));
  RETURN v_result;
END
$$;

CREATE FUNCTION public.dispatch_sales_delivery(
  p_delivery_document_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_lines JSONB DEFAULT NULL,p_notes TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  RETURN private.dispatch_sales_delivery_core(p_delivery_document_id,
    p_master_version,p_idempotency_key,p_lines,p_notes);
END
$$;

CREATE FUNCTION public.confirm_sales_delivery_received(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_recipient_name TEXT,p_notes TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_delivery RECORD;v_result JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','MANAGE');
  IF COALESCE(btrim(p_recipient_name),'')='' THEN RAISE EXCEPTION 'DELIVERY_RECEIVER_REQUIRED'; END IF;
  SELECT delivery.id,delivery.status,delivery.reservation_id,delivery.sales_id
  INTO v_delivery FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND'; END IF;
  IF v_delivery.reservation_id IS NULL THEN RAISE EXCEPTION 'LEGACY_DELIVERY_RECEIPT_BOUNDARY'; END IF;
  IF v_delivery.status<>'DISPATCHED' THEN RAISE EXCEPTION 'FULL_DISPATCH_REQUIRED'; END IF;
  v_result:=private.acp5e_update_sales_delivery_status_odr3_legacy(
    p_delivery_document_id,p_master_version,'DELIVER',p_notes);
  INSERT INTO public.sales_document_audit(company_id,document_type,document_id,
    sales_id,action,actor_id,after_state)
  VALUES(v_company,'SALES_DELIVERY',p_delivery_document_id,v_delivery.sales_id,
    'DELIVER',auth.uid(),jsonb_build_object('recipientName',btrim(p_recipient_name),
      'notes',NULLIF(btrim(p_notes),'')));
  UPDATE public.sales_headers SET order_runtime_status='DELIVERED',
    master_version=master_version+1,updated_at=clock_timestamp()
  WHERE company_id=v_company AND id=v_delivery.sales_id;
  RETURN v_result||jsonb_build_object('recipientName',btrim(p_recipient_name));
END
$$;

CREATE FUNCTION public.get_inventory_delivery_dispatch_workspace(
  p_date_from DATE DEFAULT NULL,p_date_to DATE DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_timezone TEXT;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'inventory.delivery_documents','VIEW');
  IF p_date_from IS NOT NULL AND p_date_to IS NOT NULL AND p_date_from>p_date_to THEN
    RAISE EXCEPTION 'INVALID_DELIVERY_DATE_RANGE';
  END IF;
  SELECT COALESCE(company.timezone,'Asia/Jakarta') INTO v_timezone
  FROM public.companies company WHERE company.id=v_company;
  RETURN jsonb_build_object('companyId',v_company,'timezone',v_timezone,
    'deliveries',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.scheduled_at NULLS LAST,row_data.delivery_no),'[]'::JSONB)
      FROM (SELECT delivery.id,delivery.delivery_no,delivery.sales_id,
        delivery.store_id,store.store_name,delivery.warehouse_id,warehouse.name warehouse_name,
        delivery.customer_id,customer.name customer_name,delivery.recipient_name,
        delivery.scheduled_at,delivery.status,delivery.master_version,
        delivery.dispatch_version,delivery.total_dispatched_base_qty,
        reservation.id reservation_id,reservation.status reservation_status,
        reservation.total_reserved_base_qty,reservation.total_released_base_qty,
        reservation.total_dispatched_base_qty reservation_dispatched_base_qty
      FROM public.sales_delivery_documents delivery
      JOIN public.sales_stock_reservations reservation
        ON reservation.company_id=delivery.company_id AND reservation.id=delivery.reservation_id
      JOIN public.stores store ON store.company_id=delivery.company_id AND store.id=delivery.store_id
      JOIN public.warehouses warehouse ON warehouse.company_id=delivery.company_id
        AND warehouse.id=delivery.warehouse_id
      LEFT JOIN public.customers customer ON customer.company_id=delivery.company_id
        AND customer.id=delivery.customer_id
      WHERE delivery.company_id=v_company
        AND delivery.status IN('READY','PARTIALLY_DISPATCHED','DISPATCHED')
        AND (p_date_from IS NULL OR (COALESCE(delivery.scheduled_at,delivery.created_at)
          AT TIME ZONE v_timezone)::DATE>=p_date_from)
        AND (p_date_to IS NULL OR (COALESCE(delivery.scheduled_at,delivery.created_at)
          AT TIME ZONE v_timezone)::DATE<=p_date_to)) row_data),
    'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.delivery_document_id,row_data.line_no),'[]'::JSONB)
      FROM (SELECT delivery_line.id,delivery_line.delivery_document_id,
        delivery_line.line_no,delivery_line.product_id,
        delivery_line.product_sku_snapshot,delivery_line.product_name_snapshot,
        delivery_line.sale_uom_id,delivery_line.sale_uom_name_snapshot,
        delivery_line.quantity_uom,delivery_line.quantity_base,
        round(delivery_line.quantity_uom*(1-COALESCE(lineage.dispatched_ratio,0)),6)
          remaining_quantity_uom
      FROM public.sales_delivery_lines delivery_line
      JOIN public.sales_delivery_documents delivery
        ON delivery.company_id=delivery_line.company_id
       AND delivery.id=delivery_line.delivery_document_id
      LEFT JOIN LATERAL (SELECT min(reservation_line.dispatched_base_qty/
          reservation_line.reserved_base_qty) dispatched_ratio
        FROM public.sales_stock_reservation_lines reservation_line
        WHERE reservation_line.company_id=delivery_line.company_id
          AND reservation_line.reservation_id=delivery.reservation_id
          AND reservation_line.sales_detail_id=delivery_line.sales_detail_id) lineage ON TRUE
      WHERE delivery_line.company_id=v_company AND delivery.reservation_id IS NOT NULL
        AND delivery.status IN('READY','PARTIALLY_DISPATCHED','DISPATCHED')) row_data));
END
$$;

CREATE OR REPLACE FUNCTION private.acp5e_update_sales_delivery_status_core(
  p_delivery_document_id UUID,p_master_version BIGINT,
  p_action TEXT,p_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_reservation UUID;
BEGIN
  SELECT delivery.reservation_id INTO v_reservation
  FROM public.sales_delivery_documents delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id;
  IF upper(btrim(COALESCE(p_action,''))) IN('DISPATCH','DELIVER')
    AND v_reservation IS NOT NULL THEN
    RAISE EXCEPTION 'USE_CANONICAL_DISPATCH_RUNTIME';
  END IF;
  RETURN private.acp5e_update_sales_delivery_status_odr3_legacy(
    p_delivery_document_id,p_master_version,p_action,p_reason);
END
$$;

REVOKE ALL ON FUNCTION private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.trg_g4_guard_negative_sale_movement() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.dispatch_sales_delivery_core(UUID,BIGINT,UUID,JSONB,TEXT),
  private.trg_g4_guard_negative_sale_movement() TO service_role;
REVOKE ALL ON FUNCTION public.dispatch_sales_delivery(UUID,BIGINT,UUID,JSONB,TEXT),
  public.confirm_sales_delivery_received(UUID,BIGINT,TEXT,TEXT),
  public.get_inventory_delivery_dispatch_workspace(DATE,DATE)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.dispatch_sales_delivery(UUID,BIGINT,UUID,JSONB,TEXT),
  public.confirm_sales_delivery_received(UUID,BIGINT,TEXT,TEXT),
  public.get_inventory_delivery_dispatch_workspace(DATE,DATE)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828140000','odr_phase3c_atomic_delivery_dispatch',
  'Guarded partial/full linked Delivery Dispatch atomically consumes Reservation, FIFO and On Hand, writes canonical Sale Movement and immutable allocation evidence, supports negative reservation snapshots, and keeps Delivered proof free of second stock effect; Finance remains ODR-5');
NOTIFY pgrst,'reload schema';
COMMIT;
