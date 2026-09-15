-- Allow Backoffice Sales Dispatch to move an approved Warehouse shortage into
-- its dedicated outbound Transit while preserving FIFO, audit, and later cost
-- reconciliation. Ordinary Stock Transfer remains nonnegative.
BEGIN;

DO $guard$
DECLARE v_dispatch text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260911140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260911140000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260910153000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909151000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260909154000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260831130000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: negative Dispatch dependencies missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_negative_stock_allocations') IS NOT NULL
    OR to_regclass('public.backoffice_negative_stock_replenishments') IS NOT NULL
    OR EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='product_batches'
        AND column_name='backoffice_negative_allocation_id')
    OR to_regprocedure('private.post_backoffice_sales_stock_transfer(uuid,bigint,uuid,uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: negative Dispatch object collision';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_constraint
      WHERE conrelid='public.product_batches'::regclass
        AND conname='product_batches_source_lineage_check')
    OR NOT EXISTS(SELECT 1 FROM pg_constraint
      WHERE conrelid='public.stock_movements'::regclass
        AND conname='stock_movements_balance_after_controlled') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Stock constraint missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.dispatch_backoffice_sales_delivery_to_transit(uuid,bigint,uuid,jsonb,text)'::regprocedure)
    INTO v_dispatch;
  IF (length(v_dispatch)-length(replace(v_dispatch,
      'v_posted := private.post_stock_transfer(v_transfer_id, v_transfer_version, p_operation_id);','')))
      /length('v_posted := private.post_stock_transfer(v_transfer_id, v_transfer_version, p_operation_id);') <> 1
    AND (length(v_dispatch)-length(replace(v_dispatch,
      'v_posted:=private.post_stock_transfer(v_transfer_id,v_transfer_version,p_operation_id);','')))
      /length('v_posted:=private.post_stock_transfer(v_transfer_id,v_transfer_version,p_operation_id);') <> 1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Dispatch call chain drift';
  END IF;
END
$guard$;

