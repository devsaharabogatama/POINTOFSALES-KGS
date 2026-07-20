-- KGS POS G1 phase 2: database-enforced tenant consistency for core master/stock.
--
-- Requirement: TEN-001
-- Dependency: 20260720090000_g1_phase1_security_feature_foundation.sql
--
-- This migration adds composite foreign keys while retaining legacy single-ID
-- foreign keys for compatibility. Sales/Purchase/Finance transaction topology,
-- active Company context, and the full role matrix remain later G1 phases.
--
-- Forward-fix posture:
-- - Do not drop these constraints after new writes depend on them.
-- - A failed preflight/validation rolls back the entire transaction.
-- - Resolve mismatched data explicitly; never rewrite company_id automatically.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 1 ledger missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM private.kgs_schema_migrations
        WHERE version = '20260720090000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 1 not recorded';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM private.kgs_schema_migrations
        WHERE version = '20260720120000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260720120000';
    END IF;
END
$migration_guard$;

-- Fail with the exact relation before taking the longer validation locks.
DO $tenant_preflight$
DECLARE
    r RECORD;
    v_mismatch_rows BIGINT;
BEGIN
    FOR r IN
        SELECT *
        FROM (VALUES
            ('pos_terminals', 'store_id', 'stores'),
            ('store_memberships', 'store_id', 'stores'),
            ('products', 'uom_id', 'uoms'),
            ('product_bundle_items', 'bundle_id', 'products'),
            ('product_bundle_items', 'item_id', 'products'),
            ('product_stocks', 'product_id', 'products'),
            ('product_stocks', 'warehouse_id', 'warehouses'),
            ('product_uom_conversions', 'product_id', 'products'),
            ('product_uom_conversions', 'from_uom_id', 'uoms'),
            ('product_uom_conversions', 'to_uom_id', 'uoms'),
            ('product_batches', 'product_id', 'products'),
            ('product_batches', 'warehouse_id', 'warehouses')
        ) relations(child_table, child_column, parent_table)
    LOOP
        IF to_regclass(format('public.%I', r.child_table)) IS NULL
           OR to_regclass(format('public.%I', r.parent_table)) IS NULL THEN
            RAISE EXCEPTION
                'G1_PHASE2_PRECONDITION_FAILED: missing %.% or parent %',
                r.child_table, r.child_column, r.parent_table;
        END IF;

        EXECUTE format(
            'SELECT count(*) '
            'FROM public.%I c '
            'JOIN public.%I p ON p.id = c.%I '
            'WHERE c.company_id IS DISTINCT FROM p.company_id',
            r.child_table,
            r.parent_table,
            r.child_column
        ) INTO v_mismatch_rows;

        IF v_mismatch_rows > 0 THEN
            RAISE EXCEPTION
                'G1_PHASE2_TENANT_MISMATCH: %.% has % mismatched row(s)',
                r.child_table,
                r.child_column,
                v_mismatch_rows;
        END IF;
    END LOOP;
END
$tenant_preflight$;

-- Referenced composite keys. UUID id remains the primary key; these unique
-- constraints exist specifically to make tenant ownership part of each FK.
ALTER TABLE public.stores
    ADD CONSTRAINT uq_stores_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.warehouses
    ADD CONSTRAINT uq_warehouses_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.products
    ADD CONSTRAINT uq_products_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.uoms
    ADD CONSTRAINT uq_uoms_company_id_id UNIQUE (company_id, id);

-- Supporting indexes prevent parent UPDATE/DELETE checks from scanning entire
-- child tables. Existing equivalent prefixes are reused where already present.
CREATE INDEX idx_pos_terminals_company_store_fk
    ON public.pos_terminals (company_id, store_id);
CREATE INDEX idx_products_company_uom_fk
    ON public.products (company_id, uom_id)
    WHERE uom_id IS NOT NULL;
CREATE INDEX idx_bundle_items_company_bundle_fk
    ON public.product_bundle_items (company_id, bundle_id);
CREATE INDEX idx_bundle_items_company_item_fk
    ON public.product_bundle_items (company_id, item_id);
CREATE INDEX idx_product_stocks_company_product_fk
    ON public.product_stocks (company_id, product_id);
CREATE INDEX idx_uom_conversions_company_product_fk
    ON public.product_uom_conversions (company_id, product_id);
