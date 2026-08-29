BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828180000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-4D foundation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828190000') THEN
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
  IF EXISTS(SELECT 1 FROM public.sales_order_procurement_amendments)
    OR EXISTS(SELECT 1 FROM public.sales_order_procurement_amendment_audit) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: unexpected amendment rows';
  END IF;
END
$guard$;

ALTER TABLE public.sales_order_procurement_amendments
  DROP CONSTRAINT sales_order_procurement_amendments_reason_check,
  ADD CONSTRAINT sales_order_procurement_amendments_reason_check CHECK(reason IN(
    'UNALLOCATED','DRAFT_SYNC_PENDING','AMBIGUOUS_DRAFT_TARGET',
    'MIXED_MANUAL_DRAFT_LINE','FINAL_PO_IMMUTABLE',
    'QUANTITY_DECREASE_REQUIRES_REVIEW'));

ALTER TABLE public.stock_request_lines
  ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE;

CREATE OR REPLACE FUNCTION private.trg_g5_guard_request_line_mutation()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE v_document UUID;v_status TEXT;v_source TEXT;
BEGIN
  v_document:=CASE WHEN TG_OP='DELETE' THEN OLD.document_id
    ELSE NEW.document_id END;
  SELECT document.status,document.request_source INTO v_status,v_source
  FROM public.stock_request_documents document WHERE document.id=v_document;
  IF v_status IS NULL THEN RAISE EXCEPTION 'STOCK_REQUEST_NOT_FOUND'; END IF;
  IF v_status<>'DRAFT' AND NOT (v_source='SALES_ORDER_RESERVATION'
      AND v_status IN('SUBMITTED','ORDERED')) THEN
    RAISE EXCEPTION 'FINAL_STOCK_REQUEST_LINES_IMMUTABLE';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.reconcile_session_procurement_request(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%ROWTYPE;
  v_demand public.sales_order_procurement_demands%ROWTYPE;
  v_request public.stock_request_documents%ROWTYPE;
  v_request_line public.stock_request_lines%ROWTYPE;
  v_product RECORD;v_existing RECORD;v_amendment RECORD;
  v_desired NUMERIC(24,6);v_draft NUMERIC(24,6);v_final NUMERIC(24,6);
  v_committed NUMERIC(24,6);v_delta NUMERIC(24,6);v_line_qty NUMERIC(24,6);
  v_draft_targets INTEGER;v_mixed_rows INTEGER;v_reason TEXT;
  v_line_id UUID;v_line_count INTEGER;v_total NUMERIC(24,6);
  v_line_no INTEGER;v_now TIMESTAMPTZ:=clock_timestamp();v_sync_key UUID;
  v_before JSONB;v_after JSONB;v_changed BOOLEAN:=FALSE;
BEGIN
  IF p_company_id IS NULL OR p_sales_id IS NULL OR p_actor_id IS NULL
    OR p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'PROCUREMENT_RECONCILIATION_CONTEXT_REQUIRED';
  END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  SELECT demand.* INTO v_demand
  FROM public.sales_order_procurement_demands demand
  WHERE demand.company_id=p_company_id
    AND demand.cashier_session_id=v_sale.session_id FOR UPDATE;
  IF NOT FOUND OR v_demand.stock_request_document_id IS NULL THEN
    RETURN jsonb_build_object('stockRequestId',NULL,'reconciled',FALSE,
      'reason','NO_MANAGED_REQUEST');
  END IF;
  v_sync_key:=md5(p_company_id::TEXT||':'||v_demand.id::TEXT||':'||
    p_idempotency_key::TEXT||':REQUEST_RECONCILE')::UUID;
  IF EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_audit audit
    WHERE audit.company_id=p_company_id AND audit.demand_id=v_demand.id
      AND audit.demand_line_id IS NULL
      AND audit.idempotency_key=v_sync_key) THEN
    RETURN jsonb_build_object('stockRequestId',v_demand.stock_request_document_id,
      'reconciled',TRUE,'exactRetry',TRUE);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::TEXT||':PROCUREMENT-RECONCILE:'||v_demand.id::TEXT,0));
  SELECT request.* INTO v_request FROM public.stock_request_documents request
  WHERE request.company_id=p_company_id
    AND request.id=v_demand.stock_request_document_id FOR UPDATE;
  IF NOT FOUND OR v_request.request_source<>'SALES_ORDER_RESERVATION'
    OR v_request.requesting_session_id<>v_demand.cashier_session_id
    OR v_request.status NOT IN('SUBMITTED','ORDERED') THEN
    RAISE EXCEPTION 'MANAGED_STOCK_REQUEST_STATE_INVALID';
  END IF;
  v_before:=to_jsonb(v_request);

  FOR v_product IN
    SELECT source.product_id,product.sku,product.name,product.uom_id,
      uom.name uom_name,sum(source.desired_base_qty) desired_base_qty
    FROM (SELECT line.stock_product_id product_id,
        line.demand_base_qty-line.released_base_qty desired_base_qty
      FROM public.sales_order_procurement_demand_lines line
      WHERE line.company_id=p_company_id AND line.demand_id=v_demand.id
        AND line.demand_base_qty>line.released_base_qty
      UNION ALL
      SELECT line.product_id,0::NUMERIC
      FROM public.stock_request_lines line
      WHERE line.company_id=p_company_id AND line.document_id=v_request.id) source
    JOIN public.products product ON product.company_id=p_company_id
      AND product.id=source.product_id
    JOIN public.uoms uom ON uom.company_id=product.company_id
      AND uom.id=product.uom_id
    GROUP BY source.product_id,product.sku,product.name,product.uom_id,uom.name
    ORDER BY product.name,source.product_id
  LOOP
    v_desired:=v_product.desired_base_qty;
    SELECT line.* INTO v_request_line FROM public.stock_request_lines line
    WHERE line.company_id=p_company_id AND line.document_id=v_request.id
      AND line.product_id=v_product.product_id FOR UPDATE;

    SELECT COALESCE(sum(allocation.allocated_base_qty)
        FILTER(WHERE order_document.status='DRAFT'),0),
      COALESCE(sum(allocation.allocated_base_qty) FILTER(WHERE
        order_document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),0),
      count(DISTINCT order_document.id) FILTER(WHERE order_document.status='DRAFT'),
      count(DISTINCT order_line.id) FILTER(WHERE order_document.status='DRAFT'
        AND order_line.ordered_base_qty IS DISTINCT FROM (SELECT COALESCE(
          sum(a2.allocated_base_qty),0)
          FROM public.supplier_order_request_allocations a2
          WHERE a2.company_id=order_line.company_id
            AND a2.supplier_order_line_id=order_line.id))
    INTO v_draft,v_final,v_draft_targets,v_mixed_rows
    FROM public.supplier_order_request_allocations allocation
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    JOIN public.supplier_order_documents order_document
      ON order_document.company_id=order_line.company_id
     AND order_document.id=order_line.document_id
    WHERE allocation.company_id=p_company_id
      AND allocation.stock_request_line_id=v_request_line.id;
    v_draft:=COALESCE(v_draft,0);v_final:=COALESCE(v_final,0);
    v_draft_targets:=COALESCE(v_draft_targets,0);
    v_mixed_rows:=COALESCE(v_mixed_rows,0);v_committed:=v_draft+v_final;

    IF v_request_line.id IS NULL AND v_desired>0 THEN
      SELECT COALESCE(max(line.line_no),0)+1 INTO v_line_no
      FROM public.stock_request_lines line
      WHERE line.company_id=p_company_id AND line.document_id=v_request.id;
      INSERT INTO public.stock_request_lines(
        company_id,document_id,line_no,client_line_key,product_id,
        requested_uom_id,requested_qty,factor_to_base_snapshot,
        requested_base_qty,product_sku_snapshot,product_name_snapshot,
        requested_uom_name_snapshot,notes
      ) VALUES(p_company_id,v_request.id,v_line_no,gen_random_uuid(),
        v_product.product_id,v_product.uom_id,v_desired,1,v_desired,
        v_product.sku,v_product.name,v_product.uom_name,
        'Rekonsiliasi perubahan order setelah sesi ditutup')
      RETURNING id INTO v_line_id;
      v_request_line.id:=v_line_id;v_changed:=TRUE;
    ELSIF v_request_line.id IS NOT NULL THEN
      v_line_qty:=GREATEST(v_desired,v_committed);
      IF v_line_qty>0 AND (v_request_line.requested_base_qty<>v_line_qty
          OR NOT v_request_line.is_active) THEN
        UPDATE public.stock_request_lines SET requested_qty=v_line_qty,
          factor_to_base_snapshot=1,requested_base_qty=v_line_qty,is_active=TRUE
        WHERE company_id=p_company_id AND id=v_request_line.id;
        v_changed:=TRUE;
      ELSIF v_line_qty=0 THEN
        UPDATE public.sales_order_procurement_demand_lines SET
          status='CLOSED',
          master_version=master_version+1,updated_at=v_now
        WHERE company_id=p_company_id AND demand_id=v_demand.id
          AND stock_product_id=v_product.product_id;
        UPDATE public.stock_request_lines SET is_active=FALSE
        WHERE company_id=p_company_id AND id=v_request_line.id
          AND is_active;
        v_changed:=TRUE;
      END IF;
      v_line_id:=v_request_line.id;
    END IF;

    UPDATE public.sales_order_procurement_demand_lines SET
      stock_request_line_id=v_line_id,
      status=CASE WHEN released_base_qty>=demand_base_qty
        THEN 'CLOSED' ELSE 'REQUESTED' END,
      master_version=master_version+1,updated_at=v_now
    WHERE company_id=p_company_id AND demand_id=v_demand.id
      AND stock_product_id=v_product.product_id
      AND stock_request_line_id IS DISTINCT FROM v_line_id;

    v_delta:=v_desired-v_committed;
    v_reason:=CASE
      WHEN v_delta=0 THEN NULL
      WHEN v_final>0 THEN 'FINAL_PO_IMMUTABLE'
      WHEN v_draft_targets=0 THEN 'UNALLOCATED'
      WHEN v_draft_targets>1 THEN 'AMBIGUOUS_DRAFT_TARGET'
      WHEN v_mixed_rows>0 THEN 'MIXED_MANUAL_DRAFT_LINE'
      WHEN v_delta<0 THEN 'QUANTITY_DECREASE_REQUIRES_REVIEW'
      ELSE 'DRAFT_SYNC_PENDING' END;
    SELECT amendment.* INTO v_amendment
    FROM public.sales_order_procurement_amendments amendment
    WHERE amendment.company_id=p_company_id
      AND amendment.stock_request_line_id=v_line_id
      AND amendment.status='OPEN' FOR UPDATE;
    IF v_reason IS NULL THEN
      IF v_amendment.id IS NOT NULL THEN
        UPDATE public.sales_order_procurement_amendments SET
          status='RESOLVED',resolved_by=p_actor_id,resolved_at=v_now,
          resolution_supplier_order_id=NULL,master_version=master_version+1,
          updated_at=v_now WHERE company_id=p_company_id AND id=v_amendment.id;
        SELECT to_jsonb(amendment) INTO v_after
        FROM public.sales_order_procurement_amendments amendment
        WHERE amendment.company_id=p_company_id AND amendment.id=v_amendment.id;
        INSERT INTO public.sales_order_procurement_amendment_audit(
          company_id,amendment_id,action,idempotency_key,actor_id,
          before_state,after_state)
        VALUES(p_company_id,v_amendment.id,'RESOLVE',v_sync_key,p_actor_id,
          to_jsonb(v_amendment),v_after);
      END IF;
    ELSIF v_amendment.id IS NULL THEN
      INSERT INTO public.sales_order_procurement_amendments(
        company_id,demand_id,stock_request_document_id,stock_request_line_id,
        product_id,reason,status,desired_base_qty,draft_allocated_base_qty,
        final_allocated_base_qty,delta_base_qty,source_demand_version,created_by)
      VALUES(p_company_id,v_demand.id,v_request.id,v_line_id,
        v_product.product_id,v_reason,'OPEN',v_desired,v_draft,v_final,v_delta,
        v_demand.master_version,p_actor_id) RETURNING * INTO v_amendment;
      INSERT INTO public.sales_order_procurement_amendment_audit(
        company_id,amendment_id,action,idempotency_key,actor_id,after_state)
      VALUES(p_company_id,v_amendment.id,'OPEN',v_sync_key,p_actor_id,
        to_jsonb(v_amendment));
    ELSE
      UPDATE public.sales_order_procurement_amendments SET reason=v_reason,
        desired_base_qty=v_desired,draft_allocated_base_qty=v_draft,
        final_allocated_base_qty=v_final,delta_base_qty=v_delta,
        source_demand_version=v_demand.master_version,
        master_version=master_version+1,updated_at=v_now
      WHERE company_id=p_company_id AND id=v_amendment.id;
      SELECT to_jsonb(amendment) INTO v_after
      FROM public.sales_order_procurement_amendments amendment
      WHERE amendment.company_id=p_company_id AND amendment.id=v_amendment.id;
      INSERT INTO public.sales_order_procurement_amendment_audit(
        company_id,amendment_id,action,idempotency_key,actor_id,
        before_state,after_state)
      VALUES(p_company_id,v_amendment.id,'REFRESH',v_sync_key,p_actor_id,
        to_jsonb(v_amendment),v_after);
    END IF;
  END LOOP;

  SELECT count(*),COALESCE(sum(line.requested_base_qty),0)
  INTO v_line_count,v_total FROM public.stock_request_lines line
  WHERE line.company_id=p_company_id AND line.document_id=v_request.id
    AND line.is_active;
  IF v_changed OR v_request.line_count<>v_line_count
    OR v_request.requested_total_base_qty<>v_total THEN
    UPDATE public.stock_request_documents SET line_count=v_line_count,
      requested_total_base_qty=v_total,master_version=master_version+1,
      updated_at=v_now WHERE company_id=p_company_id AND id=v_request.id;
    SELECT to_jsonb(request) INTO v_after FROM public.stock_request_documents request
    WHERE request.company_id=p_company_id AND request.id=v_request.id;
    INSERT INTO public.stock_request_audit(
      company_id,document_id,action,actor_id,before_state,after_state)
    VALUES(p_company_id,v_request.id,'UPDATE',p_actor_id,v_before,v_after);
  END IF;
  INSERT INTO public.sales_order_procurement_demand_audit(
    company_id,demand_id,action,idempotency_key,actor_id,after_state)
  VALUES(p_company_id,v_demand.id,'DRAFT_PO_SYNC',v_sync_key,p_actor_id,
    jsonb_build_object('salesId',p_sales_id,'stockRequestId',v_request.id,
      'lineCount',v_line_count,'requestedBaseQty',v_total,
      'poMutation',FALSE));
  RETURN jsonb_build_object('stockRequestId',v_request.id,'reconciled',TRUE,
    'lineCount',v_line_count,'requestedBaseQty',v_total,'exactRetry',FALSE);
