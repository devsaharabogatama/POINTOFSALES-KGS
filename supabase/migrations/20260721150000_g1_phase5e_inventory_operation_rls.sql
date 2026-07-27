-- KGS POS G1 phase 5E: inventory-operation tenant topology and RLS.
-- Requirement: TEN-001, TEN-002
-- Dependency: 20260721120000_g1_phase5d_finance_rls.sql
--
-- Existing inventory-operation tables are legacy read models. Browser writes
-- are disabled until canonical atomic Opname/Adjustment/Transfer workflows
-- replace their incomplete contracts in later gates.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260721120000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 5D not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260721150000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260721150000';
    END IF;
END
$migration_guard$;

DO $inventory_preflight$
DECLARE
    v_violations BIGINT;
BEGIN
    SELECT count(*) INTO v_violations
    FROM (
        SELECT a.id
        FROM public.sales_fifo_allocations a
        JOIN public.sales_details d ON d.id = a.sales_detail_id
        WHERE a.company_id IS DISTINCT FROM d.company_id

        UNION ALL
        SELECT a.id
        FROM public.sales_fifo_allocations a
        JOIN public.product_batches b ON b.id = a.product_batch_id
        WHERE a.company_id IS DISTINCT FROM b.company_id

        UNION ALL
        SELECT o.id
        FROM public.stock_opnames o
        JOIN public.warehouses w ON w.id = o.warehouse_id
        WHERE o.company_id IS DISTINCT FROM w.company_id

        UNION ALL
        SELECT d.id
        FROM public.stock_opname_details d
        JOIN public.stock_opnames o ON o.id = d.opname_id
        WHERE d.company_id IS DISTINCT FROM o.company_id

        UNION ALL
        SELECT d.id
        FROM public.stock_opname_details d
        JOIN public.products p ON p.id = d.product_id
        WHERE d.company_id IS DISTINCT FROM p.company_id

        UNION ALL
        SELECT a.id
        FROM public.stock_adjustments a
        JOIN public.products p ON p.id = a.product_id
        WHERE a.company_id IS DISTINCT FROM p.company_id

        UNION ALL
        SELECT a.id
        FROM public.stock_adjustments a
        JOIN public.warehouses w ON w.id = a.warehouse_id
        WHERE a.company_id IS DISTINCT FROM w.company_id

        UNION ALL
        SELECT a.id
        FROM public.stock_adjustments a
        JOIN public.stock_opname_details d ON d.id = a.opname_detail_id
        WHERE a.company_id IS DISTINCT FROM d.company_id

        UNION ALL
        SELECT m.id
        FROM public.stock_movements m
        JOIN public.products p ON p.id = m.product_id
        WHERE m.company_id IS DISTINCT FROM p.company_id

        UNION ALL
        SELECT m.id
        FROM public.stock_movements m
        JOIN public.warehouses w ON w.id = m.warehouse_id
        WHERE m.company_id IS DISTINCT FROM w.company_id
    ) mismatches;

    IF v_violations > 0 THEN
        RAISE EXCEPTION
            'G1_PHASE5E_TENANT_PRECONDITION_FAILED: % mismatch(es)',
            v_violations;
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.sales_fifo_allocations
        WHERE qty_allocated <= 0 OR cogs_unit < 0
    ) THEN
        RAISE EXCEPTION 'G1_PHASE5E_FIFO_PRECONDITION_FAILED';
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.stock_opname_details
        WHERE system_qty < 0
           OR physical_qty < 0
           OR difference <> physical_qty - system_qty
    ) THEN
        RAISE EXCEPTION 'G1_PHASE5E_OPNAME_PRECONDITION_FAILED';
    END IF;
END
$inventory_preflight$;

-- Composite parent identities for tenant-safe foreign keys.
ALTER TABLE public.sales_details
    ADD CONSTRAINT uq_sales_details_company_id_id UNIQUE(company_id,id);
ALTER TABLE public.product_batches
    ADD CONSTRAINT uq_product_batches_company_id_id UNIQUE(company_id,id);
ALTER TABLE public.stock_opnames
    ADD CONSTRAINT uq_stock_opnames_company_id_id UNIQUE(company_id,id);
ALTER TABLE public.stock_opname_details
    ADD CONSTRAINT uq_stock_opname_details_company_id_id UNIQUE(company_id,id);

ALTER TABLE public.sales_fifo_allocations
    ADD CONSTRAINT fk_fifo_allocations_company_sales_detail
    FOREIGN KEY(company_id,sales_detail_id)
    REFERENCES public.sales_details(company_id,id)
    ON DELETE CASCADE NOT VALID,
    ADD CONSTRAINT fk_fifo_allocations_company_batch
    FOREIGN KEY(company_id,product_batch_id)
    REFERENCES public.product_batches(company_id,id)
    ON DELETE CASCADE NOT VALID;

ALTER TABLE public.stock_opnames
    ADD CONSTRAINT fk_stock_opnames_company_warehouse
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id)
    NOT VALID;

ALTER TABLE public.stock_opname_details
    ADD CONSTRAINT fk_opname_details_company_opname
    FOREIGN KEY(company_id,opname_id)
    REFERENCES public.stock_opnames(company_id,id)
    ON DELETE CASCADE NOT VALID,
    ADD CONSTRAINT fk_opname_details_company_product
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id)
    NOT VALID;

ALTER TABLE public.stock_adjustments
    ADD CONSTRAINT fk_stock_adjustments_company_product
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id)
    NOT VALID,
    ADD CONSTRAINT fk_stock_adjustments_company_warehouse
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id)
    NOT VALID,
    ADD CONSTRAINT fk_stock_adjustments_company_opname_detail
    FOREIGN KEY(company_id,opname_detail_id)
    REFERENCES public.stock_opname_details(company_id,id)
    ON DELETE SET NULL (opname_detail_id)
    NOT VALID;

