BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828150000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-4A required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828160000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF EXISTS(SELECT 1 FROM public.sales_order_procurement_demands)
    OR EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_lines)
    OR EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected procurement demand rows';
  END IF;
END
$guard$;

CREATE FUNCTION private.refresh_sales_order_procurement_demand(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,
  p_idempotency_key UUID,p_action TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%ROWTYPE;
  v_session public.cashier_sessions%ROWTYPE;
  v_reservation public.sales_stock_reservations%ROWTYPE;
  v_demand public.sales_order_procurement_demands%ROWTYPE;
  v_line RECORD;
  v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
  v_audit_action TEXT;
  v_total NUMERIC(24,6):=0;
  v_released NUMERIC(24,6):=0;
  v_now TIMESTAMPTZ:=clock_timestamp();
  v_existing_sale UUID;
  v_line_count INTEGER:=0;
BEGIN
  IF p_company_id IS NULL OR p_sales_id IS NULL OR p_actor_id IS NULL THEN
    RAISE EXCEPTION 'PROCUREMENT_DEMAND_CONTEXT_REQUIRED';
  END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF v_action NOT IN('CONFIRM','CANCEL','RECONCILE') THEN
    RAISE EXCEPTION 'PROCUREMENT_DEMAND_ACTION_INVALID';
  END IF;
  v_audit_action:=CASE WHEN v_action='CONFIRM' THEN 'INITIALIZE'
    ELSE 'QUANTITY_DELTA' END;

  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  SELECT session.* INTO v_session FROM public.cashier_sessions session
  WHERE session.company_id=p_company_id AND session.id=v_sale.session_id
  FOR UPDATE;
  IF NOT FOUND OR v_session.store_id<>v_sale.store_id
    OR v_session.sales_warehouse_id<>v_sale.sales_warehouse_id THEN
    RAISE EXCEPTION 'PROCUREMENT_DEMAND_SESSION_SCOPE_MISMATCH';
  END IF;
  SELECT reservation.* INTO v_reservation
  FROM public.sales_stock_reservations reservation
  WHERE reservation.company_id=p_company_id AND reservation.sales_id=p_sales_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RESERVATION_STATE_MISMATCH'; END IF;

  IF NOT EXISTS(SELECT 1 FROM public.sales_stock_reservation_lines line
    WHERE line.company_id=p_company_id
      AND line.reservation_id=v_reservation.id AND line.shortage_base_qty>0)
    AND NOT EXISTS(SELECT 1
      FROM public.sales_order_procurement_demand_lines demand_line
      WHERE demand_line.company_id=p_company_id
        AND demand_line.sales_id=p_sales_id) THEN
    RETURN jsonb_build_object('demandId',NULL,'demandLineCount',0,
      'demandBaseQty',0,'releasedBaseQty',0,'exactRetry',FALSE);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::TEXT||':PROCUREMENT:'||v_sale.session_id::TEXT,0));
  SELECT demand.* INTO v_demand
  FROM public.sales_order_procurement_demands demand
  WHERE demand.company_id=p_company_id
    AND demand.cashier_session_id=v_sale.session_id FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.sales_order_procurement_demands(
      company_id,store_id,warehouse_id,cashier_session_id,status,
      session_closed_at,created_by)
    VALUES(p_company_id,v_sale.store_id,v_sale.sales_warehouse_id,v_sale.session_id,
      CASE WHEN v_session.status='OPEN'::public.session_status
        THEN 'OPEN' ELSE 'FROZEN' END,
      CASE WHEN v_session.status='OPEN'::public.session_status
        THEN NULL ELSE COALESCE(v_session.closed_at,v_now) END,p_actor_id)
    RETURNING * INTO v_demand;
  END IF;

  SELECT (audit.after_state->>'saleId')::UUID INTO v_existing_sale
  FROM public.sales_order_procurement_demand_audit audit
  WHERE audit.company_id=p_company_id AND audit.demand_id=v_demand.id
    AND audit.demand_line_id IS NULL
    AND audit.idempotency_key=p_idempotency_key;
  IF FOUND THEN
    IF v_existing_sale IS DISTINCT FROM p_sales_id THEN
      RAISE EXCEPTION 'IDEMPOTENCY_PAYLOAD_CONFLICT';
    END IF;
    RETURN jsonb_build_object('demandId',v_demand.id,
      'demandLineCount',(SELECT count(*)
        FROM public.sales_order_procurement_demand_lines line
        WHERE line.company_id=p_company_id AND line.demand_id=v_demand.id),
      'demandBaseQty',v_demand.total_demand_base_qty,
      'releasedBaseQty',v_demand.total_released_base_qty,
      'masterVersion',v_demand.master_version,'exactRetry',TRUE);
  END IF;

  FOR v_line IN
    SELECT line.* FROM public.sales_stock_reservation_lines line
    WHERE line.company_id=p_company_id
      AND line.reservation_id=v_reservation.id AND line.shortage_base_qty>0
    ORDER BY line.id FOR UPDATE
  LOOP
    INSERT INTO public.sales_order_procurement_demand_lines(
      company_id,demand_id,reservation_line_id,sales_id,stock_product_id,
      warehouse_id,demand_base_qty,released_base_qty,
      source_reservation_version,status)
    VALUES(p_company_id,v_demand.id,v_line.id,p_sales_id,
      v_line.stock_product_id,v_line.warehouse_id,v_line.shortage_base_qty,
      LEAST(v_line.shortage_base_qty,v_line.released_base_qty),
      v_reservation.master_version,
      CASE WHEN v_line.released_base_qty>=v_line.shortage_base_qty
        THEN 'CLOSED' ELSE 'OPEN' END)
    ON CONFLICT(company_id,reservation_line_id) DO UPDATE SET
      demand_base_qty=EXCLUDED.demand_base_qty,
      released_base_qty=EXCLUDED.released_base_qty,
      source_reservation_version=EXCLUDED.source_reservation_version,
      status=CASE
        WHEN public.sales_order_procurement_demand_lines.stock_request_line_id
          IS NOT NULL AND EXCLUDED.released_base_qty<EXCLUDED.demand_base_qty
          THEN 'REQUESTED'
        WHEN EXCLUDED.released_base_qty>=EXCLUDED.demand_base_qty THEN 'CLOSED'
        ELSE 'OPEN' END,
      master_version=public.sales_order_procurement_demand_lines.master_version+1,
      updated_at=v_now;
  END LOOP;

  SELECT COALESCE(sum(line.demand_base_qty),0),
    COALESCE(sum(line.released_base_qty),0),count(*)
  INTO v_total,v_released,v_line_count
  FROM public.sales_order_procurement_demand_lines line
  WHERE line.company_id=p_company_id AND line.demand_id=v_demand.id;

  UPDATE public.sales_order_procurement_demands SET
    total_demand_base_qty=v_total,total_released_base_qty=v_released,
    status=CASE WHEN v_session.status='OPEN'::public.session_status THEN 'OPEN'
      WHEN v_total=v_released THEN 'CLOSED' ELSE 'FROZEN' END,
    session_closed_at=CASE WHEN v_session.status='OPEN'::public.session_status
      THEN NULL ELSE COALESCE(session_closed_at,v_session.closed_at,v_now) END,
    master_version=master_version+1,updated_at=v_now
  WHERE company_id=p_company_id AND id=v_demand.id
  RETURNING * INTO v_demand;

  INSERT INTO public.sales_order_procurement_demand_audit(
    company_id,demand_id,action,idempotency_key,actor_id,after_state)
  VALUES(p_company_id,v_demand.id,v_audit_action,p_idempotency_key,p_actor_id,
    jsonb_build_object('saleId',p_sales_id,'sourceAction',v_action,
      'demandBaseQty',v_total,'releasedBaseQty',v_released,
      'lineCount',v_line_count,'masterVersion',v_demand.master_version));

  RETURN jsonb_build_object('demandId',v_demand.id,
    'demandLineCount',v_line_count,'demandBaseQty',v_total,
    'releasedBaseQty',v_released,'masterVersion',v_demand.master_version,
    'exactRetry',FALSE);
