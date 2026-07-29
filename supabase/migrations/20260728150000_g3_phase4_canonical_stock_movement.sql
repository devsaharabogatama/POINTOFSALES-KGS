-- KGS POS G3 phase 4: canonical Stock Movement audit foundation.
-- Dependency: G3 Opening Stock through 20260728120000.
--
-- EXPAND-ONLY:
-- - existing movement identity and source columns remain unchanged;
-- - canonical snapshots are enforced immediately for OPENING_BALANCE;
-- - future movement types must populate their snapshots when their source
--   workflow is opened in the appropriate roadmap phase;
-- - no Transfer/Sale/Return/Opname/Adjustment posting is enabled here.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260728120000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G3 Opening Stock dependency missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260728150000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260728150000';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.product_stocks ps
        FULL JOIN (
            SELECT company_id,product_id,warehouse_id,sum(qty_change) AS qty
            FROM public.stock_movements
            GROUP BY company_id,product_id,warehouse_id
        ) mt
          ON mt.company_id = ps.company_id
         AND mt.product_id = ps.product_id
         AND mt.warehouse_id = ps.warehouse_id
        WHERE ps.product_id IS NULL
           OR mt.product_id IS NULL
           OR ps.stock_qty IS DISTINCT FROM mt.qty
    ) THEN
        RAISE EXCEPTION
            'G3_PHASE4_STATE_CHANGED: stock balance and movement mismatch';
    END IF;
END
$migration_guard$;

ALTER TYPE public.stock_movement_type ADD VALUE IF NOT EXISTS 'SALES_RETURN';
ALTER TYPE public.stock_movement_type ADD VALUE IF NOT EXISTS 'PURCHASE_RETURN';
ALTER TYPE public.stock_movement_type ADD VALUE IF NOT EXISTS 'OPNAME_GAIN';
ALTER TYPE public.stock_movement_type ADD VALUE IF NOT EXISTS 'OPNAME_LOSS';
ALTER TYPE public.stock_movement_type ADD VALUE IF NOT EXISTS 'REVERSAL';

ALTER TABLE public.stock_movements
    ADD COLUMN base_uom_id UUID,
    ADD COLUMN base_uom_name_snapshot TEXT,
    ADD COLUMN balance_after_base_qty NUMERIC(24,6),
    ADD COLUMN actor_id UUID,
    ADD COLUMN posted_at TIMESTAMPTZ,
    ADD COLUMN movement_status TEXT NOT NULL DEFAULT 'POSTED',
    ADD COLUMN source_line_id UUID,
    ADD COLUMN notes TEXT,
    ADD CONSTRAINT fk_stock_movements_company_base_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT fk_stock_movements_actor
        FOREIGN KEY(actor_id) REFERENCES public.profiles(id)
        ON DELETE RESTRICT,
    ADD CONSTRAINT stock_movements_quantity_nonzero
        CHECK (qty_change <> 0),
    ADD CONSTRAINT stock_movements_status_check
        CHECK (movement_status IN ('POSTED','REVERSED')),
    ADD CONSTRAINT stock_movements_base_uom_snapshot_not_blank
        CHECK (
            base_uom_name_snapshot IS NULL
            OR btrim(base_uom_name_snapshot) <> ''
        ),
    ADD CONSTRAINT stock_movements_balance_after_nonnegative
        CHECK (
            balance_after_base_qty IS NULL
            OR balance_after_base_qty >= 0
        );

-- The approved preflight has one canonical Opening movement. Backfill its
-- immutable snapshots from the posted source document and line.
UPDATE public.stock_movements sm SET
    base_uom_id = l.base_uom_id,
    base_uom_name_snapshot = l.base_uom_name_snapshot,
    balance_after_base_qty = l.quantity_base,
    actor_id = d.posted_by,
    posted_at = d.posted_at,
    movement_status = 'POSTED',
    source_line_id = l.id,
    notes = COALESCE(l.notes,l.zero_cost_reason)
FROM public.opening_stock_documents d
JOIN public.opening_stock_lines l
  ON l.company_id = d.company_id
 AND l.document_id = d.id
