-- KGS POS G1 phase 3: tenant consistency for session, sales, payment, purchase.
-- Requirement: TEN-001
-- Dependency: 20260720120000_g1_phase2_core_tenant_consistency.sql
--
-- Legacy single-ID foreign keys remain for compatibility. This migration does
-- not change transaction status, totals, stock, journal, RLS, or UI behavior.
-- Resolve any preflight mismatch explicitly; never rewrite company_id silently.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260720120000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 2 not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260720150000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260720150000';
    END IF;
END
$migration_guard$;

-- Abort before DDL if persistent data violates the intended topology.
DO $tenant_preflight$
DECLARE
    v_mismatch BIGINT;
BEGIN
    SELECT count(*) INTO v_mismatch
    FROM (
        SELECT c.id FROM public.cashier_sessions c JOIN public.stores p ON p.id = c.store_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.cashier_sessions c JOIN public.pos_terminals p ON p.id = c.pos_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.cashier_sessions c JOIN public.pos_terminals p ON p.id = c.pos_id
        WHERE c.store_id IS NOT NULL AND c.store_id IS DISTINCT FROM p.store_id
        UNION ALL
        SELECT c.id FROM public.sales_headers c JOIN public.cashier_sessions p ON p.id = c.session_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_headers c JOIN public.stores p ON p.id = c.store_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_headers c JOIN public.pos_terminals p ON p.id = c.pos_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_headers c JOIN public.customers p ON p.id = c.customer_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_headers c JOIN public.cashier_sessions p ON p.id = c.session_id
        WHERE c.store_id IS NOT NULL AND c.pos_id IS NOT NULL
          AND (c.store_id IS DISTINCT FROM p.store_id OR c.pos_id IS DISTINCT FROM p.pos_id)
        UNION ALL
        SELECT c.id FROM public.sales_details c JOIN public.sales_headers p ON p.id = c.sales_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_details c JOIN public.products p ON p.id = c.product_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_details c JOIN public.warehouses p ON p.id = c.warehouse_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_payments c JOIN public.sales_headers p ON p.id = c.sales_id
        WHERE c.company_id IS DISTINCT FROM p.company_id OR c.session_id IS DISTINCT FROM p.session_id
        UNION ALL
        SELECT c.id FROM public.sales_payments c JOIN public.cashier_sessions p ON p.id = c.session_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.sales_payments c JOIN public.sales_payments p ON p.id = c.reversal_ref_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.purchases_headers c JOIN public.stores p ON p.id = c.store_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.purchases_headers c JOIN public.warehouses p ON p.id = c.warehouse_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.purchases_details c JOIN public.purchases_headers p ON p.id = c.purchase_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
        UNION ALL
        SELECT c.id FROM public.purchases_details c JOIN public.products p ON p.id = c.product_id
        WHERE c.company_id IS DISTINCT FROM p.company_id
    ) mismatches;

    IF v_mismatch > 0 THEN
        RAISE EXCEPTION 'G1_PHASE3_TENANT_MISMATCH: % relation mismatch(es)', v_mismatch;
    END IF;
END
$tenant_preflight$;

-- Composite parent identities used by tenant-safe foreign keys.
ALTER TABLE public.pos_terminals
    ADD CONSTRAINT uq_pos_terminals_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.pos_terminals
    ADD CONSTRAINT uq_pos_terminals_company_store_id_id UNIQUE (company_id, store_id, id);
ALTER TABLE public.cashier_sessions
    ADD CONSTRAINT uq_cashier_sessions_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.cashier_sessions
    ADD CONSTRAINT uq_cashier_sessions_company_store_pos_id UNIQUE (company_id, store_id, pos_id, id);
ALTER TABLE public.customers
    ADD CONSTRAINT uq_customers_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.sales_headers
    ADD CONSTRAINT uq_sales_headers_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.sales_headers
    ADD CONSTRAINT uq_sales_headers_company_session_id UNIQUE (company_id, session_id, id);
