BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828190000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: ODR-4D request reconciliation required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260828200000') THEN
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
  IF EXISTS(SELECT 1 FROM public.sales_order_procurement_amendments
    WHERE status='OPEN') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: open procurement amendment';
  END IF;
END
$guard$;

ALTER TABLE public.sales_order_procurement_amendments
  DROP CONSTRAINT sales_order_procurement_amendments_reason_check,
  ADD CONSTRAINT sales_order_procurement_amendments_reason_check CHECK(reason IN(
    'UNALLOCATED','DRAFT_SYNC_PENDING','AMBIGUOUS_DRAFT_TARGET',
    'MIXED_MANUAL_DRAFT_LINE','FINAL_PO_IMMUTABLE',
    'QUANTITY_DECREASE_REQUIRES_REVIEW',
    'DRAFT_UOM_CONVERSION_REQUIRES_REVIEW'));

CREATE FUNCTION private.sync_managed_request_single_draft_po(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,p_idempotency_key UUID
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_sale public.sales_headers%ROWTYPE;
  v_demand public.sales_order_procurement_demands%ROWTYPE;
  v_amendment public.sales_order_procurement_amendments%ROWTYPE;
  v_target RECORD;v_order_before JSONB;v_order_after JSONB;
  v_amendment_after JSONB;v_draft NUMERIC(24,6);v_final NUMERIC(24,6);
  v_line_allocated NUMERIC(24,6);v_delta NUMERIC(24,6);
  v_new_base NUMERIC(24,6);v_new_qty NUMERIC(24,6);
  v_draft_orders INTEGER;v_draft_lines INTEGER;v_sync_count INTEGER:=0;
  v_sync_key UUID;v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
  IF p_company_id IS NULL OR p_sales_id IS NULL OR p_actor_id IS NULL
    OR p_idempotency_key IS NULL THEN
    RAISE EXCEPTION 'DRAFT_PO_SYNC_CONTEXT_REQUIRED';
  END IF;
  SELECT sale.* INTO v_sale FROM public.sales_headers sale
  WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'SALES_ORDER_NOT_FOUND'; END IF;
  SELECT demand.* INTO v_demand
  FROM public.sales_order_procurement_demands demand
  WHERE demand.company_id=p_company_id
    AND demand.cashier_session_id=v_sale.session_id FOR UPDATE;
  IF NOT FOUND OR v_demand.stock_request_document_id IS NULL THEN
    RETURN jsonb_build_object('syncedDraftPoLines',0,'reason','NO_MANAGED_REQUEST');
  END IF;
  v_sync_key:=md5(p_company_id::TEXT||':'||v_demand.id::TEXT||':'||
    p_idempotency_key::TEXT||':SINGLE_DRAFT_PO_SYNC')::UUID;
  IF EXISTS(SELECT 1 FROM public.sales_order_procurement_demand_audit audit
    WHERE audit.company_id=p_company_id AND audit.demand_id=v_demand.id
      AND audit.demand_line_id IS NULL AND audit.idempotency_key=v_sync_key) THEN
    RETURN jsonb_build_object('syncedDraftPoLines',0,'exactRetry',TRUE);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_company_id::TEXT||':PROCUREMENT-RECONCILE:'||v_demand.id::TEXT,0));

  FOR v_amendment IN
    SELECT amendment.* FROM public.sales_order_procurement_amendments amendment
    WHERE amendment.company_id=p_company_id
      AND amendment.demand_id=v_demand.id AND amendment.status='OPEN'
      AND amendment.reason='DRAFT_SYNC_PENDING'
    ORDER BY amendment.product_id,amendment.id FOR UPDATE
  LOOP
    SELECT count(DISTINCT order_document.id) FILTER(
        WHERE order_document.status='DRAFT'),
      count(DISTINCT order_line.id) FILTER(
        WHERE order_document.status='DRAFT'),
      COALESCE(sum(allocation.allocated_base_qty) FILTER(
        WHERE order_document.status='DRAFT'),0),
      COALESCE(sum(allocation.allocated_base_qty) FILTER(WHERE
        order_document.status IN('CONFIRMED','PARTIALLY_RECEIVED','RECEIVED')),0)
    INTO v_draft_orders,v_draft_lines,v_draft,v_final
    FROM public.supplier_order_request_allocations allocation
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    JOIN public.supplier_order_documents order_document
      ON order_document.company_id=order_line.company_id
     AND order_document.id=order_line.document_id
    WHERE allocation.company_id=p_company_id
      AND allocation.stock_request_line_id=v_amendment.stock_request_line_id;
    v_delta:=v_amendment.desired_base_qty-v_draft-v_final;
    IF v_final>0 OR v_draft_orders<>1 OR v_draft_lines<>1 OR v_delta<=0 THEN
      RAISE EXCEPTION 'DRAFT_PO_SYNC_STATE_CHANGED';
    END IF;

    SELECT order_document.id order_id,order_document.status order_status,
      order_line.id order_line_id,order_line.ordered_qty,
      order_line.ordered_base_qty,order_line.factor_to_base_snapshot,
      order_line.estimated_unit_price,allocation.id allocation_id,
      allocation.allocated_base_qty,uom.allow_decimal,uom.decimal_precision
    INTO v_target
    FROM public.supplier_order_request_allocations allocation
    JOIN public.supplier_order_lines order_line
      ON order_line.company_id=allocation.company_id
     AND order_line.id=allocation.supplier_order_line_id
    JOIN public.supplier_order_documents order_document
      ON order_document.company_id=order_line.company_id
     AND order_document.id=order_line.document_id
    JOIN public.uoms uom ON uom.company_id=order_line.company_id
      AND uom.id=order_line.ordered_uom_id
    WHERE allocation.company_id=p_company_id
      AND allocation.stock_request_line_id=v_amendment.stock_request_line_id
      AND order_document.status='DRAFT'
    FOR UPDATE OF order_document,order_line,allocation;
    IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_PO_SYNC_STATE_CHANGED'; END IF;

    SELECT COALESCE(sum(allocation.allocated_base_qty),0)
    INTO v_line_allocated
    FROM public.supplier_order_request_allocations allocation
    WHERE allocation.company_id=p_company_id
      AND allocation.supplier_order_line_id=v_target.order_line_id;
    IF v_target.order_status<>'DRAFT'
      OR v_line_allocated<>v_target.ordered_base_qty THEN
      RAISE EXCEPTION 'DRAFT_PO_SYNC_STATE_CHANGED';
    END IF;
    v_new_base:=v_target.ordered_base_qty+v_delta;
    v_new_qty:=v_new_base/v_target.factor_to_base_snapshot;
    IF (NOT v_target.allow_decimal AND v_new_qty<>trunc(v_new_qty))
      OR (v_target.allow_decimal AND v_new_qty<>
        round(v_new_qty,v_target.decimal_precision)) THEN
      UPDATE public.sales_order_procurement_amendments SET
        reason='DRAFT_UOM_CONVERSION_REQUIRES_REVIEW',
        draft_allocated_base_qty=v_draft,final_allocated_base_qty=v_final,
        delta_base_qty=v_delta,source_demand_version=v_demand.master_version,
        master_version=master_version+1,updated_at=v_now
      WHERE company_id=p_company_id AND id=v_amendment.id;
      SELECT to_jsonb(amendment) INTO v_amendment_after
      FROM public.sales_order_procurement_amendments amendment
      WHERE amendment.company_id=p_company_id AND amendment.id=v_amendment.id;
      INSERT INTO public.sales_order_procurement_amendment_audit(
        company_id,amendment_id,action,idempotency_key,actor_id,
        before_state,after_state)
      VALUES(p_company_id,v_amendment.id,'REFRESH',v_sync_key,p_actor_id,
        to_jsonb(v_amendment),v_amendment_after);
      CONTINUE;
    END IF;

    SELECT to_jsonb(document) INTO v_order_before
    FROM public.supplier_order_documents document
    WHERE document.company_id=p_company_id AND document.id=v_target.order_id;
    UPDATE public.supplier_order_request_allocations SET
      allocated_base_qty=allocated_base_qty+v_delta
    WHERE company_id=p_company_id AND id=v_target.allocation_id;
    UPDATE public.supplier_order_lines SET ordered_qty=v_new_qty,
      ordered_base_qty=v_new_base,
      estimated_subtotal=round(v_new_qty*estimated_unit_price,4)
    WHERE company_id=p_company_id AND id=v_target.order_line_id;
    UPDATE public.supplier_order_documents document SET
      line_count=summary.line_count,
      total_ordered_base_qty=summary.total_base_qty,
      estimated_total=summary.estimated_total,
      master_version=document.master_version+1,updated_at=v_now
    FROM (SELECT count(*) line_count,sum(line.ordered_base_qty) total_base_qty,
        sum(line.estimated_subtotal) estimated_total
      FROM public.supplier_order_lines line
      WHERE line.company_id=p_company_id
        AND line.document_id=v_target.order_id) summary
    WHERE document.company_id=p_company_id AND document.id=v_target.order_id
      AND document.status='DRAFT';
    IF NOT FOUND THEN RAISE EXCEPTION 'DRAFT_PO_SYNC_STATE_CHANGED'; END IF;
    SELECT to_jsonb(document) INTO v_order_after
    FROM public.supplier_order_documents document
    WHERE document.company_id=p_company_id AND document.id=v_target.order_id;
    INSERT INTO public.supplier_order_audit(
      company_id,document_id,action,actor_id,before_state,after_state)
    VALUES(p_company_id,v_target.order_id,'UPDATE',p_actor_id,
      v_order_before||jsonb_build_object('syncRequestLineId',
        v_amendment.stock_request_line_id,'syncDeltaBaseQty',v_delta),
      v_order_after||jsonb_build_object('syncRequestLineId',
        v_amendment.stock_request_line_id,'syncDeltaBaseQty',v_delta));

    UPDATE public.sales_order_procurement_amendments SET status='RESOLVED',
      draft_allocated_base_qty=v_amendment.desired_base_qty,
      final_allocated_base_qty=0,delta_base_qty=0,
      resolution_supplier_order_id=v_target.order_id,resolved_by=p_actor_id,
      resolved_at=v_now,master_version=master_version+1,updated_at=v_now
    WHERE company_id=p_company_id AND id=v_amendment.id;
    SELECT to_jsonb(amendment) INTO v_amendment_after
    FROM public.sales_order_procurement_amendments amendment
    WHERE amendment.company_id=p_company_id AND amendment.id=v_amendment.id;
    INSERT INTO public.sales_order_procurement_amendment_audit(
      company_id,amendment_id,action,idempotency_key,actor_id,
      before_state,after_state)
    VALUES(p_company_id,v_amendment.id,'RESOLVE',v_sync_key,p_actor_id,
      to_jsonb(v_amendment),v_amendment_after);
    v_sync_count:=v_sync_count+1;
  END LOOP;

  INSERT INTO public.sales_order_procurement_demand_audit(
    company_id,demand_id,action,idempotency_key,actor_id,after_state)
  VALUES(p_company_id,v_demand.id,'DRAFT_PO_SYNC',v_sync_key,p_actor_id,
    jsonb_build_object('salesId',p_sales_id,'syncedDraftPoLines',v_sync_count,
      'finalPoMutation',FALSE,'stockOrFinanceMutation',FALSE));
  RETURN jsonb_build_object('syncedDraftPoLines',v_sync_count,
    'exactRetry',FALSE);
