-- ODR-2B atomic Sales Order confirmation and reservation runtime.
-- Confirm only creates Reserved Out. Stock/FIFO/Movement/Finance remain ODR-3/5.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-2A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260828110000';
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
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected reservation rows';
  END IF;
END
$guard$;

CREATE UNIQUE INDEX uq_sales_stock_reservation_audit_operation
  ON public.sales_stock_reservation_audit(company_id,action,idempotency_key);

CREATE FUNCTION private.confirm_pos_sales_order_core(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();
  v_sale public.sales_headers%ROWTYPE;
  v_warehouse UUID;
  v_reservation UUID;
  v_total NUMERIC(24,6);
  v_product RECORD;
  v_requirement RECORD;
  v_on_hand NUMERIC(24,6);
  v_reserved_out NUMERIC(24,6);
  v_available NUMERIC(24,6);
  v_available_remaining NUMERIC(24,6);
  v_line_available NUMERIC(24,6);
  v_shortage NUMERIC(24,6);
  v_projected_negative NUMERIC(24,6);
  v_policy public.pos_negative_stock_policies%ROWTYPE;
  v_permission public.pos_negative_stock_permissions%ROWTYPE;
  v_reason TEXT:=NULLIF(btrim(p_negative_stock_reason),'');
  v_now TIMESTAMPTZ:=clock_timestamp();
  v_line_count INTEGER:=0;
  v_shortage_count INTEGER:=0;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;

  IF EXISTS(SELECT 1 FROM public.sales_headers other_sale
    WHERE other_sale.company_id=v_company
      AND other_sale.confirmation_idempotency_key=p_idempotency_key
      AND other_sale.id<>p_sales_id) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;

  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;

  IF v_sale.confirmation_idempotency_key=p_idempotency_key
     AND v_sale.order_runtime_status IN('CONFIRMED','RESERVED') THEN
    SELECT reservation.id INTO v_reservation
    FROM public.sales_stock_reservations reservation
    WHERE reservation.company_id=v_company AND reservation.sales_id=p_sales_id;
    IF v_reservation IS NULL THEN RAISE EXCEPTION 'RESERVATION_STATE_MISMATCH'; END IF;
    IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_audit audit
      WHERE audit.company_id=v_company AND audit.sales_id=p_sales_id
        AND audit.action='CONFIRM' AND audit.idempotency_key=p_idempotency_key
        AND audit.after_state->>'negativeReason' IS DISTINCT FROM v_reason) THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN jsonb_build_object('salesId',p_sales_id,'reservationId',v_reservation,
      'orderRuntimeStatus',v_sale.order_runtime_status,
      'masterVersion',v_sale.master_version,'exactRetry',TRUE);
  END IF;

  IF v_sale.document_status<>'DRAFT'
     OR v_sale.order_runtime_status NOT IN('DRAFT_INPUT','SCHEDULED') THEN
    RAISE EXCEPTION 'SALES_ORDER_FINAL';
  END IF;
  IF v_sale.master_version IS DISTINCT FROM p_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.cashier_sessions session
    WHERE session.company_id=v_company AND session.cashier_id=v_actor
      AND session.store_id=v_sale.store_id
      AND session.status='OPEN'::public.session_status) THEN
    RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED';
  END IF;

  SELECT session.sales_warehouse_id INTO v_warehouse
  FROM public.cashier_sessions session
  WHERE session.company_id=v_company AND session.id=v_sale.session_id;
  v_warehouse:=COALESCE(v_sale.sales_warehouse_id,v_warehouse);
  IF v_warehouse IS NULL OR NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.id=v_warehouse
      AND warehouse.is_active AND warehouse.is_sale_source) THEN
    RAISE EXCEPTION 'WAREHOUSE_SCOPE_DENIED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.sale_stock_requirements requirement
    WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id) THEN
    RAISE EXCEPTION 'SALES_ORDER_REQUIREMENT_MISSING';
  END IF;

  SELECT sum(requirement.quantity_base) INTO v_total
  FROM public.sale_stock_requirements requirement
  WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id;

  INSERT INTO public.sales_stock_reservations(company_id,sales_id,warehouse_id,
    total_reserved_base_qty,confirmation_idempotency_key,confirmed_by,confirmed_at)
  VALUES(v_company,p_sales_id,v_warehouse,v_total,p_idempotency_key,v_actor,v_now)
  RETURNING id INTO v_reservation;

  FOR v_product IN
    SELECT requirement.stock_product_id,
      sum(requirement.quantity_base) requested_base_qty,
      bool_or(commercial.is_bundle) has_bundle_source
    FROM public.sale_stock_requirements requirement
    JOIN public.products commercial ON commercial.company_id=requirement.company_id
      AND commercial.id=requirement.commercial_product_id
    WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id
    GROUP BY requirement.stock_product_id ORDER BY requirement.stock_product_id
  LOOP
    -- Serializes both an existing stock row and the no-row-yet case.
    PERFORM pg_advisory_xact_lock(hashtextextended(
      v_company::TEXT||':'||v_warehouse::TEXT||':'||v_product.stock_product_id::TEXT,0));
    SELECT stock.stock_qty INTO v_on_hand FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND stock.warehouse_id=v_warehouse
      AND stock.product_id=v_product.stock_product_id FOR UPDATE;
    v_on_hand:=COALESCE(v_on_hand,0);
    SELECT COALESCE(sum(line.reserved_base_qty-line.released_base_qty-
      line.dispatched_base_qty),0) INTO v_reserved_out
    FROM public.sales_stock_reservation_lines line
    JOIN public.sales_stock_reservations reservation
      ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
    WHERE line.company_id=v_company AND line.warehouse_id=v_warehouse
      AND line.stock_product_id=v_product.stock_product_id
      AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED');
    v_available:=v_on_hand-v_reserved_out;
    v_shortage:=GREATEST(v_product.requested_base_qty-GREATEST(v_available,0),0);
    v_projected_negative:=abs(LEAST(v_available-v_product.requested_base_qty,0));

    v_policy.master_version:=NULL;
    v_permission.master_version:=NULL;
    IF v_shortage>0 THEN
      IF v_product.has_bundle_source THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED';
      END IF;
      IF NOT EXISTS(SELECT 1 FROM public.company_features feature
        WHERE feature.company_id=v_company
          AND feature.feature_code='pos_negative_stock_enabled'
          AND feature.is_enabled) THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED';
      END IF;
      SELECT policy.* INTO v_policy FROM public.pos_negative_stock_policies policy
      WHERE policy.company_id=v_company AND policy.is_active FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'; END IF;
      IF NOT EXISTS(SELECT 1 FROM public.warehouses warehouse
        WHERE warehouse.company_id=v_company AND warehouse.id=v_warehouse
          AND warehouse.allow_negative_stock) THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED';
      END IF;
      SELECT permission.* INTO v_permission
      FROM public.pos_negative_stock_permissions permission
      WHERE permission.company_id=v_company AND permission.warehouse_id=v_warehouse
        AND permission.user_id=v_actor AND permission.is_active
        AND (permission.valid_until IS NULL OR permission.valid_until>v_now)
      FOR UPDATE;
      IF NOT FOUND THEN RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'; END IF;
      IF v_policy.require_reason AND v_reason IS NULL THEN
        RAISE EXCEPTION 'NEGATIVE_STOCK_REASON_REQUIRED';
      END IF;
      IF v_policy.company_negative_limit_base_qty IS NOT NULL
         AND v_projected_negative>v_policy.company_negative_limit_base_qty THEN
        RAISE EXCEPTION 'COMPANY_NEGATIVE_STOCK_LIMIT_EXCEEDED';
      END IF;
      IF v_permission.max_negative_base_qty IS NOT NULL
         AND v_projected_negative>v_permission.max_negative_base_qty THEN
        RAISE EXCEPTION 'USER_NEGATIVE_STOCK_LIMIT_EXCEEDED';
      END IF;
    END IF;

    v_available_remaining:=GREATEST(v_available,0);
    FOR v_requirement IN
      SELECT requirement.* FROM public.sale_stock_requirements requirement
      WHERE requirement.company_id=v_company AND requirement.sales_id=p_sales_id
        AND requirement.stock_product_id=v_product.stock_product_id
      ORDER BY requirement.id
    LOOP
      v_line_available:=LEAST(v_requirement.quantity_base,v_available_remaining);
      v_available_remaining:=v_available_remaining-v_line_available;
      INSERT INTO public.sales_stock_reservation_lines(company_id,reservation_id,
        sales_id,sales_detail_id,stock_requirement_id,stock_product_id,warehouse_id,
        requested_base_qty,reserved_base_qty,available_base_qty_snapshot,
        shortage_base_qty,negative_policy_version,negative_permission_version)
      VALUES(v_company,v_reservation,p_sales_id,v_requirement.sales_detail_id,
        v_requirement.id,v_requirement.stock_product_id,v_warehouse,
        v_requirement.quantity_base,v_requirement.quantity_base,v_line_available,
        v_requirement.quantity_base-v_line_available,
        CASE WHEN v_requirement.quantity_base>v_line_available
          THEN v_policy.master_version END,
        CASE WHEN v_requirement.quantity_base>v_line_available
          THEN v_permission.master_version END);
      v_line_count:=v_line_count+1;
      IF v_requirement.quantity_base>v_line_available THEN
        v_shortage_count:=v_shortage_count+1;
      END IF;
    END LOOP;
  END LOOP;

  UPDATE public.sales_headers SET order_runtime_status='RESERVED',
    confirmed_at=v_now,confirmed_by=v_actor,
    confirmation_idempotency_key=p_idempotency_key,
    reservation_version=reservation_version+1,
    sales_warehouse_id=v_warehouse,
    edit_lock_owner_id=NULL,edit_lock_session_id=NULL,
    edit_lock_acquired_at=NULL,edit_lock_heartbeat_at=NULL,
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=p_sales_id;

  INSERT INTO public.sales_stock_reservation_audit(company_id,reservation_id,sales_id,
    action,actor_id,idempotency_key,after_state)
  VALUES(v_company,v_reservation,p_sales_id,'CONFIRM',v_actor,p_idempotency_key,
    jsonb_build_object('status','OPEN','reservedBaseQty',v_total,
      'lineCount',v_line_count,'shortageLineCount',v_shortage_count,
      'negativeReason',v_reason,'masterVersion',v_sale.master_version+1));

  RETURN jsonb_build_object('salesId',p_sales_id,'reservationId',v_reservation,
    'orderRuntimeStatus','RESERVED','reservedBaseQty',v_total,
    'lineCount',v_line_count,'shortageLineCount',v_shortage_count,
    'masterVersion',v_sale.master_version+1,'exactRetry',FALSE);