END
$$;

ALTER FUNCTION public.get_purchase_supplier_orders()
  RENAME TO odr4d_get_purchase_supplier_orders_core;
ALTER FUNCTION public.odr4d_get_purchase_supplier_orders_core()
  SET SCHEMA private;

CREATE FUNCTION public.get_purchase_supplier_orders()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_base JSONB;
  v_lines JSONB;
BEGIN
  v_base:=private.odr4d_get_purchase_supplier_orders_core();
  SELECT COALESCE(jsonb_agg(to_jsonb(line_row)
    ORDER BY line_row.document_id,line_row.line_no),'[]'::JSONB)
  INTO v_lines FROM (SELECT line.id,line.document_id,line.line_no,
      line.product_id,line.requested_uom_id,line.requested_qty,
      line.factor_to_base_snapshot,line.requested_base_qty,
      line.product_sku_snapshot,line.product_name_snapshot,
      line.requested_uom_name_snapshot,line.notes
    FROM public.stock_request_lines line
    JOIN public.stock_request_documents document
      ON document.company_id=line.company_id AND document.id=line.document_id
    WHERE line.company_id=v_company AND line.is_active
      AND document.status IN('SUBMITTED','ORDERED')
    ORDER BY line.document_id,line.line_no LIMIT 10000) line_row;
  RETURN jsonb_set(v_base,'{requestLines}',v_lines,TRUE);
