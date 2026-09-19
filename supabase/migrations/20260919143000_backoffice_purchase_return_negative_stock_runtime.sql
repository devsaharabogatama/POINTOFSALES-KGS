-- Backoffice Supplier Return negative-stock forward fix.
--
-- A Goods Receipt can be consumed immediately while repairing an existing
-- negative On Hand.  Its source batch can therefore have zero remaining FIFO
-- even though the received commercial quantity is still returnable.  This
-- migration keeps the exact Receipt/PO/cost lineage, never consumes another
-- batch, permits the Return to restore the shortage, and lets a later Goods
-- Receipt settle that shortage with the cost difference posted to PPV.
BEGIN;

DO $guard$
DECLARE v_definition text;v_constraint text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260919143000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260919143000';
  END IF;
  IF (SELECT count(*) FROM private.kgs_schema_migrations
      WHERE version IN('20260919140000','20260919141000','20260919142000'))<>3 THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Backoffice Purchase Return dependencies missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.system_events event
      WHERE event.system_key='GOODS_RECEIPT' AND event.is_active) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: GOODS_RECEIPT Finance event missing';
  END IF;
  IF to_regclass('public.purchase_return_stock_shortages') IS NOT NULL
    OR to_regclass('public.purchase_return_shortage_replenishments') IS NOT NULL
    OR to_regclass('public.purchase_return_shortage_cost_adjustments') IS NOT NULL THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: shortage object collision';
  END IF;
  SELECT pg_get_functiondef(
    'public.get_backoffice_purchase_return_workspace(uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'EXACT_SOURCE_BATCH'
    OR v_definition!~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return workspace drift';
  END IF;
  SELECT pg_get_functiondef(
    'public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'v_return_base>v_source.qty_remaining' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Draft runtime drift';
  END IF;
  SELECT pg_get_functiondef(
    'public.post_backoffice_purchase_return(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
    OR v_definition!~'stock_qty>=v_line.return_base_qty' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Return Post runtime drift';
  END IF;
  SELECT pg_get_constraintdef(oid) INTO v_constraint FROM pg_constraint
  WHERE conrelid='public.stock_movements'::regclass
    AND conname='stock_movements_balance_after_controlled';
  IF v_constraint IS NULL OR v_constraint!~'TRANSFER_OUT'
    OR v_constraint~'PURCHASE_RETURN' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Stock Movement constraint drift';
  END IF;
END
$guard$;

CREATE TABLE public.purchase_return_stock_shortages(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  document_id uuid NOT NULL,
  return_line_id uuid NOT NULL,
  source_product_batch_id uuid NOT NULL,
  product_id uuid NOT NULL,
  warehouse_id uuid NOT NULL,
  shortage_base_qty numeric(24,6) NOT NULL,
  replenished_base_qty numeric(24,6) NOT NULL DEFAULT 0,
  provisional_unit_cost numeric(20,4) NOT NULL,
  provisional_cost_total numeric(20,4) NOT NULL,
  actual_cost_total numeric(20,4) NOT NULL DEFAULT 0,
  purchase_price_variance_total numeric(20,4) NOT NULL DEFAULT 0,
  warehouse_version bigint NOT NULL,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  reconciled_at timestamptz,
  CONSTRAINT purchase_return_stock_shortages_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT purchase_return_stock_shortages_line_unique
    UNIQUE(company_id,return_line_id),
  CONSTRAINT purchase_return_stock_shortages_document_fk
    FOREIGN KEY(company_id,document_id)
    REFERENCES public.purchase_return_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_stock_shortages_line_fk
    FOREIGN KEY(company_id,return_line_id)
    REFERENCES public.purchase_return_lines(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_stock_shortages_batch_fk
    FOREIGN KEY(company_id,source_product_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_stock_shortages_product_fk
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_stock_shortages_warehouse_fk
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_stock_shortages_shape CHECK(
    shortage_base_qty>0 AND replenished_base_qty>=0
    AND replenished_base_qty<=shortage_base_qty
    AND provisional_unit_cost>=0
    AND provisional_cost_total=round(shortage_base_qty*provisional_unit_cost,4)
    AND actual_cost_total>=0 AND warehouse_version>0
    AND ((replenished_base_qty=shortage_base_qty AND reconciled_at IS NOT NULL)
      OR (replenished_base_qty<shortage_base_qty AND reconciled_at IS NULL)))
);
CREATE INDEX purchase_return_stock_shortages_open
  ON public.purchase_return_stock_shortages(
    company_id,warehouse_id,product_id,created_at,id)
  WHERE reconciled_at IS NULL;

CREATE TABLE public.purchase_return_shortage_replenishments(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL,
  shortage_id uuid NOT NULL,
  product_batch_id uuid NOT NULL,
  replenished_base_qty numeric(24,6) NOT NULL,
  provisional_unit_cost numeric(20,4) NOT NULL,
  actual_unit_cost numeric(20,4) NOT NULL,
  purchase_price_variance_total numeric(20,4) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT purchase_return_shortage_replenishments_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT purchase_return_shortage_replenishments_source_unique
    UNIQUE(company_id,shortage_id,product_batch_id),
  CONSTRAINT purchase_return_shortage_replenishments_shortage_fk
    FOREIGN KEY(company_id,shortage_id)
    REFERENCES public.purchase_return_stock_shortages(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_shortage_replenishments_batch_fk
    FOREIGN KEY(company_id,product_batch_id)
    REFERENCES public.product_batches(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_shortage_replenishments_shape CHECK(
    replenished_base_qty>0 AND provisional_unit_cost>=0 AND actual_unit_cost>=0
    AND purchase_price_variance_total=
      round(replenished_base_qty*(actual_unit_cost-provisional_unit_cost),4))
);

CREATE TABLE public.purchase_return_shortage_cost_adjustments(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
  goods_receipt_id uuid NOT NULL,
  financial_event_id uuid NOT NULL,
  total_quantity_base numeric(24,6) NOT NULL,
  purchase_price_variance_total numeric(20,4) NOT NULL,
  inventory_account_id uuid NOT NULL,
  purchase_price_variance_account_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'APPLIED',
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  posted_at timestamptz,
  CONSTRAINT purchase_return_shortage_cost_company_id_id_unique
    UNIQUE(company_id,id),
  CONSTRAINT purchase_return_shortage_cost_receipt_unique
    UNIQUE(company_id,goods_receipt_id),
  CONSTRAINT purchase_return_shortage_cost_event_unique
    UNIQUE(company_id,financial_event_id),
  CONSTRAINT purchase_return_shortage_cost_receipt_fk
    FOREIGN KEY(company_id,goods_receipt_id)
    REFERENCES public.goods_receipt_documents(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_shortage_cost_event_fk
    FOREIGN KEY(company_id,financial_event_id)
    REFERENCES public.financial_events(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_shortage_cost_inventory_account_fk
    FOREIGN KEY(company_id,inventory_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_shortage_cost_variance_account_fk
    FOREIGN KEY(company_id,purchase_price_variance_account_id)
    REFERENCES public.chart_of_accounts(company_id,id) ON DELETE RESTRICT,
  CONSTRAINT purchase_return_shortage_cost_shape CHECK(
    total_quantity_base>0 AND status IN('APPLIED','POSTED')
    AND ((status='APPLIED' AND posted_at IS NULL)
      OR (status='POSTED' AND posted_at IS NOT NULL)))
);

ALTER TABLE public.purchase_return_stock_shortages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_shortage_replenishments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_return_shortage_cost_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.purchase_return_stock_shortages,
  public.purchase_return_shortage_replenishments,
  public.purchase_return_shortage_cost_adjustments FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE ON public.purchase_return_stock_shortages,
  public.purchase_return_shortage_replenishments,
  public.purchase_return_shortage_cost_adjustments TO service_role;

UPDATE public.system_events event SET
  conditional_account_functions=ARRAY(
    SELECT DISTINCT function_key FROM unnest(COALESCE(
      event.conditional_account_functions,ARRAY[]::text[])
      ||ARRAY['PURCHASE_PRICE_VARIANCE']::text[]) function_key
    ORDER BY function_key)
WHERE event.system_key='GOODS_RECEIPT'
  AND NOT ('PURCHASE_PRICE_VARIANCE'=ANY(COALESCE(
    event.conditional_account_functions,ARRAY[]::text[])));

-- Workspace availability is the unreturned commercial Receipt quantity.
-- Remaining source FIFO is informational and never a Draft blocker.
DO $patch_workspace$
DECLARE v_definition text;v_patched text;v_hits integer;
BEGIN
  SELECT pg_get_functiondef(
    'public.get_backoffice_purchase_return_workspace(uuid)'::regprocedure)
    INTO v_definition;
  IF v_definition!~'EXACT_SOURCE_BATCH' THEN
    RAISE EXCEPTION 'WORKSPACE_PATCH_FAILED: policy anchor missing';
  END IF;
  v_patched:=replace(v_definition,'EXACT_SOURCE_BATCH',
    'SOURCE_RECEIPT_WITH_NEGATIVE_SHORTAGE');
  SELECT count(*) INTO v_hits FROM regexp_matches(v_patched,
    'GREATEST\(LEAST\([[:space:]]*allocation\.quantity_base[[:space:]]*-[[:space:]]*COALESCE\(posted_return\.base_qty,[[:space:]]*0(::numeric)?\),[[:space:]]*batch\.qty_remaining\),[[:space:]]*0(::numeric)?\)','g');
  IF v_hits<>4 THEN
    RAISE EXCEPTION 'WORKSPACE_PATCH_FAILED: expected 4 FIFO-cap anchors, got %',v_hits;
  END IF;
  v_patched:=regexp_replace(v_patched,
    'GREATEST\(LEAST\([[:space:]]*allocation\.quantity_base[[:space:]]*-[[:space:]]*COALESCE\(posted_return\.base_qty,[[:space:]]*0(::numeric)?\),[[:space:]]*batch\.qty_remaining\),[[:space:]]*0(::numeric)?\)',
    'GREATEST(allocation.quantity_base-COALESCE(posted_return.base_qty, 0), 0)','g');
  SELECT count(*) INTO v_hits FROM regexp_matches(v_patched,
    'batch\.qty_remaining[[:space:]]*<=[[:space:]]*0(::numeric)?','g');
  IF v_hits<>1 THEN
    RAISE EXCEPTION 'WORKSPACE_PATCH_FAILED: expected 1 FIFO blocker condition, got %',v_hits;
  END IF;
  -- Keep the CASE shape stable across pg_get_functiondef formatting, but make
  -- the obsolete FIFO-only branch unreachable. The following commercial
  -- received-minus-posted-return branch remains authoritative.
  v_patched:=regexp_replace(v_patched,
    'batch\.qty_remaining[[:space:]]*<=[[:space:]]*0(::numeric)?',
    'FALSE','g');
  v_patched:=replace(v_patched,'PURCHASE_RETURN_FIFO_NOT_AVAILABLE',
    'PURCHASE_RETURN_SOURCE_FULLY_RETURNED');
  IF v_patched=v_definition OR v_patched~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
    OR v_patched!~'SOURCE_RECEIPT_WITH_NEGATIVE_SHORTAGE'
    OR v_patched!~'WHEN[[:space:]]+\(?FALSE\)?[[:space:]]+THEN' THEN
    RAISE EXCEPTION 'WORKSPACE_PATCH_FAILED: FIFO blocker remains';
  END IF;
  EXECUTE v_patched;
END
$patch_workspace$;

DO $patch_draft$
DECLARE v_definition text;v_patched text;
BEGIN
  SELECT pg_get_functiondef(
    'public.save_backoffice_purchase_return_draft(uuid,bigint,uuid,uuid,uuid,date,text,text,text,jsonb)'::regprocedure)
    INTO v_definition;
  v_patched:=regexp_replace(v_definition,
    'IF[[:space:]]+v_prior_return[[:space:]]*\+[[:space:]]*v_return_base[[:space:]]*>[[:space:]]*v_source\.quantity_base[[:space:]]+OR[[:space:]]+v_return_base[[:space:]]*>[[:space:]]*v_source\.qty_remaining[[:space:]]+THEN',
    'IF v_prior_return+v_return_base>v_source.quantity_base THEN');
  IF v_patched=v_definition
    OR v_patched~'v_return_base[[:space:]]*>[[:space:]]*v_source\.qty_remaining' THEN
    RAISE EXCEPTION 'DRAFT_PATCH_FAILED: FIFO quantity anchor remains';
  END IF;
  EXECUTE v_patched;
END
$patch_draft$;

-- Permit the canonical PURCHASE_RETURN movement below zero.  The trigger below
-- still requires a source-linked shortage row and Warehouse opt-in.
ALTER TABLE public.stock_movements
  DROP CONSTRAINT stock_movements_balance_after_controlled,
  ADD CONSTRAINT stock_movements_balance_after_controlled CHECK(
    balance_after_base_qty IS NULL OR balance_after_base_qty>=0 OR qty_change>0
    OR (movement_type='SALE'::public.stock_movement_type
      AND reference_table='sales_headers')
    OR (movement_type='TRANSFER_OUT'::public.stock_movement_type
      AND reference_table='stock_transfer_documents')
    OR (movement_type='PURCHASE_RETURN'::public.stock_movement_type
      AND reference_table='purchase_return_documents')
    OR (movement_type='REVERSAL'::public.stock_movement_type
      AND reference_table='sales_headers' AND qty_change>0));

CREATE OR REPLACE FUNCTION private.trg_g4_guard_negative_sale_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.balance_after_base_qty<0 AND NEW.qty_change<0 AND NOT (
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
        AND allocation.authority_source='WAREHOUSE' AND allocation.warehouse_version>0
        AND NEW.movement_type='TRANSFER_OUT'::public.stock_movement_type
        AND NEW.reference_table='stock_transfer_documents')
    OR EXISTS(SELECT 1
      FROM public.purchase_return_fifo_allocations fifo
      JOIN public.purchase_return_stock_shortages shortage
        ON shortage.company_id=fifo.company_id
       AND shortage.return_line_id=fifo.return_line_id
      JOIN public.warehouses warehouse
        ON warehouse.company_id=shortage.company_id
       AND warehouse.id=shortage.warehouse_id
       AND warehouse.allow_negative_stock
       AND warehouse.master_version=shortage.warehouse_version
      WHERE fifo.company_id=NEW.company_id AND fifo.id=NEW.source_line_id
        AND shortage.document_id=NEW.reference_id
        AND shortage.product_id=NEW.product_id
        AND shortage.warehouse_id=NEW.warehouse_id
        AND NEW.movement_type='PURCHASE_RETURN'::public.stock_movement_type
        AND NEW.reference_table='purchase_return_documents')
    OR (NEW.movement_type='REVERSAL'::public.stock_movement_type
      AND NEW.reference_table='sales_headers' AND NEW.qty_change>0
      AND EXISTS(SELECT 1 FROM public.stock_movements original
        WHERE original.company_id=NEW.company_id AND original.id=NEW.source_line_id
          AND original.product_id=NEW.product_id
          AND original.warehouse_id=NEW.warehouse_id
          AND original.reference_id=NEW.reference_id
          AND original.reference_table='sales_headers'
          AND original.movement_type='SALE'::public.stock_movement_type
          AND original.movement_status='POSTED'
          AND original.qty_change=-NEW.qty_change))
  ) THEN RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'; END IF;
  RETURN NEW;
END
$$;

DO $patch_post$
DECLARE v_definition text;v_patched text;v_hits integer;
  v_old text;v_new text;
BEGIN
  SELECT pg_get_functiondef(
    'public.post_backoffice_purchase_return(uuid,bigint,uuid)'::regprocedure)
    INTO v_definition;
  v_patched:=replace(v_definition,
    'v_note_no text;',
    'v_note_no text; v_batch_take numeric(24,6); v_shortage numeric(24,6); v_warehouse_allow_negative boolean; v_warehouse_version bigint;');
  v_old:='SELECT * INTO v_batch FROM public.product_batches batch
    WHERE batch.company_id=v_company AND batch.id=v_line.source_product_batch_id
      AND batch.product_id=v_line.product_id
      AND batch.warehouse_id=v_document.source_warehouse_id FOR UPDATE;
    IF NOT FOUND OR v_batch.qty_remaining<v_line.return_base_qty THEN
      RAISE EXCEPTION ''PURCHASE_RETURN_FIFO_NOT_AVAILABLE''; END IF;
    UPDATE public.product_batches SET qty_remaining=qty_remaining-v_line.return_base_qty
    WHERE company_id=v_company AND id=v_batch.id;
    UPDATE public.product_stocks SET stock_qty=stock_qty-v_line.return_base_qty,
      updated_at=v_now WHERE company_id=v_company AND product_id=v_line.product_id
      AND warehouse_id=v_document.source_warehouse_id
      AND stock_qty>=v_line.return_base_qty RETURNING stock_qty INTO v_stock_after;
    IF NOT FOUND THEN RAISE EXCEPTION ''PURCHASE_RETURN_STOCK_NOT_AVAILABLE''; END IF;
    INSERT INTO public.purchase_return_fifo_allocations(company_id,document_id,
      return_line_id,source_product_batch_id,product_id,warehouse_id,
      quantity_base,fifo_unit_cost,fifo_cost_total)
    VALUES(v_company,v_document.id,v_line.id,v_batch.id,v_line.product_id,
      v_document.source_warehouse_id,v_line.return_base_qty,v_batch.cogs_unit,
      round(v_line.return_base_qty*v_batch.cogs_unit,4)) RETURNING id INTO v_fifo_id;
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_line.product_id,v_document.source_warehouse_id,-v_line.return_base_qty,
      ''PURCHASE_RETURN''::public.stock_movement_type,''purchase_return_documents'',
      v_document.id,v_company,v_line.base_uom_id,v_line.base_uom_name_snapshot,
      v_stock_after,v_actor,v_now,''POSTED'',v_fifo_id,
      ''Backoffice Supplier Return from exact Goods Receipt FIFO'');
    v_inventory_total:=v_inventory_total+round(v_line.return_base_qty*v_batch.cogs_unit,4);';
  v_new:='SELECT * INTO v_batch FROM public.product_batches batch
    WHERE batch.company_id=v_company AND batch.id=v_line.source_product_batch_id
      AND batch.product_id=v_line.product_id
      AND batch.warehouse_id=v_document.source_warehouse_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION ''PURCHASE_RETURN_SOURCE_BATCH_NOT_FOUND''; END IF;
    SELECT warehouse.allow_negative_stock,warehouse.master_version
      INTO v_warehouse_allow_negative,v_warehouse_version
    FROM public.warehouses warehouse
    WHERE warehouse.company_id=v_company AND warehouse.id=v_document.source_warehouse_id
      AND warehouse.is_active FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION ''ACTIVE_RETURN_SOURCE_WAREHOUSE_NOT_FOUND''; END IF;
    v_batch_take:=LEAST(v_batch.qty_remaining,v_line.return_base_qty);
    v_shortage:=v_line.return_base_qty-v_batch_take;
    IF v_batch_take>0 THEN
      UPDATE public.product_batches SET qty_remaining=qty_remaining-v_batch_take
      WHERE company_id=v_company AND id=v_batch.id;
    END IF;
    UPDATE public.product_stocks SET stock_qty=stock_qty-v_line.return_base_qty,
      updated_at=v_now WHERE company_id=v_company AND product_id=v_line.product_id
      AND warehouse_id=v_document.source_warehouse_id
      RETURNING stock_qty INTO v_stock_after;
    IF NOT FOUND THEN RAISE EXCEPTION ''PURCHASE_RETURN_STOCK_ROW_NOT_FOUND''; END IF;
    IF v_stock_after<0 AND NOT v_warehouse_allow_negative THEN
      RAISE EXCEPTION ''NEGATIVE_STOCK_REQUIRES_WAREHOUSE_OPT_IN''; END IF;
    INSERT INTO public.purchase_return_fifo_allocations(company_id,document_id,
      return_line_id,source_product_batch_id,product_id,warehouse_id,
      quantity_base,fifo_unit_cost,fifo_cost_total)
    VALUES(v_company,v_document.id,v_line.id,v_batch.id,v_line.product_id,
      v_document.source_warehouse_id,v_line.return_base_qty,v_batch.cogs_unit,
      round(v_line.return_base_qty*v_batch.cogs_unit,4)) RETURNING id INTO v_fifo_id;
    IF v_shortage>0 THEN
      INSERT INTO public.purchase_return_stock_shortages(company_id,document_id,
        return_line_id,source_product_batch_id,product_id,warehouse_id,
        shortage_base_qty,provisional_unit_cost,provisional_cost_total,
        warehouse_version,created_by)
      VALUES(v_company,v_document.id,v_line.id,v_batch.id,v_line.product_id,
        v_document.source_warehouse_id,v_shortage,v_batch.cogs_unit,
        round(v_shortage*v_batch.cogs_unit,4),v_warehouse_version,v_actor);
    END IF;
    INSERT INTO public.stock_movements(product_id,warehouse_id,qty_change,
      movement_type,reference_table,reference_id,company_id,base_uom_id,
      base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,
      movement_status,source_line_id,notes)
    VALUES(v_line.product_id,v_document.source_warehouse_id,-v_line.return_base_qty,
      ''PURCHASE_RETURN''::public.stock_movement_type,''purchase_return_documents'',
      v_document.id,v_company,v_line.base_uom_id,v_line.base_uom_name_snapshot,
      v_stock_after,v_actor,v_now,''POSTED'',v_fifo_id,
      CASE WHEN v_shortage>0
        THEN ''Backoffice Supplier Return; source FIFO exhausted quantity restored as negative Stock''
        ELSE ''Backoffice Supplier Return from source Goods Receipt FIFO'' END);
    v_inventory_total:=v_inventory_total+round(v_line.return_base_qty*v_batch.cogs_unit,4);';
  IF position(v_old in v_patched)=0 THEN
    -- pg_get_functiondef normalizes whitespace; replace the one bounded Stock
    -- block rather than accepting an unpatched runtime.
    SELECT count(*) INTO v_hits FROM regexp_matches(v_patched,
      'SELECT \* INTO v_batch FROM public\.product_batches batch[[:space:][:print:]]*v_inventory_total := v_inventory_total \+ round\(v_line\.return_base_qty \* v_batch\.cogs_unit, 4\);','g');
    IF v_hits<>1 THEN
      RAISE EXCEPTION 'POST_PATCH_FAILED: expected 1 Stock block anchor, got %',v_hits;
    END IF;
    v_patched:=regexp_replace(v_patched,
      'SELECT \* INTO v_batch FROM public\.product_batches batch[[:space:][:print:]]*v_inventory_total := v_inventory_total \+ round\(v_line\.return_base_qty \* v_batch\.cogs_unit, 4\);',
      v_new);
  ELSE
    v_patched:=replace(v_patched,v_old,v_new);
  END IF;
  IF v_patched=v_definition OR v_patched~'PURCHASE_RETURN_FIFO_NOT_AVAILABLE'
    OR v_patched~'stock_qty[[:space:]]*>=[[:space:]]*v_line\.return_base_qty'
    OR v_patched!~'purchase_return_stock_shortages' THEN
    RAISE EXCEPTION 'POST_PATCH_FAILED: exact FIFO/positive Stock gate remains';
  END IF;
  EXECUTE v_patched;
END
$patch_post$;

CREATE OR REPLACE FUNCTION private.reconcile_negative_stock_replenishment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
  v_pos public.negative_stock_sale_allocations%rowtype;
  v_bo public.backoffice_negative_stock_allocations%rowtype;
  v_return public.purchase_return_stock_shortages%rowtype;
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
  FOR v_return IN SELECT * FROM public.purchase_return_stock_shortages shortage
    WHERE shortage.company_id=NEW.company_id AND shortage.product_id=NEW.product_id
      AND shortage.warehouse_id=NEW.warehouse_id AND shortage.reconciled_at IS NULL
    ORDER BY shortage.created_at,shortage.id FOR UPDATE
  LOOP
    EXIT WHEN v_available<=0;
    v_outstanding:=v_return.shortage_base_qty-v_return.replenished_base_qty;
    v_take:=LEAST(v_available,v_outstanding);v_actual:=round(v_take*NEW.cogs_unit,4);
    v_variance:=round(v_take*(NEW.cogs_unit-v_return.provisional_unit_cost),4);
    INSERT INTO public.purchase_return_shortage_replenishments(company_id,
      shortage_id,product_batch_id,replenished_base_qty,provisional_unit_cost,
      actual_unit_cost,purchase_price_variance_total)
    VALUES(NEW.company_id,v_return.id,NEW.id,v_take,v_return.provisional_unit_cost,
      NEW.cogs_unit,v_variance);
    UPDATE public.purchase_return_stock_shortages SET
      replenished_base_qty=replenished_base_qty+v_take,
      actual_cost_total=actual_cost_total+v_actual,
      purchase_price_variance_total=purchase_price_variance_total+v_variance,
      reconciled_at=CASE WHEN replenished_base_qty+v_take=shortage_base_qty
        THEN clock_timestamp() ELSE NULL END
    WHERE company_id=NEW.company_id AND id=v_return.id;
    v_available:=v_available-v_take;
  END LOOP;
  IF v_available IS DISTINCT FROM NEW.qty_remaining THEN
    UPDATE public.product_batches SET qty_remaining=v_available
    WHERE company_id=NEW.company_id AND id=NEW.id;
  END IF;
  RETURN NEW;
END
$$;

CREATE FUNCTION private.trg_purchase_return_shortage_cost_source()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_quantity numeric(24,6);v_variance numeric(20,4);
  v_inventory_account uuid;v_variance_account uuid;
BEGIN
  IF NEW.system_event_key<>'GOODS_RECEIPT'
    OR NEW.source_table<>'goods_receipt_documents'
    OR NEW.status<>'HOLD'::public.event_status THEN RETURN NEW; END IF;
  SELECT COALESCE(sum(replenishment.replenished_base_qty),0),
    round(COALESCE(sum(replenishment.purchase_price_variance_total),0),4)
    INTO v_quantity,v_variance
  FROM public.purchase_return_shortage_replenishments replenishment
  JOIN public.product_batches batch ON batch.company_id=replenishment.company_id
    AND batch.id=replenishment.product_batch_id
  JOIN public.goods_receipt_lines receipt_line ON receipt_line.company_id=batch.company_id
    AND receipt_line.id=batch.goods_receipt_line_id
  WHERE receipt_line.company_id=NEW.company_id
    AND receipt_line.document_id=NEW.source_id;
  IF v_quantity=0 OR v_variance=0 THEN RETURN NEW; END IF;
  v_inventory_account:=NULLIF(NEW.amounts->>'inventoryAccountId','')::uuid;
  IF v_inventory_account IS NULL THEN
    v_inventory_account:=private.resolve_opening_stock_account(NEW.company_id,
      NEW.transaction_category_id,'INVENTORY_ASSET',NEW.event_date);
  END IF;
  v_variance_account:=private.resolve_opening_stock_account(NEW.company_id,
    NEW.transaction_category_id,'PURCHASE_PRICE_VARIANCE',NEW.event_date);
  INSERT INTO public.purchase_return_shortage_cost_adjustments(company_id,
    goods_receipt_id,financial_event_id,total_quantity_base,
    purchase_price_variance_total,inventory_account_id,
    purchase_price_variance_account_id,status,created_by)
  VALUES(NEW.company_id,NEW.source_id,NEW.id,v_quantity,v_variance,
    v_inventory_account,v_variance_account,'APPLIED',NEW.created_by);
  UPDATE public.financial_events event SET amounts=event.amounts||jsonb_build_object(
    'purchaseReturnShortageSettlementVersion',1,
    'purchaseReturnShortageQuantity',v_quantity,
    'purchaseReturnShortagePurchasePriceVariance',v_variance,
    'purchaseReturnShortageInventoryAccountId',v_inventory_account,
    'purchaseReturnShortageVarianceAccountId',v_variance_account)
  WHERE event.company_id=NEW.company_id AND event.id=NEW.id;
  RETURN NEW;
END
$$;
CREATE TRIGGER purchase_return_shortage_cost_source
AFTER INSERT ON public.financial_events FOR EACH ROW
EXECUTE FUNCTION private.trg_purchase_return_shortage_cost_source();

CREATE FUNCTION private.trg_purchase_return_shortage_journal_lines()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_adjustment public.purchase_return_shortage_cost_adjustments%rowtype;
  v_supplier uuid;
BEGIN
  IF NEW.source_type<>'goods_receipt_documents'
    OR NEW.financial_event_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO v_adjustment FROM public.purchase_return_shortage_cost_adjustments adjustment
  WHERE adjustment.company_id=NEW.company_id
    AND adjustment.financial_event_id=NEW.financial_event_id
    AND adjustment.status='APPLIED';
  IF NOT FOUND THEN RETURN NEW; END IF;
  SELECT order_document.supplier_id INTO v_supplier
  FROM public.goods_receipt_documents receipt
  JOIN public.supplier_order_documents order_document
    ON order_document.company_id=receipt.company_id
   AND order_document.id=receipt.supplier_order_id
  WHERE receipt.company_id=NEW.company_id
    AND receipt.id=v_adjustment.goods_receipt_id;
  PERFORM private.nsc_insert_signed_journal_line(NEW.company_id,NEW.id,900011,
    v_adjustment.inventory_account_id,-v_adjustment.purchase_price_variance_total,
    NEW.store_id,NEW.warehouse_id,v_supplier,
    'PURCHASE_RETURN_SHORTAGE_INVENTORY_VARIANCE');
  PERFORM private.nsc_insert_signed_journal_line(NEW.company_id,NEW.id,900012,
    v_adjustment.purchase_price_variance_account_id,
    v_adjustment.purchase_price_variance_total,NEW.store_id,NEW.warehouse_id,
    v_supplier,'PURCHASE_RETURN_SHORTAGE_PURCHASE_PRICE_VARIANCE');
  RETURN NEW;
END
$$;
CREATE TRIGGER purchase_return_shortage_journal_lines
AFTER INSERT ON public.finance_journals FOR EACH ROW
EXECUTE FUNCTION private.trg_purchase_return_shortage_journal_lines();

CREATE FUNCTION private.trg_purchase_return_shortage_cost_posted()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF OLD.status='HOLD'::public.event_status
    AND NEW.status='POSTED'::public.event_status THEN
    UPDATE public.purchase_return_shortage_cost_adjustments adjustment SET
      status='POSTED',posted_at=COALESCE(NEW.processed_at,clock_timestamp())
    WHERE adjustment.company_id=NEW.company_id
      AND adjustment.financial_event_id=NEW.id AND adjustment.status='APPLIED';
  END IF;
  RETURN NEW;
END
$$;
CREATE TRIGGER purchase_return_shortage_cost_posted
AFTER UPDATE OF status ON public.financial_events FOR EACH ROW
EXECUTE FUNCTION private.trg_purchase_return_shortage_cost_posted();

REVOKE ALL ON FUNCTION private.trg_purchase_return_shortage_cost_source(),
  private.trg_purchase_return_shortage_journal_lines(),
  private.trg_purchase_return_shortage_cost_posted()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_purchase_return_shortage_cost_source(),
  private.trg_purchase_return_shortage_journal_lines(),
  private.trg_purchase_return_shortage_cost_posted()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260919143000','backoffice_purchase_return_negative_stock_runtime',
  'Allows source-linked Backoffice Supplier Return after its Receipt FIFO was consumed by negative On Hand; never consumes unrelated batches, records the restored shortage, settles it from later Goods Receipts, and posts future cost differences to Purchase Price Variance');

NOTIFY pgrst,'reload schema';
COMMIT;
