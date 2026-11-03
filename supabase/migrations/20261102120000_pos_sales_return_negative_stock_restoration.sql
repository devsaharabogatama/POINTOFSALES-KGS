-- Restore a physical Sales Return from the exact negative-stock source Sale.
-- This is a forward-only correction; installed migrations remain immutable.
BEGIN;
SET LOCAL lock_timeout='5s';

DO $guard$
DECLARE
  v_return_definition text;
  v_trigger_definition text;
  v_lineage_definition text;
BEGIN
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260805190000','20260805220000','20260831130000',
        '20260911140000','20260919143000','20261102100000','20261102110000'))<>7 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: negative Return dependency chain incomplete';
  END IF;
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20261102120000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20261102120000';
  END IF;
  IF to_regprocedure('private.acp5h_post_sales_return_core(uuid,bigint,uuid)') IS NULL
    OR to_regprocedure('private.reconcile_negative_stock_replenishment()') IS NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: canonical Return runtime missing';
  END IF;
  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_return_definition;
  SELECT pg_get_functiondef(
    'private.reconcile_negative_stock_replenishment()'::regprocedure)
    INTO v_trigger_definition;
  IF md5(v_return_definition)<>'9a4ec8f10eacec926435e99deb1fca26'
    OR v_return_definition NOT LIKE '%SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED%'
    OR v_return_definition NOT LIKE '%sales_return_fifo_restorations%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return core changed';
  END IF;
  IF md5(v_trigger_definition)<>'ef37126de5f098b97223d9877e460cd1'
    OR v_trigger_definition NOT LIKE '%negative_stock_sale_allocations%'
    OR v_trigger_definition NOT LIKE '%purchase_return_stock_shortages%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: replenishment trigger changed';
  END IF;
  SELECT pg_get_constraintdef(constraint_row.oid,true)
    INTO v_lineage_definition
  FROM pg_constraint constraint_row
  JOIN pg_class relation ON relation.oid=constraint_row.conrelid
  JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
  WHERE namespace.nspname='public' AND relation.relname='product_batches'
    AND constraint_row.conname='product_batches_source_lineage_check';
  IF v_lineage_definition IS NULL
    OR v_lineage_definition NOT LIKE '%backoffice_negative_allocation_id%'
    OR v_lineage_definition LIKE '%sales_return_negative_allocation_id%' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Product Batch lineage changed';
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

ALTER TABLE public.product_batches
  ADD COLUMN sales_return_negative_allocation_id uuid;

ALTER TABLE public.product_batches
  DROP CONSTRAINT product_batches_source_lineage_check,
  ADD CONSTRAINT product_batches_source_lineage_check CHECK(
    (stock_transfer_line_id IS NULL AND sales_return_line_id IS NULL
      AND source_batch_id IS NULL AND backoffice_negative_allocation_id IS NULL
      AND sales_return_negative_allocation_id IS NULL)
    OR (stock_transfer_line_id IS NOT NULL AND sales_return_line_id IS NULL
      AND source_batch_id IS NOT NULL AND backoffice_negative_allocation_id IS NULL
      AND sales_return_negative_allocation_id IS NULL)
    OR (stock_transfer_line_id IS NULL AND sales_return_line_id IS NOT NULL
      AND source_batch_id IS NOT NULL AND backoffice_negative_allocation_id IS NULL
      AND sales_return_negative_allocation_id IS NULL)
    OR (stock_transfer_line_id IS NULL AND sales_return_line_id IS NULL
      AND source_batch_id IS NULL AND backoffice_negative_allocation_id IS NOT NULL
      AND sales_return_negative_allocation_id IS NULL)
    OR (stock_transfer_line_id IS NULL AND sales_return_line_id IS NOT NULL
      AND backoffice_negative_allocation_id IS NULL
      AND sales_return_negative_allocation_id IS NOT NULL)),
  ADD CONSTRAINT product_batches_sales_return_negative_allocation_fk
    FOREIGN KEY(company_id,sales_return_negative_allocation_id)
    REFERENCES public.negative_stock_sale_allocations(company_id,id)
    ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;

CREATE INDEX product_batches_sales_return_negative_allocation
  ON public.product_batches(company_id,sales_return_negative_allocation_id)
  WHERE sales_return_negative_allocation_id IS NOT NULL;