END
$$;

CREATE FUNCTION private.freeze_session_procurement_demand(
  p_company_id UUID,p_cashier_session_id UUID,p_actor_id UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_demand public.sales_order_procurement_demands%ROWTYPE;
  v_now TIMESTAMPTZ:=clock_timestamp();v_key UUID;
BEGIN
  SELECT demand.* INTO v_demand
  FROM public.sales_order_procurement_demands demand
  WHERE demand.company_id=p_company_id
    AND demand.cashier_session_id=p_cashier_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('procurementDemandId',NULL,
      'procurementDemandStatus',NULL,'procurementDemandFrozen',FALSE);
  END IF;
  v_key:=md5(p_company_id::TEXT||':'||p_cashier_session_id::TEXT||
    ':SESSION_FREEZE')::UUID;
  IF v_demand.status='OPEN' THEN
    UPDATE public.sales_order_procurement_demands SET status=CASE
        WHEN total_demand_base_qty=total_released_base_qty THEN 'CLOSED'
        ELSE 'FROZEN' END,
      session_closed_at=v_now,master_version=master_version+1,updated_at=v_now
    WHERE company_id=p_company_id AND id=v_demand.id
    RETURNING * INTO v_demand;
    INSERT INTO public.sales_order_procurement_demand_audit(
      company_id,demand_id,action,idempotency_key,actor_id,after_state)
    VALUES(p_company_id,v_demand.id,'SESSION_FREEZE',v_key,p_actor_id,
      jsonb_build_object('status',v_demand.status,
        'sessionId',p_cashier_session_id,'masterVersion',v_demand.master_version))
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN jsonb_build_object('procurementDemandId',v_demand.id,
    'procurementDemandStatus',v_demand.status,
    'procurementDemandFrozen',v_demand.status IN('FROZEN','CLOSED'));
END
$$;

CREATE FUNCTION public.get_purchase_procurement_demands()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  RETURN jsonb_build_object('companyId',v_company,
    'demands',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.updated_at DESC,row_data.id),'[]'::JSONB)
      FROM (SELECT demand.id,demand.store_id,store.store_name,
          demand.warehouse_id,warehouse.name warehouse_name,
          demand.cashier_session_id,session.session_code,demand.status,
          demand.total_demand_base_qty,demand.total_released_base_qty,
          demand.stock_request_document_id,demand.master_version,
          demand.session_closed_at,demand.created_at,demand.updated_at
        FROM public.sales_order_procurement_demands demand
        JOIN public.stores store ON store.company_id=demand.company_id
          AND store.id=demand.store_id
        JOIN public.warehouses warehouse ON warehouse.company_id=demand.company_id
          AND warehouse.id=demand.warehouse_id
        JOIN public.cashier_sessions session ON session.company_id=demand.company_id
          AND session.id=demand.cashier_session_id
        WHERE demand.company_id=v_company
        ORDER BY demand.updated_at DESC,demand.id LIMIT 500) row_data),
    'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(row_data)
      ORDER BY row_data.demand_id,product.name,row_data.id),'[]'::JSONB)
      FROM (SELECT line.id,line.demand_id,line.sales_id,line.reservation_line_id,
          line.stock_product_id,product.sku product_sku,product.name product_name,
          line.warehouse_id,line.demand_base_qty,line.released_base_qty,
          line.demand_base_qty-line.released_base_qty open_demand_base_qty,
          line.stock_request_line_id,line.status,line.master_version,
          line.updated_at
        FROM public.sales_order_procurement_demand_lines line
        JOIN public.products product ON product.company_id=line.company_id
          AND product.id=line.stock_product_id
        WHERE line.company_id=v_company
        ORDER BY line.demand_id,product.name,line.id LIMIT 10000) row_data));