CREATE INDEX idx_uom_conversions_company_from_fk
    ON public.product_uom_conversions (company_id, from_uom_id);
CREATE INDEX idx_uom_conversions_company_to_fk
    ON public.product_uom_conversions (company_id, to_uom_id);
CREATE INDEX idx_product_batches_company_product_fk
    ON public.product_batches (company_id, product_id);
CREATE INDEX idx_product_batches_company_warehouse_fk
    ON public.product_batches (company_id, warehouse_id);

-- Add as NOT VALID first: new writes are protected immediately, then existing
-- rows are validated explicitly below.
ALTER TABLE public.pos_terminals
    ADD CONSTRAINT fk_pos_terminals_company_store
    FOREIGN KEY (company_id, store_id)
    REFERENCES public.stores (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.store_memberships
    ADD CONSTRAINT fk_store_memberships_company_store
    FOREIGN KEY (company_id, store_id)
    REFERENCES public.stores (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.products
    ADD CONSTRAINT fk_products_company_uom
    FOREIGN KEY (company_id, uom_id)
    REFERENCES public.uoms (company_id, id)
    NOT VALID;

ALTER TABLE public.product_bundle_items
    ADD CONSTRAINT fk_bundle_items_company_bundle
    FOREIGN KEY (company_id, bundle_id)
    REFERENCES public.products (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.product_bundle_items
    ADD CONSTRAINT fk_bundle_items_company_item
    FOREIGN KEY (company_id, item_id)
    REFERENCES public.products (company_id, id)
    NOT VALID;

ALTER TABLE public.product_stocks
    ADD CONSTRAINT fk_product_stocks_company_product
    FOREIGN KEY (company_id, product_id)
    REFERENCES public.products (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.product_stocks
    ADD CONSTRAINT fk_product_stocks_company_warehouse
    FOREIGN KEY (company_id, warehouse_id)
    REFERENCES public.warehouses (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.product_uom_conversions
    ADD CONSTRAINT fk_uom_conversions_company_product
    FOREIGN KEY (company_id, product_id)
    REFERENCES public.products (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.product_uom_conversions
    ADD CONSTRAINT fk_uom_conversions_company_from
    FOREIGN KEY (company_id, from_uom_id)
    REFERENCES public.uoms (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.product_uom_conversions
    ADD CONSTRAINT fk_uom_conversions_company_to
    FOREIGN KEY (company_id, to_uom_id)
    REFERENCES public.uoms (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.product_batches
    ADD CONSTRAINT fk_product_batches_company_product
    FOREIGN KEY (company_id, product_id)
    REFERENCES public.products (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.product_batches
    ADD CONSTRAINT fk_product_batches_company_warehouse
    FOREIGN KEY (company_id, warehouse_id)
    REFERENCES public.warehouses (company_id, id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.pos_terminals
    VALIDATE CONSTRAINT fk_pos_terminals_company_store;
ALTER TABLE public.store_memberships
    VALIDATE CONSTRAINT fk_store_memberships_company_store;
ALTER TABLE public.products
    VALIDATE CONSTRAINT fk_products_company_uom;
ALTER TABLE public.product_bundle_items
    VALIDATE CONSTRAINT fk_bundle_items_company_bundle;
ALTER TABLE public.product_bundle_items
    VALIDATE CONSTRAINT fk_bundle_items_company_item;
ALTER TABLE public.product_stocks
    VALIDATE CONSTRAINT fk_product_stocks_company_product;
ALTER TABLE public.product_stocks
    VALIDATE CONSTRAINT fk_product_stocks_company_warehouse;
ALTER TABLE public.product_uom_conversions
    VALIDATE CONSTRAINT fk_uom_conversions_company_product;
ALTER TABLE public.product_uom_conversions
    VALIDATE CONSTRAINT fk_uom_conversions_company_from;
ALTER TABLE public.product_uom_conversions
    VALIDATE CONSTRAINT fk_uom_conversions_company_to;
ALTER TABLE public.product_batches
    VALIDATE CONSTRAINT fk_product_batches_company_product;
ALTER TABLE public.product_batches
    VALIDATE CONSTRAINT fk_product_batches_company_warehouse;

INSERT INTO private.kgs_schema_migrations (
    version,
    migration_name,
    notes
) VALUES (
    '20260720120000',
    'g1_phase2_core_tenant_consistency',
    'TEN-001 core master/inventory composite tenant foreign keys'
);

COMMIT;
