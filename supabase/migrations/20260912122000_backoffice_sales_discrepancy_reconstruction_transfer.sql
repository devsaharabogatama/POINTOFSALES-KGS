-- Step 4/6.5C1: private physical reconstruction transfer for Overage/Wrong Item.
-- No public resolver and no discrepancy state transition in this gate.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912121000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: shortage audit fix required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912122000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912122000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regprocedure('private.post_backoffice_sales_discrepancy_transfer(uuid,bigint,uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: reconstruction helper collision';
  END IF;
  IF to_regprocedure('private.post_backoffice_sales_stock_transfer(uuid,bigint,uuid,uuid)') IS NULL
    OR to_regprocedure('private.resolve_pos_negative_stock_provisional_cost(uuid,uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical negative transfer dependency missing';
  END IF;
END
$guard$;

CREATE FUNCTION private.post_backoffice_sales_discrepancy_transfer(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid,
  p_discrepancy_line_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_document public.stock_transfer_documents%rowtype;
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
  v_discrepancy public.backoffice_sales_delivery_discrepancies%rowtype;
  v_discrepancy_line public.backoffice_sales_delivery_discrepancy_lines%rowtype;
  v_line public.stock_transfer_lines%rowtype;v_batch record;
  v_before jsonb;v_after jsonb;v_category uuid;v_result_version bigint;
  v_source_before numeric(24,6);v_source_after numeric(24,6);
  v_destination_before numeric(24,6);v_available_fifo numeric(24,6);
  v_expected_shortage numeric(24,6);v_remaining numeric(24,6);v_take numeric(24,6);
  v_line_cost numeric(24,4);v_total_cost numeric(24,4):=0;v_layers integer;
  v_destination_batch uuid;v_source_batch uuid;v_allocation uuid;
  v_cost numeric(20,4);v_allow_negative boolean;v_warehouse_version bigint;
  v_posted_at timestamptz:=clock_timestamp();
BEGIN
  IF v_actor IS NULL OR v_company IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
  IF p_idempotency_key IS NULL THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED'; END IF;
  IF NOT public.private_stock_transfer_operator_allowed(v_company) THEN
    RAISE EXCEPTION 'STOCK_TRANSFER_OPERATOR_REQUIRED';
  END IF;
  SELECT * INTO v_document FROM public.stock_transfer_documents document
  WHERE document.company_id=v_company AND document.id=p_document_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'STOCK_TRANSFER_NOT_FOUND'; END IF;
  IF v_document.status='POSTED' THEN
    IF v_document.posting_idempotency_key=p_idempotency_key THEN
      RETURN jsonb_build_object('documentId',v_document.id,'documentNo',v_document.document_no,
        'status','POSTED','masterVersion',v_document.master_version,
        'lineCount',v_document.line_count,'totalQuantityBase',v_document.total_quantity_base,
        'totalCost',v_document.total_cost,'idempotentReplay',true);
    END IF;
    RAISE EXCEPTION 'STOCK_TRANSFER_ALREADY_POSTED';
  END IF;
  IF v_document.status<>'DRAFT' THEN RAISE EXCEPTION 'CANCELED_STOCK_TRANSFER_IMMUTABLE'; END IF;
  IF p_master_version IS DISTINCT FROM v_document.master_version THEN
    RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
  END IF;
  SELECT * INTO v_discrepancy_line
  FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=v_company AND line.id=p_discrepancy_line_id FOR SHARE;
  IF NOT FOUND OR v_discrepancy_line.warehouse_resolution_status<>'PENDING'
    OR v_discrepancy_line.discrepancy_type NOT IN('OVERAGE','WRONG_ITEM')
    OR (v_discrepancy_line.requested_resolution='ACCEPT_OVERAGE'
      AND v_discrepancy_line.commercial_approval_status<>'APPROVED') THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_RECONSTRUCTION_STATE_INVALID';
  END IF;
  SELECT * INTO STRICT v_discrepancy
  FROM public.backoffice_sales_delivery_discrepancies discrepancy
  WHERE discrepancy.company_id=v_company
    AND discrepancy.id=v_discrepancy_line.discrepancy_id FOR SHARE;
  SELECT * INTO STRICT v_delivery FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company
    AND delivery.id=v_discrepancy_line.delivery_order_id FOR SHARE;
  IF v_delivery.status<>'IN_TRANSIT'
    OR v_delivery.sales_order_id<>v_discrepancy.sales_order_id THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_DELIVERY_STATE_INVALID';
  END IF;
  IF (SELECT count(*) FROM public.stock_transfer_lines transfer_line
      WHERE transfer_line.company_id=v_company
        AND transfer_line.document_id=v_document.id)<>1
    OR NOT EXISTS(SELECT 1 FROM public.stock_transfer_lines transfer_line
      WHERE transfer_line.company_id=v_company
        AND transfer_line.document_id=v_document.id
        AND transfer_line.product_id=CASE
          WHEN v_discrepancy_line.discrepancy_type='WRONG_ITEM'
            THEN v_discrepancy_line.actual_product_id
          ELSE v_discrepancy_line.expected_product_id END
        AND transfer_line.quantity_base=CASE
          WHEN v_discrepancy_line.discrepancy_type='WRONG_ITEM'
            THEN v_discrepancy_line.actual_quantity_base
          ELSE v_discrepancy_line.quantity_base END) THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSFER_LINE_INVALID';
  END IF;
  IF v_document.source_warehouse_id<>(SELECT reservation.warehouse_id
      FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id
        AND reservation.sales_order_id=v_delivery.sales_order_id)
    OR v_document.destination_warehouse_id<>(SELECT dispatch.transit_warehouse_id
      FROM public.backoffice_sales_delivery_dispatches dispatch
      WHERE dispatch.company_id=v_company AND dispatch.delivery_order_id=v_delivery.id
      ORDER BY dispatch.dispatched_at DESC,dispatch.id DESC LIMIT 1)
    OR NOT EXISTS(SELECT 1 FROM public.warehouses transit
      WHERE transit.company_id=v_company AND transit.id=v_document.destination_warehouse_id
        AND transit.is_active AND transit.transit_parent_warehouse_id=v_document.source_warehouse_id
        AND transit.transit_operation='SALES_DELIVERY_OUTBOUND') THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_TRANSFER_LINEAGE_INVALID';
  END IF;
  SELECT warehouse.allow_negative_stock,warehouse.master_version
    INTO v_allow_negative,v_warehouse_version
  FROM public.warehouses warehouse
  WHERE warehouse.company_id=v_company AND warehouse.id=v_document.source_warehouse_id
    AND warehouse.is_active AND warehouse.is_sale_source FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ACTIVE_SALE_SOURCE_WAREHOUSE_NOT_FOUND'; END IF;
  SELECT category.id INTO v_category FROM public.transaction_categories category
  WHERE category.company_id=v_company AND category.system_key='STOCK_TRANSFER'
    AND category.is_active AND category.is_system_default ORDER BY category.id LIMIT 1;
  IF v_category IS NULL THEN RAISE EXCEPTION 'STOCK_TRANSFER_TRANSACTION_CATEGORY_NOT_FOUND'; END IF;
  v_before:=to_jsonb(v_document);

  FOR v_line IN SELECT * FROM public.stock_transfer_lines line
    WHERE line.company_id=v_company AND line.document_id=v_document.id
    ORDER BY line.product_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':STOCK:'||
      v_line.product_id::text||':'||LEAST(v_document.source_warehouse_id::text,
      v_document.destination_warehouse_id::text),0));
    PERFORM pg_advisory_xact_lock(hashtextextended(v_company::text||':STOCK:'||
      v_line.product_id::text||':'||GREATEST(v_document.source_warehouse_id::text,
      v_document.destination_warehouse_id::text),0));
    SELECT stock.stock_qty INTO v_source_before FROM public.product_stocks stock
    WHERE stock.company_id=v_company AND stock.product_id=v_line.product_id
      AND stock.warehouse_id=v_document.source_warehouse_id FOR UPDATE;
    v_source_before:=COALESCE(v_source_before,0);
    SELECT COALESCE(sum(batch.qty_remaining),0) INTO v_available_fifo
    FROM public.product_batches batch WHERE batch.company_id=v_company
      AND batch.product_id=v_line.product_id
      AND batch.warehouse_id=v_document.source_warehouse_id AND batch.qty_remaining>0;
    v_expected_shortage:=GREATEST(v_line.quantity_base-GREATEST(v_source_before,0),0);
    IF v_available_fifo<GREATEST(LEAST(v_source_before,v_line.quantity_base),0) THEN
      RAISE EXCEPTION 'FIFO_STOCK_CHANGED';
    END IF;
    IF v_expected_shortage>0 AND NOT v_allow_negative THEN RAISE EXCEPTION 'INSUFFICIENT_STOCK'; END IF;
    SELECT COALESCE(stock.stock_qty,0) INTO v_destination_before
    FROM public.product_stocks stock WHERE stock.company_id=v_company
      AND stock.product_id=v_line.product_id
      AND stock.warehouse_id=v_document.destination_warehouse_id FOR UPDATE;
    v_destination_before:=COALESCE(v_destination_before,0);
    v_remaining:=v_line.quantity_base;v_line_cost:=0;v_layers:=0;
    FOR v_batch IN SELECT batch.* FROM public.product_batches batch
      WHERE batch.company_id=v_company AND batch.product_id=v_line.product_id
        AND batch.warehouse_id=v_document.source_warehouse_id AND batch.qty_remaining>0
      ORDER BY batch.created_at,batch.id FOR UPDATE
    LOOP
      EXIT WHEN v_remaining<=v_expected_shortage;
      v_take:=LEAST(v_remaining-v_expected_shortage,v_batch.qty_remaining);
      UPDATE public.product_batches SET qty_remaining=qty_remaining-v_take
      WHERE company_id=v_company AND id=v_batch.id;
      INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
        qty_purchased,qty_remaining,cogs_unit,company_id,opening_stock_line_id,
        stock_transfer_line_id,source_batch_id)
      VALUES(v_line.product_id,v_document.destination_warehouse_id,NULL,v_take,v_take,
        v_batch.cogs_unit,v_company,NULL,v_line.id,v_batch.id)
      RETURNING id INTO v_destination_batch;
      INSERT INTO public.stock_transfer_fifo_allocations(company_id,document_id,line_id,
        source_batch_id,destination_batch_id,quantity_base,unit_cost_base,total_cost)
      VALUES(v_company,v_document.id,v_line.id,v_batch.id,v_destination_batch,v_take,
        v_batch.cogs_unit,round(v_take*v_batch.cogs_unit,4));
      v_line_cost:=v_line_cost+round(v_take*v_batch.cogs_unit,4);
      v_layers:=v_layers+1;v_remaining:=v_remaining-v_take;
    END LOOP;
    IF v_remaining<>v_expected_shortage THEN RAISE EXCEPTION 'FIFO_STOCK_CHANGED'; END IF;
    IF v_remaining>0 THEN
      v_cost:=private.resolve_pos_negative_stock_provisional_cost(
        v_company,v_line.product_id,v_document.source_warehouse_id);
      v_allocation:=gen_random_uuid();v_source_batch:=gen_random_uuid();
      v_destination_batch:=gen_random_uuid();
      INSERT INTO public.backoffice_negative_stock_allocations(id,company_id,
        sales_order_id,delivery_order_id,reservation_id,stock_transfer_document_id,
        stock_transfer_line_id,product_id,source_warehouse_id,transit_warehouse_id,
        provisional_source_batch_id,transit_batch_id,shortage_base_qty,
        provisional_unit_cost,provisional_cost_total,warehouse_version,created_by)
      VALUES(v_allocation,v_company,v_delivery.sales_order_id,v_delivery.id,
        v_delivery.reservation_id,v_document.id,v_line.id,v_line.product_id,
        v_document.source_warehouse_id,v_document.destination_warehouse_id,
        v_source_batch,v_destination_batch,v_remaining,v_cost,
        round(v_remaining*v_cost,4),v_warehouse_version,v_actor);
      INSERT INTO public.product_batches(id,product_id,warehouse_id,purchase_detail_id,
        qty_purchased,qty_remaining,cogs_unit,company_id,opening_stock_line_id,
        stock_transfer_line_id,source_batch_id,backoffice_negative_allocation_id)
      VALUES(v_source_batch,v_line.product_id,v_document.source_warehouse_id,NULL,
        v_remaining,0,v_cost,v_company,NULL,NULL,NULL,v_allocation);
      INSERT INTO public.product_batches(id,product_id,warehouse_id,purchase_detail_id,
        qty_purchased,qty_remaining,cogs_unit,company_id,opening_stock_line_id,
        stock_transfer_line_id,source_batch_id,backoffice_negative_allocation_id)
      VALUES(v_destination_batch,v_line.product_id,v_document.destination_warehouse_id,NULL,
        v_remaining,v_remaining,v_cost,v_company,NULL,v_line.id,v_source_batch,NULL);
      INSERT INTO public.stock_transfer_fifo_allocations(company_id,document_id,line_id,
        source_batch_id,destination_batch_id,quantity_base,unit_cost_base,total_cost)
      VALUES(v_company,v_document.id,v_line.id,v_source_batch,v_destination_batch,
        v_remaining,v_cost,round(v_remaining*v_cost,4));
      v_line_cost:=v_line_cost+round(v_remaining*v_cost,4);v_layers:=v_layers+1;
    END IF;
    v_source_after:=v_source_before-v_line.quantity_base;
    INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
    VALUES(v_line.product_id,v_document.source_warehouse_id,v_source_after,v_company)
    ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
      stock_qty=excluded.stock_qty,updated_at=clock_timestamp();
    INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
    VALUES(v_line.product_id,v_document.destination_warehouse_id,v_line.quantity_base,v_company)
    ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
      stock_qty=public.product_stocks.stock_qty+excluded.stock_qty,
      updated_at=clock_timestamp();
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,movement_type,
      reference_table,reference_id,company_id,base_uom_id,base_uom_name_snapshot,
      balance_after_base_qty,actor_id,posted_at,movement_status,source_line_id,notes)
    VALUES
      (v_line.product_id,v_document.source_warehouse_id,-v_line.quantity_base,
       'TRANSFER_OUT'::public.stock_movement_type,'stock_transfer_documents',v_document.id,
       v_company,v_line.base_uom_id,v_line.base_uom_name_snapshot,v_source_after,v_actor,
       v_posted_at,'POSTED',v_line.id,COALESCE(v_line.notes,v_document.notes)),
      (v_line.product_id,v_document.destination_warehouse_id,v_line.quantity_base,
       'TRANSFER_IN'::public.stock_movement_type,'stock_transfer_documents',v_document.id,
       v_company,v_line.base_uom_id,v_line.base_uom_name_snapshot,
       v_destination_before+v_line.quantity_base,v_actor,v_posted_at,'POSTED',v_line.id,
       COALESCE(v_line.notes,v_document.notes));
    UPDATE public.stock_transfer_lines SET transferred_cost=v_line_cost,
      fifo_layer_count=v_layers WHERE company_id=v_company AND id=v_line.id;
    v_total_cost:=v_total_cost+v_line_cost;
  END LOOP;
  UPDATE public.stock_transfer_documents SET status='POSTED',
    posting_idempotency_key=p_idempotency_key,transaction_category_id=v_category,
    total_cost=v_total_cost,posted_by=v_actor,posted_at=v_posted_at,
    updated_by=v_actor,updated_at=v_posted_at,master_version=master_version+1
  WHERE company_id=v_company AND id=v_document.id RETURNING master_version INTO v_result_version;
  SELECT to_jsonb(document) INTO v_after FROM public.stock_transfer_documents document
  WHERE document.company_id=v_company AND document.id=v_document.id;
  INSERT INTO public.stock_transfer_audit(company_id,document_id,action,actor_id,
    before_state,after_state) VALUES(v_company,v_document.id,'POST',v_actor,v_before,v_after);
  RETURN jsonb_build_object('documentId',v_document.id,'documentNo',v_document.document_no,
    'status','POSTED','masterVersion',v_result_version,'lineCount',v_document.line_count,
    'totalQuantityBase',v_document.total_quantity_base,'totalCost',v_total_cost,
    'idempotentReplay',false);
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'STOCK_TRANSFER_IDEMPOTENCY_CONFLICT';
END
$$;


REVOKE ALL ON FUNCTION private.post_backoffice_sales_discrepancy_transfer(
  uuid,bigint,uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.post_backoffice_sales_discrepancy_transfer(
  uuid,bigint,uuid,uuid) TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912122000','backoffice_sales_discrepancy_reconstruction_transfer',
  'Step 4/6.5C1 adds a private exact FIFO source-to-Transit reconstruction transfer for pending Overage/Wrong Item using Warehouse negative-stock authority; no public resolver or state transition');

NOTIFY pgrst,'reload schema';
COMMIT;