END
$$;

ALTER FUNCTION private.refresh_sales_order_procurement_demand(
  UUID,UUID,UUID,UUID,TEXT) RENAME TO odr4d_refresh_procurement_demand_core;

CREATE FUNCTION private.refresh_sales_order_procurement_demand(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,
  p_idempotency_key UUID,p_action TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_reconciliation JSONB;
BEGIN
  v_result:=private.odr4d_refresh_procurement_demand_core(p_company_id,
    p_sales_id,p_actor_id,p_idempotency_key,p_action);
  v_reconciliation:=private.reconcile_session_procurement_request(p_company_id,
    p_sales_id,p_actor_id,p_idempotency_key);
  RETURN v_result||jsonb_build_object('requestReconciliation',v_reconciliation);
END
$$;

CREATE OR REPLACE FUNCTION public.get_purchase_procurement_demands()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id();v_base JSONB;
BEGIN
  PERFORM private.acp_require_permission_capability(
    v_company,'purchase.supplier_orders','VIEW');
  v_base:=jsonb_build_object('companyId',v_company,
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
          line.stock_request_line_id,line.status,line.master_version,line.updated_at
        FROM public.sales_order_procurement_demand_lines line
        JOIN public.products product ON product.company_id=line.company_id
          AND product.id=line.stock_product_id
        WHERE line.company_id=v_company
        ORDER BY line.demand_id,product.name,line.id LIMIT 10000) row_data));
  RETURN v_base||jsonb_build_object('amendments',(SELECT COALESCE(jsonb_agg(
      to_jsonb(amendment) ORDER BY amendment.updated_at DESC,amendment.id),
      '[]'::JSONB)
    FROM public.sales_order_procurement_amendments amendment
    WHERE amendment.company_id=v_company));