ALTER TABLE public.sales_payments
    ADD CONSTRAINT uq_sales_payments_company_id_id UNIQUE (company_id, id);
ALTER TABLE public.purchases_headers
    ADD CONSTRAINT uq_purchases_headers_company_id_id UNIQUE (company_id, id);

-- Supporting child indexes. Existing company/sales indexes are retained.
CREATE INDEX idx_cashier_sessions_company_pos_fk ON public.cashier_sessions (company_id, pos_id);
CREATE INDEX idx_cashier_sessions_company_store_pos_fk ON public.cashier_sessions (company_id, store_id, pos_id);
CREATE INDEX idx_sales_headers_company_pos_fk ON public.sales_headers (company_id, pos_id);
CREATE INDEX idx_sales_headers_company_customer_fk ON public.sales_headers (company_id, customer_id);
CREATE INDEX idx_sales_headers_company_store_pos_session_fk ON public.sales_headers (company_id, store_id, pos_id, session_id);
CREATE INDEX idx_sales_details_company_product_fk ON public.sales_details (company_id, product_id);
CREATE INDEX idx_sales_details_company_warehouse_fk ON public.sales_details (company_id, warehouse_id);
CREATE INDEX idx_sales_payments_company_session_sales_fk ON public.sales_payments (company_id, session_id, sales_id);
CREATE INDEX idx_sales_payments_company_reversal_fk ON public.sales_payments (company_id, reversal_ref_id) WHERE reversal_ref_id IS NOT NULL;
CREATE INDEX idx_purchases_headers_company_store_fk ON public.purchases_headers (company_id, store_id);
CREATE INDEX idx_purchases_headers_company_warehouse_fk ON public.purchases_headers (company_id, warehouse_id);
CREATE INDEX idx_purchases_details_company_purchase_fk ON public.purchases_details (company_id, purchase_id);
CREATE INDEX idx_purchases_details_company_product_fk ON public.purchases_details (company_id, product_id);

-- New writes are protected immediately; existing rows are validated below.
ALTER TABLE public.cashier_sessions ADD CONSTRAINT fk_cashier_sessions_company_store
    FOREIGN KEY (company_id, store_id) REFERENCES public.stores (company_id, id) NOT VALID;
ALTER TABLE public.cashier_sessions ADD CONSTRAINT fk_cashier_sessions_company_pos
    FOREIGN KEY (company_id, pos_id) REFERENCES public.pos_terminals (company_id, id) NOT VALID;
ALTER TABLE public.cashier_sessions ADD CONSTRAINT fk_cashier_sessions_company_store_pos
    FOREIGN KEY (company_id, store_id, pos_id) REFERENCES public.pos_terminals (company_id, store_id, id) NOT VALID;

ALTER TABLE public.sales_headers ADD CONSTRAINT fk_sales_headers_company_session
    FOREIGN KEY (company_id, session_id) REFERENCES public.cashier_sessions (company_id, id) NOT VALID;
ALTER TABLE public.sales_headers ADD CONSTRAINT fk_sales_headers_company_store
    FOREIGN KEY (company_id, store_id) REFERENCES public.stores (company_id, id) NOT VALID;
ALTER TABLE public.sales_headers ADD CONSTRAINT fk_sales_headers_company_pos
    FOREIGN KEY (company_id, pos_id) REFERENCES public.pos_terminals (company_id, id) NOT VALID;
ALTER TABLE public.sales_headers ADD CONSTRAINT fk_sales_headers_company_customer
    FOREIGN KEY (company_id, customer_id) REFERENCES public.customers (company_id, id) NOT VALID;
ALTER TABLE public.sales_headers ADD CONSTRAINT fk_sales_headers_company_store_pos_session
    FOREIGN KEY (company_id, store_id, pos_id, session_id)
    REFERENCES public.cashier_sessions (company_id, store_id, pos_id, id) NOT VALID;

ALTER TABLE public.sales_details ADD CONSTRAINT fk_sales_details_company_sales
    FOREIGN KEY (company_id, sales_id) REFERENCES public.sales_headers (company_id, id) ON DELETE CASCADE NOT VALID;