END
$$;

CREATE OR REPLACE FUNCTION public.confirm_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,
  p_negative_stock_reason TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_documents JSONB;v_demand JSONB;
  v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  v_result:=private.confirm_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_negative_stock_reason);
  v_documents:=private.ensure_confirmed_order_documents(v_company,p_sales_id);
  v_demand:=private.refresh_sales_order_procurement_demand(
    v_company,p_sales_id,v_actor,p_idempotency_key,'CONFIRM');
  RETURN v_result||jsonb_build_object('documents',v_documents,
    'procurementDemand',v_demand);
END
$$;

CREATE OR REPLACE FUNCTION public.cancel_pos_sales_order(
  p_sales_id UUID,p_master_version BIGINT,p_idempotency_key UUID,p_reason TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_demand JSONB;
  v_company UUID:=public.private_active_company_id();v_actor UUID:=auth.uid();
BEGIN
  v_result:=private.cancel_pos_sales_order_core(p_sales_id,p_master_version,
    p_idempotency_key,p_reason);
  PERFORM private.cancel_confirmed_order_delivery(v_company,p_sales_id,p_reason);
  v_demand:=private.refresh_sales_order_procurement_demand(
    v_company,p_sales_id,v_actor,p_idempotency_key,'CANCEL');
  RETURN v_result||jsonb_build_object('procurementDemand',v_demand);
END
$$;

ALTER FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
  RENAME TO odr4b_close_cashier_session_legacy;
ALTER FUNCTION public.odr4b_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
  SET SCHEMA private;

CREATE FUNCTION public.close_cashier_session(
  p_cashier_session_id UUID,p_master_version BIGINT,
  p_closing_cash_actual NUMERIC
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();
  v_actor UUID:=auth.uid();v_result JSONB;v_demand JSONB;
BEGIN
  v_result:=private.odr4b_close_cashier_session_legacy(
    p_cashier_session_id,p_master_version,p_closing_cash_actual);
  v_demand:=private.freeze_session_procurement_demand(
    v_company,p_cashier_session_id,v_actor);
  RETURN v_result||v_demand;
END
$$;

REVOKE ALL ON FUNCTION
  private.refresh_sales_order_procurement_demand(UUID,UUID,UUID,UUID,TEXT),
  private.freeze_session_procurement_demand(UUID,UUID,UUID),
  private.odr4b_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.refresh_sales_order_procurement_demand(UUID,UUID,UUID,UUID,TEXT),
  private.freeze_session_procurement_demand(UUID,UUID,UUID),
  private.odr4b_close_cashier_session_legacy(UUID,BIGINT,NUMERIC)
TO service_role;

REVOKE ALL ON FUNCTION public.get_purchase_procurement_demands(),
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.close_cashier_session(UUID,BIGINT,NUMERIC)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_procurement_demands(),
  public.confirm_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.cancel_pos_sales_order(UUID,BIGINT,UUID,TEXT),
  public.close_cashier_session(UUID,BIGINT,NUMERIC)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828160000','odr_phase4b_session_procurement_demand_runtime',
  'Atomic reservation-shortage demand refresh on Sales Order confirm/cancel, Session freeze integration, composed Purchasing read, exact retry and private runtime boundary; no Stock Request, Supplier Order, Stock, or Finance mutation');

NOTIFY pgrst,'reload schema';
COMMIT;