ALTER TABLE public.negative_stock_replenishment_allocations
  ADD CONSTRAINT negative_stock_replenishments_company_id_id_unique
  UNIQUE(company_id,id);

CREATE TABLE public.sales_return_negative_stock_restorations(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  document_id uuid NOT NULL,
  return_line_id uuid NOT NULL,
  source_negative_allocation_id uuid NOT NULL,
  source_replenishment_allocation_id uuid NOT NULL,
  restored_product_batch_id uuid NOT NULL,
  product_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  source_mode text NOT NULL,
  quantity_base numeric(24,6) NOT NULL,
  unit_cost numeric(20,4) NOT NULL,
  cost_total numeric(20,4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT sales_return_negative_restorations_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT sales_return_negative_restoration_source_unique
    UNIQUE(company_id,return_line_id,source_replenishment_allocation_id),
  CONSTRAINT sales_return_negative_restoration_shape CHECK(
    source_mode IN('OUTSTANDING_PROVISIONAL','REPLENISHED_ACTUAL')
    AND quantity_base>0 AND unit_cost>=0
    AND cost_total=round(quantity_base*unit_cost,4)),
  CONSTRAINT sales_return_negative_restoration_document_fk
    FOREIGN KEY(company_id,document_id)
    REFERENCES public.sales_return_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_return_negative_restoration_line_fk
    FOREIGN KEY(company_id,return_line_id)
    REFERENCES public.sales_return_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_return_negative_restoration_allocation_fk
    FOREIGN KEY(company_id,source_negative_allocation_id)
    REFERENCES public.negative_stock_sale_allocations(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_return_negative_restoration_replenishment_fk
    FOREIGN KEY(company_id,source_replenishment_allocation_id)
    REFERENCES public.negative_stock_replenishment_allocations(company_id,id)
    ON DELETE RESTRICT,
  CONSTRAINT sales_return_negative_restoration_batch_fk
    FOREIGN KEY(company_id,restored_product_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_return_negative_restoration_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT sales_return_negative_restoration_warehouse_fk
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX sales_return_negative_restoration_document
  ON public.sales_return_negative_stock_restorations(company_id,document_id,created_at,id);

CREATE TRIGGER guard_final_sales_return_negative_restorations
BEFORE INSERT OR UPDATE OR DELETE ON public.sales_return_negative_stock_restorations
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_sales_return_history_guard();

ALTER TABLE public.sales_return_negative_stock_restorations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Sales Return negative restoration visible in active Company"
ON public.sales_return_negative_stock_restorations FOR SELECT TO authenticated
USING(
  public.private_request_company_matches(company_id)
  AND EXISTS(
    SELECT 1 FROM public.sales_return_documents document
    WHERE document.company_id=sales_return_negative_stock_restorations.company_id
      AND document.id=sales_return_negative_stock_restorations.document_id
      AND public.private_cashier_session_visible(document.executing_session_id)));
REVOKE ALL ON public.sales_return_negative_stock_restorations
  FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.sales_return_negative_stock_restorations TO authenticated;
GRANT ALL ON public.sales_return_negative_stock_restorations TO service_role;

-- The tag prevents a Return batch from being consumed by an unrelated oldest
-- shortage. An outstanding source is settled only against its exact allocation;
-- an already-replenished source remains available as returned On Hand.
DO $patch_trigger$
DECLARE
  v_definition text;
  v_anchor text:='BEGIN
  IF v_available<=0 OR NEW.backoffice_negative_allocation_id IS NOT NULL THEN RETURN NEW; END IF;';
  v_replacement text:='BEGIN
  IF NEW.sales_return_negative_allocation_id IS NOT NULL THEN
    SELECT * INTO v_pos
    FROM public.negative_stock_sale_allocations allocation
    WHERE allocation.company_id=NEW.company_id
      AND allocation.id=NEW.sales_return_negative_allocation_id
      AND allocation.stock_product_id=NEW.product_id
      AND allocation.warehouse_id=NEW.warehouse_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION ''RETURN_NEGATIVE_SOURCE_MISMATCH'';
    END IF;
    IF NOT EXISTS(
      SELECT 1 FROM public.sales_return_lines return_line
      WHERE return_line.company_id=NEW.company_id
        AND return_line.id=NEW.sales_return_line_id
        AND return_line.source_sales_detail_id=v_pos.sales_detail_id) THEN
      RAISE EXCEPTION ''RETURN_NEGATIVE_SOURCE_LINE_MISMATCH'';
    END IF;
    IF NEW.source_batch_id IS NOT NULL THEN RETURN NEW; END IF;
    v_outstanding:=v_pos.shortage_base_qty-v_pos.replenished_base_qty;
    IF NEW.qty_remaining<=0 OR NEW.qty_remaining>v_outstanding THEN
      RAISE EXCEPTION ''RETURN_NEGATIVE_OUTSTANDING_EXHAUSTED'';
    END IF;
    v_take:=NEW.qty_remaining;
    v_actual:=round(v_take*NEW.cogs_unit,4);
    v_variance:=v_actual-round(v_take*v_pos.provisional_unit_cost,4);
    IF v_variance<>0 THEN
      RAISE EXCEPTION ''RETURN_NEGATIVE_PROVISIONAL_COST_MISMATCH'';
    END IF;
    INSERT INTO public.negative_stock_replenishment_allocations(company_id,
      negative_sale_allocation_id,product_batch_id,replenished_base_qty,
      provisional_unit_cost,actual_unit_cost,cost_variance_total)
    VALUES(NEW.company_id,v_pos.id,NEW.id,v_take,v_pos.provisional_unit_cost,
      NEW.cogs_unit,0);
    UPDATE public.negative_stock_sale_allocations SET
      replenished_base_qty=replenished_base_qty+v_take,
      actual_cost_total=actual_cost_total+v_actual,
      reconciled_at=CASE WHEN replenished_base_qty+v_take=shortage_base_qty
        THEN clock_timestamp() ELSE NULL END
    WHERE company_id=NEW.company_id AND id=v_pos.id;
    UPDATE public.product_batches SET qty_remaining=0
    WHERE company_id=NEW.company_id AND id=NEW.id;
    RETURN NEW;
  END IF;
  IF v_available<=0 OR NEW.backoffice_negative_allocation_id IS NOT NULL THEN RETURN NEW; END IF;';
BEGIN
  SELECT pg_get_functiondef(
    'private.reconcile_negative_stock_replenishment()'::regprocedure)
    INTO v_definition;
  IF md5(v_definition)<>'ef37126de5f098b97223d9877e460cd1'
    OR (length(v_definition)-length(replace(v_definition,v_anchor,'')))
       /length(v_anchor)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: replenishment patch anchor changed';
  END IF;
  v_definition:=replace(v_definition,v_anchor,v_replacement);
  EXECUTE v_definition;
END
$patch_trigger$;

CREATE FUNCTION private.restore_sales_return_negative_stock(
  p_company_id uuid,
  p_document_id uuid,
  p_return_line_id uuid,
  p_stock_requirement_id uuid,
  p_actor_id uuid,
  p_posted_at timestamptz,
  p_quantity_base numeric
) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_line public.sales_return_lines%rowtype;
  v_requirement public.sale_stock_requirements%rowtype;
  v_negative public.negative_stock_sale_allocations%rowtype;
  v_replenishment public.negative_stock_replenishment_allocations%rowtype;
  v_remaining numeric(24,6):=round(p_quantity_base,6);
  v_available numeric(24,6);
  v_take numeric(24,6);
  v_batch_id uuid;
  v_restoration_id uuid;
  v_created_replenishment_id uuid;
  v_stock_after numeric(24,6);
  v_total_cost numeric(20,4):=0;
BEGIN
  IF p_quantity_base<=0 THEN RETURN 0; END IF;
  SELECT * INTO STRICT v_line FROM public.sales_return_lines line
  WHERE line.company_id=p_company_id AND line.id=p_return_line_id;
  SELECT * INTO STRICT v_requirement FROM public.sale_stock_requirements requirement
  WHERE requirement.company_id=p_company_id AND requirement.id=p_stock_requirement_id
    AND requirement.sales_detail_id=v_line.source_sales_detail_id
  FOR UPDATE;
  SELECT * INTO v_negative FROM public.negative_stock_sale_allocations allocation
  WHERE allocation.company_id=p_company_id
    AND allocation.stock_requirement_id=v_requirement.id
    AND allocation.sales_detail_id=v_line.source_sales_detail_id
    AND allocation.stock_product_id=v_requirement.stock_product_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED'; END IF;
  IF v_line.destination_warehouse_id IS DISTINCT FROM v_negative.warehouse_id THEN
    RAISE EXCEPTION 'NEGATIVE_SOURCE_RETURN_DESTINATION_MISMATCH';
  END IF;

  v_available:=v_negative.shortage_base_qty-v_negative.replenished_base_qty;
  IF v_available>0 THEN
    v_take:=LEAST(v_remaining,v_available);
    INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
      qty_purchased,qty_remaining,cogs_unit,company_id,source_batch_id,
      sales_return_line_id,sales_return_negative_allocation_id)
    VALUES(v_requirement.stock_product_id,v_line.destination_warehouse_id,NULL,
      v_take,v_take,v_negative.provisional_unit_cost,p_company_id,NULL,
      v_line.id,v_negative.id)
    RETURNING id INTO v_batch_id;
    SELECT replenishment.id INTO STRICT v_created_replenishment_id
    FROM public.negative_stock_replenishment_allocations replenishment
    WHERE replenishment.company_id=p_company_id
      AND replenishment.negative_sale_allocation_id=v_negative.id
      AND replenishment.product_batch_id=v_batch_id;
    INSERT INTO public.sales_return_negative_stock_restorations(company_id,
      document_id,return_line_id,source_negative_allocation_id,
      source_replenishment_allocation_id,restored_product_batch_id,
      product_id,warehouse_id,source_mode,quantity_base,unit_cost,cost_total)
    VALUES(p_company_id,p_document_id,v_line.id,v_negative.id,
      v_created_replenishment_id,v_batch_id,v_requirement.stock_product_id,
      v_line.destination_warehouse_id,'OUTSTANDING_PROVISIONAL',v_take,
      v_negative.provisional_unit_cost,
      round(v_take*v_negative.provisional_unit_cost,4))
    RETURNING id INTO v_restoration_id;
    INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
    VALUES(v_requirement.stock_product_id,v_line.destination_warehouse_id,
      v_take,p_company_id)
    ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
      stock_qty=public.product_stocks.stock_qty+EXCLUDED.stock_qty,
      updated_at=p_posted_at
    RETURNING stock_qty INTO v_stock_after;
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_requirement.stock_product_id,v_line.destination_warehouse_id,v_take,
      'SALES_RETURN'::public.stock_movement_type,'sales_return_documents',
      p_document_id,p_company_id,v_requirement.stock_uom_id,
      v_requirement.stock_uom_name_snapshot,v_stock_after,p_actor_id,p_posted_at,
      'POSTED',v_restoration_id,'Restored from exact outstanding negative Sale source');
    v_total_cost:=v_total_cost+round(v_take*v_negative.provisional_unit_cost,4);
    v_remaining:=v_remaining-v_take;
  END IF;

  FOR v_replenishment IN
    SELECT replenishment.*
    FROM public.negative_stock_replenishment_allocations replenishment
    JOIN public.product_batches source_batch
      ON source_batch.company_id=replenishment.company_id
     AND source_batch.id=replenishment.product_batch_id
    WHERE replenishment.company_id=p_company_id
      AND replenishment.negative_sale_allocation_id=v_negative.id
      AND source_batch.sales_return_line_id IS NULL
    ORDER BY replenishment.created_at,replenishment.id
    FOR UPDATE OF replenishment
  LOOP
    EXIT WHEN v_remaining<=0;
    SELECT v_replenishment.replenished_base_qty-COALESCE(sum(restoration.quantity_base),0)
      INTO v_available
    FROM public.sales_return_negative_stock_restorations restoration
    WHERE restoration.company_id=p_company_id
      AND restoration.source_replenishment_allocation_id=v_replenishment.id;
    v_available:=COALESCE(v_available,v_replenishment.replenished_base_qty);
    IF v_available<=0 THEN CONTINUE; END IF;
    v_take:=LEAST(v_remaining,v_available);
    INSERT INTO public.product_batches(product_id,warehouse_id,purchase_detail_id,
      qty_purchased,qty_remaining,cogs_unit,company_id,source_batch_id,
      sales_return_line_id,sales_return_negative_allocation_id)
    VALUES(v_requirement.stock_product_id,v_line.destination_warehouse_id,NULL,
      v_take,v_take,v_replenishment.actual_unit_cost,p_company_id,
      v_replenishment.product_batch_id,v_line.id,v_negative.id)
    RETURNING id INTO v_batch_id;
    INSERT INTO public.sales_return_negative_stock_restorations(company_id,
      document_id,return_line_id,source_negative_allocation_id,
      source_replenishment_allocation_id,restored_product_batch_id,
      product_id,warehouse_id,source_mode,quantity_base,unit_cost,cost_total)
    VALUES(p_company_id,p_document_id,v_line.id,v_negative.id,
      v_replenishment.id,v_batch_id,v_requirement.stock_product_id,
      v_line.destination_warehouse_id,'REPLENISHED_ACTUAL',v_take,
      v_replenishment.actual_unit_cost,
      round(v_take*v_replenishment.actual_unit_cost,4))
    RETURNING id INTO v_restoration_id;
    INSERT INTO public.product_stocks(product_id,warehouse_id,stock_qty,company_id)
    VALUES(v_requirement.stock_product_id,v_line.destination_warehouse_id,
      v_take,p_company_id)
    ON CONFLICT(product_id,warehouse_id) DO UPDATE SET
      stock_qty=public.product_stocks.stock_qty+EXCLUDED.stock_qty,
      updated_at=p_posted_at
    RETURNING stock_qty INTO v_stock_after;
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_requirement.stock_product_id,v_line.destination_warehouse_id,v_take,
      'SALES_RETURN'::public.stock_movement_type,'sales_return_documents',
      p_document_id,p_company_id,v_requirement.stock_uom_id,
      v_requirement.stock_uom_name_snapshot,v_stock_after,p_actor_id,p_posted_at,
      'POSTED',v_restoration_id,'Restored from exact replenished negative Sale source');
    v_total_cost:=v_total_cost+round(v_take*v_replenishment.actual_unit_cost,4);
    v_remaining:=v_remaining-v_take;
  END LOOP;
  IF v_remaining<>0 THEN
    RAISE EXCEPTION 'SOURCE_SALE_NEGATIVE_RESTORATION_EXHAUSTED';
  END IF;
  RETURN v_total_cost;
END
$$;

REVOKE ALL ON FUNCTION private.restore_sales_return_negative_stock(
  uuid,uuid,uuid,uuid,uuid,timestamptz,numeric) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.restore_sales_return_negative_stock(
  uuid,uuid,uuid,uuid,uuid,timestamptz,numeric) TO service_role;

DO $patch_return$
DECLARE
  v_definition text;
  v_anchor text:='IF v_remaining<>0 THEN
                    RAISE EXCEPTION ''SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED'';
                END IF;';
  v_replacement text:='IF v_remaining<>0 THEN
                    v_line_cost:=v_line_cost+private.restore_sales_return_negative_stock(
                        v_company,v_document.id,v_line.id,v_requirement.id,
                        v_actor,v_now,v_remaining
                    );
                    v_remaining:=0;
                END IF;';
BEGIN
  SELECT pg_get_functiondef(
    'private.acp5h_post_sales_return_core(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  IF md5(v_definition)<>'9a4ec8f10eacec926435e99deb1fca26'
    OR (length(v_definition)-length(replace(v_definition,v_anchor,'')))
       /length(v_anchor)<>1 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return patch anchor changed';
  END IF;
  v_definition:=replace(v_definition,v_anchor,v_replacement);
  EXECUTE v_definition;
END
$patch_return$;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20261102120000','pos_sales_return_negative_stock_restoration',
  'Restores physical Sales Return quantity and cost from its exact POS negative-stock source without consuming unrelated shortages; preserves positive FIFO, Backoffice routing, refund and Finance posting');

NOTIFY pgrst,'reload schema';
COMMIT;
