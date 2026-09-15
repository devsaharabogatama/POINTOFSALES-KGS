-- Step 4/6.5A: Warehouse discrepancy-resolution effect and Backorder lineage.
-- Foundation only: no public resolution RPC and no operational Stock effect.
BEGIN;

DO $guard$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: overage commercial approval required';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260912110000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260912110000';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF to_regclass('public.backoffice_sales_discrepancy_stock_effects') IS NOT NULL
    OR to_regclass('public.backoffice_sales_discrepancy_fifo_allocations') IS NOT NULL
    OR to_regclass('public.backoffice_sales_discrepancy_backorders') IS NOT NULL
    OR to_regclass('public.backoffice_sales_discrepancy_backorder_lines') IS NOT NULL
    OR EXISTS(SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='backoffice_sales_order_lines'
        AND column_name='approved_overage_base_qty') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Warehouse resolution foundation collision';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_constraint
    WHERE conrelid='public.stock_movements'::regclass
      AND conname='bo_stock_movements_company_id_unique') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Stock movement tenant identity collision';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
    WHERE line.requested_resolution='ACCEPT_OVERAGE'
      AND line.warehouse_resolution_status NOT IN('NOT_REQUIRED','PENDING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: accepted overage Warehouse state requires reconciliation';
  END IF;
  IF (SELECT count(*) FROM pg_constraint constraint_row
      WHERE (constraint_row.conrelid='public.backoffice_sales_delivery_discrepancy_lines'::regclass
          AND constraint_row.conname='backoffice_sales_delivery_discrepancy_lines_warehouse_check')
        OR (constraint_row.conrelid='public.backoffice_sales_order_lines'::regclass
          AND constraint_row.conname='backoffice_sales_order_lines_invoiceable_quantity_check'))<>2 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Warehouse resolution source constraint drift';
  END IF;
  IF EXISTS(SELECT 1 FROM public.backoffice_sales_order_lines line
    WHERE line.accepted_base_qty>line.ordered_base_qty) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: existing accepted quantity exceeds unapproved overage boundary';
  END IF;
END
$guard$;

-- Accepted overage must still pass Warehouse physical reconciliation after its
-- commercial approval. Existing runtime rows can only be NOT_REQUIRED/PENDING;
-- converting NOT_REQUIRED to PENDING does not invent a physical result.
ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  DROP CONSTRAINT backoffice_sales_delivery_discrepancy_lines_warehouse_check;
UPDATE public.backoffice_sales_delivery_discrepancy_lines
SET warehouse_resolution_status='PENDING',updated_at=clock_timestamp()
WHERE requested_resolution='ACCEPT_OVERAGE'
  AND warehouse_resolution_status='NOT_REQUIRED';
ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  ADD CONSTRAINT backoffice_sales_delivery_discrepancy_lines_warehouse_check CHECK(
    (discrepancy_type='SHORT'
      AND warehouse_resolution_status IN('PENDING','RESOLVED','REJECTED'))
    OR (requested_resolution IN('ACCEPT_OVERAGE','RETURN_OVERAGE','REPLACE_WRONG_ITEM')
      AND warehouse_resolution_status IN('PENDING','RESOLVED','REJECTED'))
    OR (discrepancy_type<>'SHORT'
      AND requested_resolution NOT IN('ACCEPT_OVERAGE','RETURN_OVERAGE','REPLACE_WRONG_ITEM')
      AND warehouse_resolution_status='NOT_REQUIRED'));

UPDATE public.backoffice_sales_delivery_discrepancies discrepancy
SET requires_warehouse_resolution=true,
  status=CASE WHEN discrepancy.status='OPEN'
    THEN 'PENDING_WAREHOUSE_RESOLUTION' ELSE discrepancy.status END,
  master_version=discrepancy.master_version+1,
  updated_at=clock_timestamp()
WHERE EXISTS(SELECT 1 FROM public.backoffice_sales_delivery_discrepancy_lines line
  WHERE line.company_id=discrepancy.company_id AND line.discrepancy_id=discrepancy.id
    AND line.requested_resolution='ACCEPT_OVERAGE')
  AND (NOT discrepancy.requires_warehouse_resolution OR discrepancy.status='OPEN');

CREATE OR REPLACE FUNCTION private.classify_backoffice_sales_discrepancy(
  p_discrepancy_type text,p_requested_resolution text,p_physical_state text
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
SET search_path=public,pg_temp AS $$
DECLARE
  v_type text:=upper(btrim(COALESCE(p_discrepancy_type,'')));
  v_resolution text:=upper(btrim(COALESCE(p_requested_resolution,'')));
  v_physical text:=NULLIF(upper(btrim(COALESCE(p_physical_state,''))), '');
  v_valid boolean:=false;v_sales boolean:=false;v_warehouse boolean:=false;
BEGIN
  v_valid:=CASE v_type
    WHEN 'SHORT' THEN v_resolution IN('BACKORDER','ACCEPT_SHORT')
      AND v_physical IN('NOT_LOADED','RETURNING','LOST','DAMAGED')
    WHEN 'OVERAGE' THEN v_resolution IN('ACCEPT_OVERAGE','RETURN_OVERAGE')
      AND v_physical IS NULL
    WHEN 'WRONG_ITEM' THEN v_resolution='REPLACE_WRONG_ITEM'
      AND v_physical IS NULL
    ELSE false END;
  IF v_type='SHORT' AND v_resolution IN('BACKORDER','ACCEPT_SHORT')
    AND v_physical IS NULL THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_PHYSICAL_STATE_REQUIRED';
  END IF;
  IF NOT v_valid THEN RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_ACTION_INVALID'; END IF;
  v_sales:=v_resolution='ACCEPT_OVERAGE';
  v_warehouse:=v_type='SHORT'
    OR v_resolution IN('ACCEPT_OVERAGE','RETURN_OVERAGE','REPLACE_WRONG_ITEM');
  RETURN jsonb_build_object('discrepancyType',v_type,
    'requestedResolution',v_resolution,'physicalState',v_physical,
    'requiresSalesApproval',v_sales,
    'requiresWarehouseResolution',v_warehouse);
END
$$;

ALTER TABLE public.backoffice_sales_order_lines
  ADD COLUMN approved_overage_base_qty numeric(24,6) NOT NULL DEFAULT 0;
ALTER TABLE public.backoffice_sales_order_lines
  DROP CONSTRAINT backoffice_sales_order_lines_invoiceable_quantity_check,
  ADD CONSTRAINT backoffice_sales_order_lines_invoiceable_quantity_check CHECK(
    approved_overage_base_qty>=0 AND approved_overage_base_qty<=accepted_base_qty
    AND accepted_base_qty>=0
    AND accepted_base_qty<=ordered_base_qty+approved_overage_base_qty
    AND returned_before_invoice_base_qty>=0
    AND returned_before_invoice_base_qty<=accepted_base_qty
    AND draft_invoice_allocated_base_qty>=0 AND invoiced_base_qty>=0
    AND draft_invoice_allocated_base_qty+invoiced_base_qty
      <=accepted_base_qty-returned_before_invoice_base_qty);

ALTER TABLE public.backoffice_sales_delivery_discrepancy_lines
  ADD CONSTRAINT bo_sales_discrepancy_lines_case_identity_unique
    UNIQUE(company_id,discrepancy_id,id);
ALTER TABLE public.backoffice_sales_discrepancy_operations
  ADD CONSTRAINT bo_sales_discrepancy_operations_case_identity_unique
    UNIQUE(company_id,discrepancy_id,id);
ALTER TABLE public.stock_movements
  ADD CONSTRAINT bo_stock_movements_company_id_unique UNIQUE(company_id,id);

CREATE TABLE public.backoffice_sales_discrepancy_stock_effects(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  discrepancy_id uuid NOT NULL,
  discrepancy_line_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  effect_type text NOT NULL,
  product_id uuid NOT NULL,
  source_warehouse_id uuid NOT NULL,
  destination_warehouse_id uuid,
  quantity_base numeric(24,6) NOT NULL,
  total_cost numeric(24,4) NOT NULL,
  source_stock_movement_id uuid NOT NULL,
  destination_stock_movement_id uuid,
  stock_transfer_document_id uuid,
  financial_event_id uuid,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_discrepancy_stock_effects_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_discrepancy_stock_effects_source_unique
    UNIQUE(company_id,discrepancy_line_id,effect_type),
  CONSTRAINT backoffice_sales_discrepancy_stock_effects_case_fk
    FOREIGN KEY(company_id,discrepancy_id)
    REFERENCES public.backoffice_sales_delivery_discrepancies(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_stock_effects_line_fk
    FOREIGN KEY(company_id,discrepancy_id,discrepancy_line_id)
    REFERENCES public.backoffice_sales_delivery_discrepancy_lines(company_id,discrepancy_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_stock_effects_operation_fk
    FOREIGN KEY(company_id,discrepancy_id,operation_id)
    REFERENCES public.backoffice_sales_discrepancy_operations(company_id,discrepancy_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_effects_source_movement_fk
    FOREIGN KEY(company_id,source_stock_movement_id)
    REFERENCES public.stock_movements(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_effects_destination_movement_fk
    FOREIGN KEY(company_id,destination_stock_movement_id)
    REFERENCES public.stock_movements(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_stock_effects_product_fk
    FOREIGN KEY(company_id,product_id) REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_effects_source_warehouse_fk
    FOREIGN KEY(company_id,source_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_effects_destination_warehouse_fk
    FOREIGN KEY(company_id,destination_warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_stock_effects_transfer_fk
    FOREIGN KEY(company_id,stock_transfer_document_id)
    REFERENCES public.stock_transfer_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_stock_effects_event_fk
    FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_stock_effects_shape_check CHECK(
    effect_type IN('EXPECTED_RETURN_TO_SOURCE','EXPECTED_WRITE_OFF',
      'ACTUAL_TO_TRANSIT','ACTUAL_RETURN_TO_SOURCE','OVERAGE_TO_TRANSIT',
      'OVERAGE_RETURN_TO_SOURCE','OVERAGE_ACCEPTED_SALE')
    AND quantity_base>0 AND total_cost>=0
    AND ((effect_type IN('EXPECTED_RETURN_TO_SOURCE','ACTUAL_TO_TRANSIT',
          'ACTUAL_RETURN_TO_SOURCE','OVERAGE_TO_TRANSIT','OVERAGE_RETURN_TO_SOURCE')
        AND destination_warehouse_id IS NOT NULL
        AND destination_warehouse_id<>source_warehouse_id
        AND destination_stock_movement_id IS NOT NULL
        AND financial_event_id IS NULL)
      OR (effect_type IN('EXPECTED_WRITE_OFF','OVERAGE_ACCEPTED_SALE')
        AND destination_warehouse_id IS NULL
        AND destination_stock_movement_id IS NULL
        AND financial_event_id IS NOT NULL))
    AND ((effect_type IN('ACTUAL_TO_TRANSIT','OVERAGE_TO_TRANSIT')
        AND stock_transfer_document_id IS NOT NULL)
      OR (effect_type NOT IN('ACTUAL_TO_TRANSIT','OVERAGE_TO_TRANSIT')
        AND stock_transfer_document_id IS NULL))));

-- Exact FIFO lineage prevents a resolution from consuming another DO's Transit
-- batch merely because Product and Warehouse happen to be equal.
CREATE TABLE public.backoffice_sales_discrepancy_fifo_allocations(
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  company_id uuid NOT NULL,
  stock_effect_id uuid NOT NULL,
  source_batch_id uuid NOT NULL,
  destination_batch_id uuid,
  quantity_base numeric(24,6) NOT NULL,
  unit_cost numeric(24,6) NOT NULL,
  total_cost numeric(24,4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_discrepancy_fifo_source_unique
    UNIQUE(company_id,stock_effect_id,source_batch_id),
  CONSTRAINT backoffice_sales_discrepancy_fifo_destination_unique
    UNIQUE(company_id,destination_batch_id),
  CONSTRAINT backoffice_sales_discrepancy_fifo_effect_fk
    FOREIGN KEY(company_id,stock_effect_id)
    REFERENCES public.backoffice_sales_discrepancy_stock_effects(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_fifo_source_batch_fk
    FOREIGN KEY(company_id,source_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_fifo_destination_batch_fk
    FOREIGN KEY(company_id,destination_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_fifo_amount_check CHECK(
    quantity_base>0 AND unit_cost>=0
    AND total_cost=round(quantity_base*unit_cost,4)));

CREATE TABLE public.backoffice_sales_discrepancy_backorders(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  discrepancy_id uuid NOT NULL,
  source_delivery_order_id uuid NOT NULL,
  backorder_delivery_order_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_discrepancy_backorders_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_discrepancy_backorders_case_unique UNIQUE(company_id,discrepancy_id),
  CONSTRAINT backoffice_sales_discrepancy_backorders_target_unique
    UNIQUE(company_id,backorder_delivery_order_id),
  CONSTRAINT backoffice_sales_discrepancy_backorders_case_fk
    FOREIGN KEY(company_id,discrepancy_id)
    REFERENCES public.backoffice_sales_delivery_discrepancies(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_backorders_source_fk
    FOREIGN KEY(company_id,source_delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_backorders_target_fk
    FOREIGN KEY(company_id,backorder_delivery_order_id)
    REFERENCES public.backoffice_sales_delivery_orders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT bo_sales_discrepancy_backorders_operation_fk
    FOREIGN KEY(company_id,discrepancy_id,operation_id)
    REFERENCES public.backoffice_sales_discrepancy_operations(company_id,discrepancy_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_backorders_distinct_check CHECK(
    source_delivery_order_id<>backorder_delivery_order_id));

CREATE TABLE public.backoffice_sales_discrepancy_backorder_lines(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  backorder_id uuid NOT NULL,
  discrepancy_line_id uuid NOT NULL,
  backorder_delivery_order_line_id uuid NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT backoffice_sales_discrepancy_backorder_lines_company_id_unique UNIQUE(company_id,id),
  CONSTRAINT backoffice_sales_discrepancy_backorder_lines_source_unique
    UNIQUE(company_id,discrepancy_line_id),
  CONSTRAINT backoffice_sales_discrepancy_backorder_lines_target_unique
    UNIQUE(company_id,backorder_delivery_order_line_id),
  CONSTRAINT backoffice_sales_discrepancy_backorder_lines_header_fk
    FOREIGN KEY(company_id,backorder_id)
    REFERENCES public.backoffice_sales_discrepancy_backorders(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_backorder_lines_case_line_fk
    FOREIGN KEY(company_id,discrepancy_line_id)
    REFERENCES public.backoffice_sales_delivery_discrepancy_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_backorder_lines_target_fk
    FOREIGN KEY(company_id,backorder_delivery_order_line_id)
    REFERENCES public.backoffice_sales_delivery_order_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT backoffice_sales_discrepancy_backorder_lines_quantity_check CHECK(quantity_base>0));

CREATE INDEX backoffice_sales_discrepancy_stock_effects_case
  ON public.backoffice_sales_discrepancy_stock_effects(company_id,discrepancy_id,created_at,id);
CREATE INDEX backoffice_sales_discrepancy_fifo_effect
  ON public.backoffice_sales_discrepancy_fifo_allocations(company_id,stock_effect_id,id);

CREATE FUNCTION private.validate_backoffice_sales_discrepancy_stock_effect()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_source record;v_destination record;v_transfer record;v_event record;
BEGIN
  SELECT product_id,warehouse_id,qty_change,movement_status INTO STRICT v_source
  FROM public.stock_movements
  WHERE company_id=NEW.company_id AND id=NEW.source_stock_movement_id;
  IF v_source.product_id<>NEW.product_id
    OR v_source.warehouse_id<>NEW.source_warehouse_id
    OR v_source.qty_change<>-NEW.quantity_base
    OR v_source.movement_status<>'POSTED' THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_SOURCE_MOVEMENT_INVALID';
  END IF;
  IF NEW.destination_stock_movement_id IS NOT NULL THEN
    SELECT product_id,warehouse_id,qty_change,movement_status
    INTO STRICT v_destination FROM public.stock_movements
    WHERE company_id=NEW.company_id AND id=NEW.destination_stock_movement_id;
    IF v_destination.product_id<>NEW.product_id
      OR v_destination.warehouse_id<>NEW.destination_warehouse_id
      OR v_destination.qty_change<>NEW.quantity_base
      OR v_destination.movement_status<>'POSTED' THEN
      RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_DESTINATION_MOVEMENT_INVALID';
    END IF;
  END IF;
  IF NEW.stock_transfer_document_id IS NOT NULL THEN
    SELECT source_warehouse_id,destination_warehouse_id,status INTO STRICT v_transfer
    FROM public.stock_transfer_documents
    WHERE company_id=NEW.company_id AND id=NEW.stock_transfer_document_id;
    IF v_transfer.source_warehouse_id<>NEW.source_warehouse_id
      OR v_transfer.destination_warehouse_id<>NEW.destination_warehouse_id
      OR v_transfer.status<>'POSTED' THEN
      RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_STOCK_TRANSFER_INVALID';
    END IF;
  END IF;
  IF NEW.financial_event_id IS NOT NULL THEN
    SELECT status INTO STRICT v_event FROM public.financial_events
    WHERE company_id=NEW.company_id AND id=NEW.financial_event_id;
    IF v_event.status NOT IN('HOLD','POSTED') THEN
      RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_FINANCIAL_EVENT_INVALID';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.validate_backoffice_sales_discrepancy_fifo_allocation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE v_effect record;v_source record;v_destination record;
BEGIN
  SELECT product_id,source_warehouse_id,destination_warehouse_id,effect_type
  INTO STRICT v_effect FROM public.backoffice_sales_discrepancy_stock_effects
  WHERE company_id=NEW.company_id AND id=NEW.stock_effect_id;
  SELECT product_id,warehouse_id INTO STRICT v_source
  FROM public.product_batches
  WHERE company_id=NEW.company_id AND id=NEW.source_batch_id;
  IF v_source.product_id<>v_effect.product_id
    OR v_source.warehouse_id<>v_effect.source_warehouse_id THEN
    RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_SOURCE_BATCH_INVALID';
  END IF;
  IF v_effect.destination_warehouse_id IS NULL THEN
    IF NEW.destination_batch_id IS NOT NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_DESTINATION_BATCH_NOT_ALLOWED';
    END IF;
  ELSE
    IF NEW.destination_batch_id IS NULL THEN
      RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_DESTINATION_BATCH_REQUIRED';
    END IF;
    SELECT product_id,warehouse_id INTO STRICT v_destination
    FROM public.product_batches
    WHERE company_id=NEW.company_id AND id=NEW.destination_batch_id;
    IF v_destination.product_id<>v_effect.product_id
      OR v_destination.warehouse_id<>v_effect.destination_warehouse_id THEN
      RAISE EXCEPTION 'BACKOFFICE_DISCREPANCY_DESTINATION_BATCH_INVALID';
    END IF;
  END IF;
  RETURN NEW;
END
$$;

CREATE TRIGGER backoffice_sales_discrepancy_stock_effects_validate
BEFORE INSERT ON public.backoffice_sales_discrepancy_stock_effects
FOR EACH ROW EXECUTE FUNCTION private.validate_backoffice_sales_discrepancy_stock_effect();
CREATE TRIGGER backoffice_sales_discrepancy_fifo_allocations_validate
BEFORE INSERT ON public.backoffice_sales_discrepancy_fifo_allocations
FOR EACH ROW EXECUTE FUNCTION private.validate_backoffice_sales_discrepancy_fifo_allocation();

CREATE TRIGGER backoffice_sales_discrepancy_stock_effects_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_discrepancy_stock_effects
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history();
CREATE TRIGGER backoffice_sales_discrepancy_fifo_allocations_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_discrepancy_fifo_allocations
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history();
CREATE TRIGGER backoffice_sales_discrepancy_backorders_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_discrepancy_backorders
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history();
CREATE TRIGGER backoffice_sales_discrepancy_backorder_lines_immutable
BEFORE UPDATE OR DELETE ON public.backoffice_sales_discrepancy_backorder_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_guard_backoffice_sales_discrepancy_history();

ALTER TABLE public.backoffice_sales_discrepancy_stock_effects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_discrepancy_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_discrepancy_backorders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.backoffice_sales_discrepancy_backorder_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.backoffice_sales_discrepancy_stock_effects,
  public.backoffice_sales_discrepancy_fifo_allocations,
  public.backoffice_sales_discrepancy_backorders,
  public.backoffice_sales_discrepancy_backorder_lines FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.backoffice_sales_discrepancy_stock_effects,
  public.backoffice_sales_discrepancy_fifo_allocations,
  public.backoffice_sales_discrepancy_backorders,
  public.backoffice_sales_discrepancy_backorder_lines TO service_role;
REVOKE ALL ON FUNCTION
  private.validate_backoffice_sales_discrepancy_stock_effect(),
  private.validate_backoffice_sales_discrepancy_fifo_allocation()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
  private.validate_backoffice_sales_discrepancy_stock_effect(),
  private.validate_backoffice_sales_discrepancy_fifo_allocation()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260912110000','backoffice_sales_warehouse_resolution_foundation',
  'Step 4/6.5A makes accepted overage Warehouse-resolvable, records approved overage quantity boundary, and adds immutable exact FIFO/Stock effect/Backorder lineage without activating resolution');
NOTIFY pgrst,'reload schema';
COMMIT;