END
$$;

CREATE FUNCTION public.confirm_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RETURN private.confirm_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_negative_stock_reason);
END
$$;

CREATE FUNCTION private.cancel_pos_sales_order_core(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
  v_sale public.sales_headers%ROWTYPE;v_reservation public.sales_stock_reservations%ROWTYPE;
  v_now TIMESTAMPTZ:=clock_timestamp();v_reason TEXT:=NULLIF(btrim(p_reason),'');
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'CANCEL_REASON_REQUIRED'; END IF;

  IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_audit audit
    WHERE audit.company_id=v_company AND audit.action='RELEASE'
      AND audit.idempotency_key=p_idempotency_key AND audit.sales_id<>p_sales_id) THEN
    RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
  END IF;

  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  SELECT reservation.* INTO v_reservation FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=v_company AND reservation.sales_id=p_sales_id FOR UPDATE;

  IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_audit audit
    WHERE audit.company_id=v_company AND audit.sales_id=p_sales_id
      AND audit.action='RELEASE' AND audit.idempotency_key=p_idempotency_key) THEN
    IF EXISTS(SELECT 1 FROM public.sales_stock_reservation_audit audit
      WHERE audit.company_id=v_company AND audit.sales_id=p_sales_id
        AND audit.action='RELEASE' AND audit.idempotency_key=p_idempotency_key
        AND audit.after_state->>'reason' IS DISTINCT FROM v_reason) THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN jsonb_build_object('salesId',p_sales_id,'reservationId',v_reservation.id,
      'orderRuntimeStatus','CANCELED','masterVersion',v_sale.master_version,
      'exactRetry',TRUE);
  END IF;
  IF v_sale.master_version IS DISTINCT FROM p_master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  IF v_sale.document_status<>'DRAFT'
     OR v_sale.order_runtime_status NOT IN('CONFIRMED','RESERVED')
     OR v_reservation.id IS NULL OR v_reservation.status<>'OPEN' THEN
    RAISE EXCEPTION 'SALES_ORDER_FINAL';
  END IF;
  IF NOT (EXISTS(SELECT 1 FROM public.cashier_sessions session
      WHERE session.company_id=v_company AND session.cashier_id=v_actor
        AND session.store_id=v_sale.store_id
        AND session.status='OPEN'::public.session_status)
    OR public.private_user_has_any_company_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[])
    OR public.private_user_has_any_store_role(v_sale.store_id,
      ARRAY['STORE_MANAGER']::TEXT[])) THEN
    RAISE EXCEPTION 'SALES_ORDER_CANCEL_FORBIDDEN';
  END IF;
  IF v_reservation.total_dispatched_base_qty>0 THEN
    RAISE EXCEPTION 'SALES_ORDER_DISPATCH_STARTED';
  END IF;

  UPDATE public.sales_stock_reservation_lines SET
    released_base_qty=reserved_base_qty-dispatched_base_qty,
    updated_at=v_now WHERE company_id=v_company AND reservation_id=v_reservation.id;
  UPDATE public.sales_stock_reservations SET status='RELEASED',
    total_released_base_qty=total_reserved_base_qty-total_dispatched_base_qty,
    released_by=v_actor,released_at=v_now,release_reason=v_reason,
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=v_reservation.id;
  UPDATE public.sales_headers SET document_status='CANCELED',
    order_runtime_status='CANCELED',canceled_at=v_now,canceled_by=v_actor,
    cancel_reason=v_reason,reservation_version=reservation_version+1,
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=v_company AND id=p_sales_id;
  INSERT INTO public.sales_stock_reservation_audit(company_id,reservation_id,sales_id,
    action,actor_id,idempotency_key,before_state,after_state)
  VALUES(v_company,v_reservation.id,p_sales_id,'RELEASE',v_actor,p_idempotency_key,
    jsonb_build_object('status',v_reservation.status,
      'releasedBaseQty',v_reservation.total_released_base_qty),
    jsonb_build_object('status','RELEASED','releasedBaseQty',
      v_reservation.total_reserved_base_qty-v_reservation.total_dispatched_base_qty,
      'reason',v_reason,'masterVersion',v_sale.master_version+1));
  RETURN jsonb_build_object('salesId',p_sales_id,'reservationId',v_reservation.id,
    'orderRuntimeStatus','CANCELED','masterVersion',v_sale.master_version+1,
    'exactRetry',FALSE);