ALTER TABLE public.sales_details ADD CONSTRAINT fk_sales_details_company_product
    FOREIGN KEY (company_id, product_id) REFERENCES public.products (company_id, id) NOT VALID;
ALTER TABLE public.sales_details ADD CONSTRAINT fk_sales_details_company_warehouse
    FOREIGN KEY (company_id, warehouse_id) REFERENCES public.warehouses (company_id, id) NOT VALID;

ALTER TABLE public.sales_payments ADD CONSTRAINT fk_sales_payments_company_sales
    FOREIGN KEY (company_id, sales_id) REFERENCES public.sales_headers (company_id, id) ON DELETE CASCADE NOT VALID;
ALTER TABLE public.sales_payments ADD CONSTRAINT fk_sales_payments_company_session
    FOREIGN KEY (company_id, session_id) REFERENCES public.cashier_sessions (company_id, id) NOT VALID;
ALTER TABLE public.sales_payments ADD CONSTRAINT fk_sales_payments_company_session_sales
    FOREIGN KEY (company_id, session_id, sales_id)
    REFERENCES public.sales_headers (company_id, session_id, id) NOT VALID;
ALTER TABLE public.sales_payments ADD CONSTRAINT fk_sales_payments_company_reversal
    FOREIGN KEY (company_id, reversal_ref_id) REFERENCES public.sales_payments (company_id, id) NOT VALID;

ALTER TABLE public.purchases_headers ADD CONSTRAINT fk_purchases_headers_company_store
    FOREIGN KEY (company_id, store_id) REFERENCES public.stores (company_id, id) NOT VALID;
ALTER TABLE public.purchases_headers ADD CONSTRAINT fk_purchases_headers_company_warehouse
    FOREIGN KEY (company_id, warehouse_id) REFERENCES public.warehouses (company_id, id) NOT VALID;
ALTER TABLE public.purchases_details ADD CONSTRAINT fk_purchases_details_company_purchase
    FOREIGN KEY (company_id, purchase_id) REFERENCES public.purchases_headers (company_id, id) ON DELETE CASCADE NOT VALID;
ALTER TABLE public.purchases_details ADD CONSTRAINT fk_purchases_details_company_product
    FOREIGN KEY (company_id, product_id) REFERENCES public.products (company_id, id) NOT VALID;

DO $validate$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('cashier_sessions','fk_cashier_sessions_company_store'),
            ('cashier_sessions','fk_cashier_sessions_company_pos'),
            ('cashier_sessions','fk_cashier_sessions_company_store_pos'),
            ('sales_headers','fk_sales_headers_company_session'),
            ('sales_headers','fk_sales_headers_company_store'),
            ('sales_headers','fk_sales_headers_company_pos'),
            ('sales_headers','fk_sales_headers_company_customer'),
            ('sales_headers','fk_sales_headers_company_store_pos_session'),
            ('sales_details','fk_sales_details_company_sales'),
            ('sales_details','fk_sales_details_company_product'),
            ('sales_details','fk_sales_details_company_warehouse'),
            ('sales_payments','fk_sales_payments_company_sales'),
            ('sales_payments','fk_sales_payments_company_session'),
            ('sales_payments','fk_sales_payments_company_session_sales'),
            ('sales_payments','fk_sales_payments_company_reversal'),
            ('purchases_headers','fk_purchases_headers_company_store'),
            ('purchases_headers','fk_purchases_headers_company_warehouse'),
            ('purchases_details','fk_purchases_details_company_purchase'),
            ('purchases_details','fk_purchases_details_company_product')
        ) v(table_name, constraint_name)
    LOOP
        EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT %I', r.table_name, r.constraint_name);
    END LOOP;
END
$validate$;

INSERT INTO private.kgs_schema_migrations (version, migration_name, notes)
VALUES (
    '20260720150000',
    'g1_phase3_transaction_tenant_consistency',
    'TEN-001 composite tenant topology for cashier session, sales, payment, and purchase'
);

COMMIT;