CREATE TABLE public.backoffice_negative_stock_allocations(
  id uuid PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  sales_order_id uuid NOT NULL,
  delivery_order_id uuid NOT NULL,
  reservation_id uuid NOT NULL,
  stock_transfer_document_id uuid NOT NULL,
  stock_transfer_line_id uuid NOT NULL,
  product_id uuid NOT NULL,
  source_warehouse_id uuid NOT NULL,
  transit_warehouse_id uuid NOT NULL,
  provisional_source_batch_id uuid NOT NULL,
  transit_batch_id uuid NOT NULL,
  shortage_base_qty numeric(24,6) NOT NULL,
  replenished_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  provisional_unit_cost numeric(20,4) NOT NULL,
  provisional_cost_total numeric(20,4) NOT NULL,
  actual_cost_total numeric(20,4) NOT NULL DEFAULT 0,
  inventory_revaluation_total numeric(20,4) NOT NULL DEFAULT 0,
  cogs_variance_total numeric(20,4) NOT NULL DEFAULT 0,
  authority_source text NOT NULL DEFAULT 'WAREHOUSE',
  warehouse_version bigint NOT NULL,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reconciled_at timestamptz,
  CONSTRAINT backoffice_negative_stock_allocations_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT backoffice_negative_stock_allocations_transfer_line_unique
    UNIQUE(company_id,stock_transfer_line_id),
  CONSTRAINT backoffice_negative_stock_allocations_source_batch_unique
    UNIQUE(company_id,provisional_source_batch_id),
  CONSTRAINT backoffice_negative_stock_allocations_transit_batch_unique
    UNIQUE(company_id,transit_batch_id),
  CONSTRAINT backoffice_negative_stock_allocations_delivery_fk
    FOREIGN KEY(company_id,sales_order_id,delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,sales_order_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_allocations_reservation_fk
    FOREIGN KEY(company_id,reservation_id,sales_order_id)
    REFERENCES public.backoffice_sales_reservations(company_id,id,sales_order_id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_allocations_transfer_document_fk
    FOREIGN KEY(company_id,stock_transfer_document_id)
    REFERENCES public.stock_transfer_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_allocations_transfer_line_fk
    FOREIGN KEY(company_id,stock_transfer_line_id)
    REFERENCES public.stock_transfer_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_allocations_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_allocations_source_warehouse_fk
    FOREIGN KEY(company_id,source_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_allocations_transit_warehouse_fk
    FOREIGN KEY(company_id,transit_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_allocations_shape_check CHECK(
    source_warehouse_id<>transit_warehouse_id AND shortage_base_qty>0
    AND replenished_base_qty>=0 AND replenished_base_qty<=shortage_base_qty
    AND provisional_unit_cost>=0
    AND provisional_cost_total=round(shortage_base_qty*provisional_unit_cost,4)
    AND actual_cost_total>=0 AND authority_source='WAREHOUSE'
    AND warehouse_version>0
    AND ((replenished_base_qty=shortage_base_qty AND reconciled_at IS NOT NULL)
      OR (replenished_base_qty<shortage_base_qty AND reconciled_at IS NULL)))
);

ALTER TABLE public.product_batches
  ADD COLUMN backoffice_negative_allocation_id uuid;

ALTER TABLE public.product_batches
  DROP CONSTRAINT product_batches_source_lineage_check,
  ADD CONSTRAINT product_batches_source_lineage_check CHECK(
    (stock_transfer_line_id IS NULL AND sales_return_line_id IS NULL
      AND source_batch_id IS NULL AND backoffice_negative_allocation_id IS NULL)
    OR (stock_transfer_line_id IS NOT NULL AND sales_return_line_id IS NULL
      AND source_batch_id IS NOT NULL AND backoffice_negative_allocation_id IS NULL)
    OR (stock_transfer_line_id IS NULL AND sales_return_line_id IS NOT NULL
      AND source_batch_id IS NOT NULL AND backoffice_negative_allocation_id IS NULL)
    OR (stock_transfer_line_id IS NULL AND sales_return_line_id IS NULL
      AND source_batch_id IS NULL AND backoffice_negative_allocation_id IS NOT NULL)),
  ADD CONSTRAINT product_batches_backoffice_negative_allocation_fk
    FOREIGN KEY(company_id,backoffice_negative_allocation_id)
    REFERENCES public.backoffice_negative_stock_allocations(company_id,id)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE public.backoffice_negative_stock_allocations
  ADD CONSTRAINT backoffice_negative_stock_allocations_source_batch_fk
    FOREIGN KEY(company_id,provisional_source_batch_id)
    REFERENCES public.product_batches(company_id,id)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED,
  ADD CONSTRAINT backoffice_negative_stock_allocations_transit_batch_fk
    FOREIGN KEY(company_id,transit_batch_id)
    REFERENCES public.product_batches(company_id,id)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX backoffice_negative_stock_allocations_open
  ON public.backoffice_negative_stock_allocations(
    company_id,source_warehouse_id,product_id,created_at,id)
  WHERE reconciled_at IS NULL;
CREATE INDEX product_batches_backoffice_negative_allocation
  ON public.product_batches(company_id,backoffice_negative_allocation_id)
  WHERE backoffice_negative_allocation_id IS NOT NULL;

CREATE TABLE public.backoffice_negative_stock_replenishments(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  negative_allocation_id uuid NOT NULL,
  product_batch_id uuid NOT NULL,
  replenished_base_qty numeric(24,6) NOT NULL,
  provisional_unit_cost numeric(20,4) NOT NULL,
  actual_unit_cost numeric(20,4) NOT NULL,
  cost_variance_total numeric(20,4) NOT NULL,
  inventory_revaluation numeric(20,4) NOT NULL,
  cogs_variance numeric(20,4) NOT NULL,
  transit_qty_remaining_snapshot numeric(24,6) NOT NULL,
  previous_transit_unit_cost numeric(24,10) NOT NULL,
  revalued_transit_unit_cost numeric(24,10) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_negative_stock_replenishments_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT backoffice_negative_stock_replenishments_source_unique
    UNIQUE(company_id,negative_allocation_id,product_batch_id),
  CONSTRAINT backoffice_negative_stock_replenishments_allocation_fk
    FOREIGN KEY(company_id,negative_allocation_id)
    REFERENCES public.backoffice_negative_stock_allocations(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_replenishments_batch_fk
    FOREIGN KEY(company_id,product_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_negative_stock_replenishments_shape_check CHECK(
    replenished_base_qty>0 AND provisional_unit_cost>=0 AND actual_unit_cost>=0
    AND cost_variance_total=inventory_revaluation+cogs_variance
    AND transit_qty_remaining_snapshot>=0
    AND previous_transit_unit_cost>=0 AND revalued_transit_unit_cost>=0)
);

ALTER TABLE public.stock_movements
  DROP CONSTRAINT stock_movements_balance_after_controlled,
  ADD CONSTRAINT stock_movements_balance_after_controlled CHECK(
    balance_after_base_qty IS NULL OR balance_after_base_qty>=0
    OR (movement_type='SALE'::public.stock_movement_type
      AND reference_table='sales_headers')
    OR (movement_type='TRANSFER_OUT'::public.stock_movement_type
      AND reference_table='stock_transfer_documents'));

CREATE OR REPLACE FUNCTION private.trg_g4_guard_negative_sale_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.balance_after_base_qty<0 AND NOT (
    EXISTS(SELECT 1 FROM public.pos_negative_stock_authorizations authz
      WHERE authz.company_id=NEW.company_id AND authz.sales_id=NEW.reference_id
        AND authz.stock_product_id=NEW.product_id AND authz.warehouse_id=NEW.warehouse_id
        AND authz.balance_after_base_qty=NEW.balance_after_base_qty
        AND ((authz.authority_source='LEGACY_USER_POLICY'
            AND authz.policy_version IS NOT NULL AND authz.permission_version IS NOT NULL)
          OR (authz.authority_source='WAREHOUSE' AND authz.warehouse_version IS NOT NULL)))
    OR EXISTS(SELECT 1 FROM public.backoffice_negative_stock_allocations allocation
      WHERE allocation.company_id=NEW.company_id
        AND allocation.stock_transfer_document_id=NEW.reference_id
        AND allocation.stock_transfer_line_id=NEW.source_line_id
        AND allocation.product_id=NEW.product_id
        AND allocation.source_warehouse_id=NEW.warehouse_id
        AND allocation.authority_source='WAREHOUSE'
        AND allocation.warehouse_version>0
        AND NEW.movement_type='TRANSFER_OUT'::public.stock_movement_type
        AND NEW.reference_table='stock_transfer_documents')
  ) THEN RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'; END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.post_backoffice_sales_stock_transfer(
  p_document_id uuid,p_master_version bigint,p_idempotency_key uuid,
  p_delivery_order_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
  v_actor uuid:=auth.uid();v_company uuid:=public.private_active_company_id();
  v_document public.stock_transfer_documents%rowtype;
  v_delivery public.backoffice_sales_delivery_orders%rowtype;
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
  SELECT * INTO v_delivery FROM public.backoffice_sales_delivery_orders delivery
  WHERE delivery.company_id=v_company AND delivery.id=p_delivery_order_id FOR SHARE;
  IF NOT FOUND OR v_delivery.status NOT IN('READY','PARTIALLY_SHIPPED')
    OR v_delivery.sales_order_id IS NULL OR v_delivery.reservation_id IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_ORDER_STATE_INVALID';
  END IF;
  IF v_document.source_warehouse_id<>(SELECT reservation.warehouse_id
      FROM public.backoffice_sales_reservations reservation
      WHERE reservation.company_id=v_company AND reservation.id=v_delivery.reservation_id
        AND reservation.sales_order_id=v_delivery.sales_order_id)
    OR NOT EXISTS(SELECT 1 FROM public.warehouses transit
      WHERE transit.company_id=v_company AND transit.id=v_document.destination_warehouse_id
        AND transit.is_active AND transit.transit_parent_warehouse_id=v_document.source_warehouse_id
        AND transit.transit_operation='SALES_DELIVERY_OUTBOUND') THEN
    RAISE EXCEPTION 'BACKOFFICE_DELIVERY_TRANSFER_LINEAGE_INVALID';
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

CREATE OR REPLACE FUNCTION private.reconcile_negative_stock_replenishment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_pos public.negative_stock_sale_allocations%rowtype;
  v_bo public.backoffice_negative_stock_allocations%rowtype;
  v_transit public.product_batches%rowtype;
  v_available numeric(24,6):=NEW.qty_remaining;v_outstanding numeric(24,6);
  v_take numeric(24,6);v_actual numeric(20,4);v_variance numeric(20,4);
  v_inventory numeric(20,4);v_cogs numeric(20,4);v_old_value numeric(24,4);
  v_new_value numeric(24,4);v_new_cogs numeric(24,10);
BEGIN
  IF v_available<=0 OR NEW.backoffice_negative_allocation_id IS NOT NULL THEN RETURN NEW; END IF;
  FOR v_pos IN SELECT * FROM public.negative_stock_sale_allocations allocation
    WHERE allocation.company_id=NEW.company_id AND allocation.stock_product_id=NEW.product_id
      AND allocation.warehouse_id=NEW.warehouse_id AND allocation.reconciled_at IS NULL
    ORDER BY allocation.created_at,allocation.id FOR UPDATE
  LOOP
    EXIT WHEN v_available<=0;
    v_outstanding:=v_pos.shortage_base_qty-v_pos.replenished_base_qty;
    v_take:=LEAST(v_available,v_outstanding);v_actual:=round(v_take*NEW.cogs_unit,4);
    v_variance:=v_actual-round(v_take*v_pos.provisional_unit_cost,4);
    INSERT INTO public.negative_stock_replenishment_allocations(company_id,
      negative_sale_allocation_id,product_batch_id,replenished_base_qty,
      provisional_unit_cost,actual_unit_cost,cost_variance_total)
    VALUES(NEW.company_id,v_pos.id,NEW.id,v_take,v_pos.provisional_unit_cost,
      NEW.cogs_unit,v_variance);
    UPDATE public.negative_stock_sale_allocations SET
      replenished_base_qty=replenished_base_qty+v_take,
      actual_cost_total=actual_cost_total+v_actual,
      cost_variance_total=cost_variance_total+v_variance,
      reconciled_at=CASE WHEN replenished_base_qty+v_take=shortage_base_qty
        THEN clock_timestamp() ELSE NULL END
    WHERE company_id=NEW.company_id AND id=v_pos.id;
    v_available:=v_available-v_take;
  END LOOP;
  FOR v_bo IN SELECT * FROM public.backoffice_negative_stock_allocations allocation
    WHERE allocation.company_id=NEW.company_id AND allocation.product_id=NEW.product_id
      AND allocation.source_warehouse_id=NEW.warehouse_id AND allocation.reconciled_at IS NULL
    ORDER BY allocation.created_at,allocation.id FOR UPDATE
  LOOP
    EXIT WHEN v_available<=0;
    v_outstanding:=v_bo.shortage_base_qty-v_bo.replenished_base_qty;
    v_take:=LEAST(v_available,v_outstanding);v_actual:=round(v_take*NEW.cogs_unit,4);
    v_variance:=v_actual-round(v_take*v_bo.provisional_unit_cost,4);
    SELECT * INTO STRICT v_transit FROM public.product_batches batch
    WHERE batch.company_id=NEW.company_id AND batch.id=v_bo.transit_batch_id FOR UPDATE;
    v_old_value:=round(v_transit.qty_remaining*v_transit.cogs_unit,4);
    IF v_transit.qty_remaining>0 THEN
      v_new_value:=GREATEST(v_old_value+v_variance,0);
      v_inventory:=v_new_value-v_old_value;v_cogs:=v_variance-v_inventory;
      v_new_cogs:=round(v_new_value/v_transit.qty_remaining,10);
      UPDATE public.product_batches SET cogs_unit=v_new_cogs
      WHERE company_id=NEW.company_id AND id=v_transit.id;
    ELSE
      v_inventory:=0;v_cogs:=v_variance;v_new_cogs:=v_transit.cogs_unit;
    END IF;
    INSERT INTO public.backoffice_negative_stock_replenishments(company_id,
      negative_allocation_id,product_batch_id,replenished_base_qty,
      provisional_unit_cost,actual_unit_cost,cost_variance_total,
      inventory_revaluation,cogs_variance,transit_qty_remaining_snapshot,
      previous_transit_unit_cost,revalued_transit_unit_cost)
    VALUES(NEW.company_id,v_bo.id,NEW.id,v_take,v_bo.provisional_unit_cost,
      NEW.cogs_unit,v_variance,v_inventory,v_cogs,v_transit.qty_remaining,
      v_transit.cogs_unit,v_new_cogs);
    UPDATE public.backoffice_negative_stock_allocations SET
      replenished_base_qty=replenished_base_qty+v_take,
      actual_cost_total=actual_cost_total+v_actual,
      inventory_revaluation_total=inventory_revaluation_total+v_inventory,
      cogs_variance_total=cogs_variance_total+v_cogs,
      reconciled_at=CASE WHEN replenished_base_qty+v_take=shortage_base_qty
        THEN clock_timestamp() ELSE NULL END
    WHERE company_id=NEW.company_id AND id=v_bo.id;
    v_available:=v_available-v_take;
  END LOOP;
  IF v_available IS DISTINCT FROM NEW.qty_remaining THEN
    UPDATE public.product_batches SET qty_remaining=v_available
    WHERE company_id=NEW.company_id AND id=NEW.id;
  END IF;
  RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION private.trg_nsc_goods_receipt_cost_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_quantity numeric(24,6);v_variance numeric(20,4);
  v_inventory_account uuid;v_cogs_account uuid;v_source_id uuid;
BEGIN
  IF NEW.system_event_key<>'GOODS_RECEIPT' OR NEW.source_table<>'goods_receipt_documents'
    OR NEW.status<>'HOLD'::public.event_status THEN RETURN NEW; END IF;
  SELECT COALESCE(sum(source.quantity),0),round(COALESCE(sum(source.variance),0),4)
    INTO v_quantity,v_variance
  FROM (
    SELECT replenishment.replenished_base_qty quantity,
      replenishment.cost_variance_total variance
    FROM public.negative_stock_replenishment_allocations replenishment
    JOIN public.product_batches batch ON batch.company_id=replenishment.company_id
      AND batch.id=replenishment.product_batch_id
    JOIN public.goods_receipt_lines line ON line.company_id=batch.company_id
      AND line.id=batch.goods_receipt_line_id
    WHERE line.company_id=NEW.company_id AND line.document_id=NEW.source_id
      AND replenishment.cost_variance_total<>0
    UNION ALL
    SELECT replenishment.replenished_base_qty,replenishment.cogs_variance
    FROM public.backoffice_negative_stock_replenishments replenishment
    JOIN public.product_batches batch ON batch.company_id=replenishment.company_id
      AND batch.id=replenishment.product_batch_id
    JOIN public.goods_receipt_lines line ON line.company_id=batch.company_id
      AND line.id=batch.goods_receipt_line_id
    WHERE line.company_id=NEW.company_id AND line.document_id=NEW.source_id
      AND replenishment.cogs_variance<>0
  ) source;
  IF v_quantity=0 THEN RETURN NEW; END IF;
  v_inventory_account:=NULLIF(NEW.amounts->>'inventoryAccountId','')::uuid;
  v_cogs_account:=private.resolve_opening_stock_account(NEW.company_id,
    NEW.transaction_category_id,'COGS',NEW.event_date);
  INSERT INTO public.inventory_cost_adjustment_sources(company_id,adjustment_type,
    source_document_table,source_document_id,source_financial_event_id,total_quantity_base,
    planned_cost_variance,inventory_variance,hpp_variance,inventory_account_id,
    offset_account_id,status,idempotency_key,created_by,applied_at)
  VALUES(NEW.company_id,'NEGATIVE_REPLENISHMENT','goods_receipt_documents',NEW.source_id,
    NEW.id,v_quantity,v_variance,-v_variance,v_variance,v_inventory_account,v_cogs_account,
    'APPLIED','NSC_NEGATIVE_REPLENISHMENT|'||NEW.company_id::text||'|'||NEW.source_id::text,
    NEW.created_by,clock_timestamp()) RETURNING id INTO v_source_id;
  UPDATE public.financial_events event SET amounts=event.amounts||jsonb_build_object(
    'negativeStockCostSettlementVersion',2,'inventoryCostAdjustmentSourceId',v_source_id,
    'negativeStockCostVariance',v_variance,'negativeStockCogsAccountId',v_cogs_account)
  WHERE event.company_id=NEW.company_id AND event.id=NEW.id;
  RETURN NEW;
END
$$;

DO $patch_dispatch$
DECLARE v_definition text;v_patched text;v_old text;v_count integer;
BEGIN
  SELECT pg_get_functiondef(
    'private.dispatch_backoffice_sales_delivery_to_transit(uuid,bigint,uuid,jsonb,text)'::regprocedure)
    INTO v_definition;
  v_old:='v_posted := private.post_stock_transfer(v_transfer_id, v_transfer_version, p_operation_id);';
  v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  IF v_count=0 THEN
    v_old:='v_posted:=private.post_stock_transfer(v_transfer_id,v_transfer_version,p_operation_id);';
    v_count:=(length(v_definition)-length(replace(v_definition,v_old,'')))/length(v_old);
  END IF;
  IF v_count<>1 THEN RAISE EXCEPTION
    'MIGRATION_PRECONDITION_FAILED: Backoffice Dispatch post call drift (matches=%)',v_count;
  END IF;
  v_patched:=replace(v_definition,v_old,
    'v_posted:=private.post_backoffice_sales_stock_transfer(v_transfer_id,v_transfer_version,p_operation_id,v_delivery.id);');
  EXECUTE v_patched;
END
$patch_dispatch$;

ALTER TABLE public.backoffice_negative_stock_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_negative_stock_replenishments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.backoffice_negative_stock_allocations,
  public.backoffice_negative_stock_replenishments FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.backoffice_negative_stock_allocations,
  public.backoffice_negative_stock_replenishments TO service_role;
REVOKE ALL ON FUNCTION
  private.post_backoffice_sales_stock_transfer(uuid,bigint,uuid,uuid),
  private.reconcile_negative_stock_replenishment(),
  private.trg_g4_guard_negative_sale_movement(),
  private.trg_nsc_goods_receipt_cost_source()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.post_backoffice_sales_stock_transfer(uuid,bigint,uuid,uuid),
  private.reconcile_negative_stock_replenishment(),
  private.trg_g4_guard_negative_sale_movement(),
  private.trg_nsc_goods_receipt_cost_source()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260911140000','backoffice_sales_negative_dispatch_runtime',
  'Warehouse-authorized Backoffice shortage Dispatch to outbound Transit with provisional FIFO, isolated transfer guard, replenishment revaluation, and COGS variance source; ordinary Transfer and POS contracts preserved');
COMMIT;