END
$$;

CREATE FUNCTION public.cancel_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
BEGIN
  RETURN private.cancel_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_reason);
END
$$;

CREATE FUNCTION public.get_pos_sales_orders(p_store_id UUID DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
  IF p_store_id IS NOT NULL AND NOT (
    public.private_user_has_any_company_role(v_company,
      ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
    OR public.private_user_has_any_store_role(p_store_id,
      ARRAY['CASHIER','STORE_MANAGER']::TEXT[])) THEN
    RAISE EXCEPTION 'SALES_ORDER_VIEW_FORBIDDEN';
  END IF;
  RETURN jsonb_build_object(
    'orders',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.planned_order_date NULLS FIRST,row_data.updated_at DESC),'[]'::JSONB)
      FROM (SELECT sale.id,sale.draft_no,sale.store_id,store.store_name,
          sale.customer_id,customer.name customer_name,sale.order_timing_mode,
          sale.planned_order_date,sale.order_runtime_status,sale.grand_total_after_rounding,
          sale.master_version,sale.reservation_version,sale.confirmed_at,sale.updated_at,
          reservation.id reservation_id,reservation.status reservation_status,
          reservation.total_reserved_base_qty,reservation.total_released_base_qty,
          reservation.total_dispatched_base_qty,reservation.master_version reservation_master_version
        FROM public.sales_headers sale
        JOIN public.stores store ON store.company_id=sale.company_id AND store.id=sale.store_id
        JOIN public.customers customer ON customer.company_id=sale.company_id
          AND customer.id=sale.customer_id
        JOIN public.sales_stock_reservations reservation
          ON reservation.company_id=sale.company_id AND reservation.sales_id=sale.id
        WHERE sale.company_id=v_company
          AND sale.order_runtime_status IN('CONFIRMED','RESERVED','PARTIALLY_DISPATCHED',
            'DISPATCHED','DELIVERED')
          AND (p_store_id IS NULL OR sale.store_id=p_store_id)
          AND (public.private_user_has_any_company_role(v_company,
              ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
            OR public.private_user_has_any_store_role(sale.store_id,
              ARRAY['CASHIER','STORE_MANAGER']::TEXT[]))) row_data),
    'reservationLines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.sales_id,row_data.stock_product_id,row_data.id),'[]'::JSONB)
      FROM (SELECT line.id,line.reservation_id,line.sales_id,line.sales_detail_id,
          line.stock_product_id,product.sku product_sku,product.name product_name,
          line.warehouse_id,warehouse.name warehouse_name,line.requested_base_qty,
          line.reserved_base_qty,line.released_base_qty,line.dispatched_base_qty,
          line.available_base_qty_snapshot,line.shortage_base_qty
        FROM public.sales_stock_reservation_lines line
        JOIN public.sales_headers sale ON sale.company_id=line.company_id AND sale.id=line.sales_id
        JOIN public.products product ON product.company_id=line.company_id
          AND product.id=line.stock_product_id
        JOIN public.warehouses warehouse ON warehouse.company_id=line.company_id
          AND warehouse.id=line.warehouse_id
        WHERE line.company_id=v_company AND (p_store_id IS NULL OR sale.store_id=p_store_id)
          AND (public.private_user_has_any_company_role(v_company,
              ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
            OR public.private_user_has_any_store_role(sale.store_id,
              ARRAY['CASHIER','STORE_MANAGER']::TEXT[]))) row_data),
    'availability',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.warehouse_id,row_data.product_name),'[]'::JSONB)
      FROM (SELECT line.warehouse_id,line.stock_product_id,product.name product_name,
          COALESCE(stock.stock_qty,0) on_hand_base_qty,
          sum(line.reserved_base_qty-line.released_base_qty-line.dispatched_base_qty)
            reserved_out_base_qty,
          COALESCE(stock.stock_qty,0)-sum(line.reserved_base_qty-
            line.released_base_qty-line.dispatched_base_qty) available_to_sell_base_qty
        FROM public.sales_stock_reservation_lines line
        JOIN public.sales_stock_reservations reservation
          ON reservation.company_id=line.company_id AND reservation.id=line.reservation_id
        JOIN public.sales_headers sale ON sale.company_id=line.company_id AND sale.id=line.sales_id
        JOIN public.products product ON product.company_id=line.company_id
          AND product.id=line.stock_product_id
        LEFT JOIN public.product_stocks stock ON stock.company_id=line.company_id
          AND stock.warehouse_id=line.warehouse_id AND stock.product_id=line.stock_product_id
        WHERE line.company_id=v_company AND reservation.status IN('OPEN','PARTIALLY_DISPATCHED')
          AND (p_store_id IS NULL OR sale.store_id=p_store_id)
          AND (public.private_user_has_any_company_role(v_company,
              ARRAY['COMPANY_OWNER','COMPANY_ADMIN','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING']::TEXT[])
            OR public.private_user_has_any_store_role(sale.store_id,
              ARRAY['CASHIER','STORE_MANAGER']::TEXT[]))
        GROUP BY line.warehouse_id,line.stock_product_id,product.name,stock.stock_qty
      ) row_data));
END
$$;

REVOKE ALL ON FUNCTION private.confirm_pos_sales_order_core(UUID,BIGINT,UUID,TEXT),
  private.cancel_pos_sales_order_core(UUID,BIGINT,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.confirm_pos_sales_order_core(UUID,BIGINT,UUID,TEXT),
  private.cancel_pos_sales_order_core(UUID,BIGINT,UUID,TEXT) TO service_role;
REVOKE ALL ON FUNCTION public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.get_pos_sales_orders(UUID) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.get_pos_sales_orders(UUID) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828110000','odr_phase2b_atomic_sales_order_reservation_runtime',
  'Atomic POS Sales Order confirm/cancel/read runtime with server-derived Reserved Out, projected-negative authorization, exact retry, audit, and zero Stock/FIFO/Movement/Finance effect');

COMMIT;