WHERE sm.company_id = d.company_id
  AND sm.reference_table = 'opening_stock_documents'
  AND sm.reference_id = d.id
  AND sm.product_id = l.product_id
  AND sm.warehouse_id = d.warehouse_id
  AND sm.movement_type = 'OPENING_BALANCE'::public.stock_movement_type;

ALTER TABLE public.stock_movements
    ADD CONSTRAINT stock_movements_opening_snapshot_complete CHECK (
        movement_type IS DISTINCT FROM
            'OPENING_BALANCE'::public.stock_movement_type
        OR (
            base_uom_id IS NOT NULL
            AND base_uom_name_snapshot IS NOT NULL
            AND balance_after_base_qty IS NOT NULL
            AND actor_id IS NOT NULL
            AND posted_at IS NOT NULL
            AND movement_status = 'POSTED'
            AND source_line_id IS NOT NULL
        )
    );

CREATE UNIQUE INDEX uq_stock_movements_canonical_source_line
    ON public.stock_movements(
        company_id,reference_table,source_line_id,movement_type
    )
    WHERE source_line_id IS NOT NULL
      AND movement_status = 'POSTED';

CREATE INDEX idx_stock_movements_company_posted_card
    ON public.stock_movements(
        company_id,warehouse_id,product_id,posted_at DESC,id DESC
    );

-- Enrich future Opening Stock rows without changing the already-applied
-- post_opening_stock signature. Other source workflows remain untouched.
CREATE FUNCTION private.trg_g3_canonical_opening_movement()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_line public.opening_stock_lines%ROWTYPE;
    v_balance_before NUMERIC(24,6);
BEGIN
    IF NEW.movement_type IS DISTINCT FROM
       'OPENING_BALANCE'::public.stock_movement_type THEN
        RETURN NEW;
    END IF;
    IF NEW.reference_table <> 'opening_stock_documents' THEN
        RAISE EXCEPTION 'OPENING_MOVEMENT_SOURCE_INVALID';
    END IF;

    SELECT l.* INTO v_line
    FROM public.opening_stock_lines l
    JOIN public.opening_stock_documents d
      ON d.company_id = l.company_id
     AND d.id = l.document_id
    WHERE l.company_id = NEW.company_id
      AND l.document_id = NEW.reference_id
      AND l.product_id = NEW.product_id
      AND d.warehouse_id = NEW.warehouse_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OPENING_MOVEMENT_LINE_NOT_FOUND';
    END IF;

    SELECT COALESCE(ps.stock_qty,0) INTO v_balance_before
    FROM public.product_stocks ps
    WHERE ps.company_id = NEW.company_id
      AND ps.product_id = NEW.product_id
      AND ps.warehouse_id = NEW.warehouse_id;
    v_balance_before := COALESCE(v_balance_before,0);

    NEW.base_uom_id := v_line.base_uom_id;
    NEW.base_uom_name_snapshot := v_line.base_uom_name_snapshot;
    NEW.balance_after_base_qty := v_balance_before + NEW.qty_change;
    NEW.actor_id := COALESCE(NEW.actor_id,auth.uid());
    NEW.posted_at := COALESCE(NEW.posted_at,clock_timestamp());
    NEW.movement_status := 'POSTED';
    NEW.source_line_id := v_line.id;
    NEW.notes := COALESCE(NEW.notes,v_line.notes,v_line.zero_cost_reason);
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g3_stock_movement_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'STOCK_MOVEMENT_IMMUTABLE';
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g3_canonical_opening_movement()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_g3_stock_movement_immutable()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g3_canonical_opening_movement(),
    private.trg_g3_stock_movement_immutable()
TO service_role;

CREATE TRIGGER g3_canonical_opening_movement
BEFORE INSERT ON public.stock_movements
FOR EACH ROW EXECUTE FUNCTION private.trg_g3_canonical_opening_movement();

CREATE TRIGGER g3_stock_movement_immutable
BEFORE UPDATE OR DELETE ON public.stock_movements
FOR EACH ROW EXECUTE FUNCTION private.trg_g3_stock_movement_immutable();

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260728150000',
    'g3_phase4_canonical_stock_movement',
    'Canonical movement snapshots, Opening backfill/enrichment, immutable ledger, source-line idempotency, and future enum vocabulary without enabling deferred source workflows'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