END
$$;

ALTER FUNCTION private.refresh_sales_order_procurement_demand(
  UUID,UUID,UUID,UUID,TEXT) RENAME TO odr4e_refresh_procurement_demand_core;

CREATE FUNCTION private.refresh_sales_order_procurement_demand(
  p_company_id UUID,p_sales_id UUID,p_actor_id UUID,
  p_idempotency_key UUID,p_action TEXT
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_result JSONB;v_sync JSONB;
BEGIN
  v_result:=private.odr4e_refresh_procurement_demand_core(p_company_id,
    p_sales_id,p_actor_id,p_idempotency_key,p_action);
  v_sync:=private.sync_managed_request_single_draft_po(p_company_id,
    p_sales_id,p_actor_id,p_idempotency_key);
  RETURN v_result||jsonb_build_object('draftPoSync',v_sync);
END
$$;

REVOKE ALL ON FUNCTION
  private.sync_managed_request_single_draft_po(UUID,UUID,UUID,UUID),
  private.odr4e_refresh_procurement_demand_core(UUID,UUID,UUID,UUID,TEXT),
  private.refresh_sales_order_procurement_demand(UUID,UUID,UUID,UUID,TEXT)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.sync_managed_request_single_draft_po(UUID,UUID,UUID,UUID),
  private.odr4e_refresh_procurement_demand_core(UUID,UUID,UUID,UUID,TEXT),
  private.refresh_sales_order_procurement_demand(UUID,UUID,UUID,UUID,TEXT)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260828200000','odr_phase4e_single_draft_po_sync',
  'Atomically synchronize positive managed-request delta into one fully allocation-backed Draft Supplier Order line; final or ambiguous PO and Stock Finance boundaries remain immutable');
NOTIFY pgrst,'reload schema';
COMMIT;