END
$$;

REVOKE ALL ON FUNCTION
  private.reconcile_session_procurement_request(UUID,UUID,UUID,UUID),
  private.odr4d_refresh_procurement_demand_core(UUID,UUID,UUID,UUID,TEXT),
  private.refresh_sales_order_procurement_demand(UUID,UUID,UUID,UUID,TEXT),
  private.odr4d_get_purchase_supplier_orders_core()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.reconcile_session_procurement_request(UUID,UUID,UUID,UUID),
  private.odr4d_refresh_procurement_demand_core(UUID,UUID,UUID,UUID,TEXT),
  private.refresh_sales_order_procurement_demand(UUID,UUID,UUID,UUID,TEXT),
  private.odr4d_get_purchase_supplier_orders_core()
TO service_role;
REVOKE ALL ON FUNCTION public.get_purchase_procurement_demands(),
  public.get_purchase_supplier_orders()
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_purchase_procurement_demands(),
  public.get_purchase_supplier_orders()
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828190000','odr_phase4d_managed_request_reconciliation',
  'Reconcile post-close Sales Order demand into managed Stock Request quantities and immutable Purchasing delta notices with exact retry; no Supplier Order, Stock, FIFO or Finance mutation');
NOTIFY pgrst,'reload schema';
COMMIT;