ALTER TABLE public.stock_movements
    ADD CONSTRAINT fk_stock_movements_company_product
    FOREIGN KEY(company_id,product_id)
    REFERENCES public.products(company_id,id)
    NOT VALID,
    ADD CONSTRAINT fk_stock_movements_company_warehouse
    FOREIGN KEY(company_id,warehouse_id)
    REFERENCES public.warehouses(company_id,id)
    NOT VALID;

DO $validate_constraints$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('sales_fifo_allocations','fk_fifo_allocations_company_sales_detail'),
            ('sales_fifo_allocations','fk_fifo_allocations_company_batch'),
            ('stock_opnames','fk_stock_opnames_company_warehouse'),
            ('stock_opname_details','fk_opname_details_company_opname'),
            ('stock_opname_details','fk_opname_details_company_product'),
            ('stock_adjustments','fk_stock_adjustments_company_product'),
            ('stock_adjustments','fk_stock_adjustments_company_warehouse'),
            ('stock_adjustments','fk_stock_adjustments_company_opname_detail'),
            ('stock_movements','fk_stock_movements_company_product'),
            ('stock_movements','fk_stock_movements_company_warehouse')
        ) v(table_name,constraint_name)
    LOOP
        EXECUTE format(
            'ALTER TABLE public.%I VALIDATE CONSTRAINT %I',
            r.table_name,r.constraint_name
        );
    END LOOP;
END
$validate_constraints$;

CREATE INDEX idx_fifo_allocations_company_sales_detail_fk
    ON public.sales_fifo_allocations(company_id,sales_detail_id);
CREATE INDEX idx_fifo_allocations_company_batch_fk
    ON public.sales_fifo_allocations(company_id,product_batch_id);
CREATE INDEX idx_stock_opnames_company_warehouse_fk
    ON public.stock_opnames(company_id,warehouse_id);
CREATE INDEX idx_opname_details_company_opname_fk
    ON public.stock_opname_details(company_id,opname_id);
CREATE INDEX idx_opname_details_company_product_fk
    ON public.stock_opname_details(company_id,product_id);
CREATE INDEX idx_stock_adjustments_company_product_fk
    ON public.stock_adjustments(company_id,product_id);
CREATE INDEX idx_stock_adjustments_company_warehouse_fk
    ON public.stock_adjustments(company_id,warehouse_id);
CREATE INDEX idx_stock_adjustments_company_opname_detail_fk
    ON public.stock_adjustments(company_id,opname_detail_id)
    WHERE opname_detail_id IS NOT NULL;
CREATE INDEX idx_stock_movements_company_product_fk
    ON public.stock_movements(company_id,product_id);
CREATE INDEX idx_stock_movements_company_warehouse_fk
    ON public.stock_movements(company_id,warehouse_id);

CREATE OR REPLACE FUNCTION public.private_inventory_reviewer_visible(
    p_company_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND public.private_user_has_any_company_or_store_role(
           p_company_id,
           ARRAY[
               'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER',
               'WAREHOUSE_ADMIN','FINANCE','ACCOUNTING'
           ]::TEXT[]
       );
$$;

DO $drop_inventory_policies$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT tablename,policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = ANY(ARRAY[
              'sales_fifo_allocations','stock_opnames',
              'stock_opname_details','stock_adjustments','stock_movements'
          ])
    LOOP
        EXECUTE format('DROP POLICY %I ON public.%I',r.policyname,r.tablename);
    END LOOP;
END
$drop_inventory_policies$;

ALTER TABLE public.sales_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_opnames ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_opname_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

CREATE POLICY "FIFO allocations readable by inventory reviewers"
ON public.sales_fifo_allocations FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

CREATE POLICY "Stock opnames readable by owner or inventory reviewers"
ON public.stock_opnames FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        created_by = auth.uid()
        OR public.private_inventory_reviewer_visible(company_id)
    )
);

CREATE POLICY "Stock opname details readable by inventory reviewers"
ON public.stock_opname_details FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

CREATE POLICY "Stock adjustments readable by inventory reviewers"
ON public.stock_adjustments FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

CREATE POLICY "Stock movements readable by inventory reviewers"
ON public.stock_movements FOR SELECT TO authenticated
USING (public.private_inventory_reviewer_visible(company_id));

REVOKE ALL ON public.sales_fifo_allocations, public.stock_opnames,
    public.stock_opname_details, public.stock_adjustments,
    public.stock_movements
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.sales_fifo_allocations, public.stock_opnames,
    public.stock_opname_details, public.stock_adjustments,
    public.stock_movements
TO authenticated;

GRANT ALL ON public.sales_fifo_allocations, public.stock_opnames,
    public.stock_opname_details, public.stock_adjustments,
    public.stock_movements
TO service_role;

REVOKE ALL ON FUNCTION public.private_inventory_reviewer_visible(UUID)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.private_inventory_reviewer_visible(UUID)
TO authenticated, service_role;

-- Legacy transfer is not safe for browser execution (no active Company actor
-- guard and incomplete concurrency contract). It remains server-only until G3.
REVOKE ALL ON FUNCTION public.transfer_product_stock(UUID,UUID,UUID,NUMERIC)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.transfer_product_stock(UUID,UUID,UUID,NUMERIC)
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260721150000',
    'g1_phase5e_inventory_operation_rls',
    'TEN-001/TEN-002 tenant-safe FIFO/opname/adjustment/movement reads; browser mutation disabled pending canonical workflows'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
