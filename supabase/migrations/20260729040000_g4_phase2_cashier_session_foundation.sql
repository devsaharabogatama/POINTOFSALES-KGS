-- KGS POS G4 phase 2: canonical Cashier Session foundation.
-- Requirement: POS-001
-- Dependency: G3 inventory core through 20260729010000.
--
-- This migration opens only the guarded Session lifecycle. It does not enable
-- the legacy checkout, Sale posting, offline queue, Expense, or deposit flow.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM private.kgs_schema_migrations
           WHERE version = '20260729010000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G3 inventory core is incomplete';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM private.kgs_schema_migrations
        WHERE version = '20260729040000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729040000';
    END IF;
END
$migration_guard$;

-- The approved readiness result reported no OPEN Session. An in-flight legacy
-- Session has no canonical warehouse or stock snapshot and must be closed or
-- reviewed explicitly before this lifecycle is installed.
DO $session_state_guard$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.cashier_sessions
        WHERE status = 'OPEN'::public.session_status
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE2_STATE_CHANGED: close or review legacy OPEN Cashier Sessions';
    END IF;
END
$session_state_guard$;

ALTER TABLE public.cashier_sessions
    ADD COLUMN sales_warehouse_id UUID,
    ADD COLUMN opening_cash_actual NUMERIC(20,4),
    ADD COLUMN closing_cash_actual NUMERIC(20,4),
    ADD COLUMN opening_stock_snapshot_at TIMESTAMPTZ,
    ADD COLUMN closing_stock_snapshot_at TIMESTAMPTZ,
    ADD COLUMN master_version BIGINT,
    ADD COLUMN updated_at TIMESTAMPTZ;

UPDATE public.cashier_sessions
SET
    opening_cash_actual = opening_balance,
    closing_cash_actual = CASE
        WHEN status = 'CLOSED'::public.session_status THEN actual_cash
        ELSE NULL
    END,
    master_version = 1,
    updated_at = COALESCE(closed_at,opened_at,clock_timestamp());

ALTER TABLE public.cashier_sessions
    ALTER COLUMN opening_cash_actual SET NOT NULL,
    ALTER COLUMN opening_cash_actual SET DEFAULT 0,
    ALTER COLUMN master_version SET NOT NULL,
    ALTER COLUMN master_version SET DEFAULT 1,
    ALTER COLUMN updated_at SET NOT NULL,
    ALTER COLUMN updated_at SET DEFAULT clock_timestamp(),
    ADD CONSTRAINT cashier_sessions_opening_cash_nonnegative
        CHECK (opening_cash_actual >= 0),
    ADD CONSTRAINT cashier_sessions_closing_cash_nonnegative
        CHECK (closing_cash_actual IS NULL OR closing_cash_actual >= 0),
    ADD CONSTRAINT cashier_sessions_master_version_positive
        CHECK (master_version > 0),
    ADD CONSTRAINT cashier_sessions_open_warehouse_required
        CHECK (
            status IS DISTINCT FROM 'OPEN'::public.session_status
            OR sales_warehouse_id IS NOT NULL
        ),
    ADD CONSTRAINT fk_cashier_sessions_company_sales_warehouse
        FOREIGN KEY(company_id,sales_warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT;

CREATE INDEX idx_cashier_sessions_company_sales_warehouse
    ON public.cashier_sessions(company_id,sales_warehouse_id)
    WHERE sales_warehouse_id IS NOT NULL;

CREATE UNIQUE INDEX uq_cashier_sessions_one_open_per_cashier
    ON public.cashier_sessions(cashier_id)
    WHERE status = 'OPEN'::public.session_status;

CREATE SEQUENCE private.cashier_session_code_seq AS BIGINT START WITH 1;
REVOKE ALL ON SEQUENCE private.cashier_session_code_seq
FROM PUBLIC, anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE private.cashier_session_code_seq
TO service_role;

CREATE TABLE public.cashier_session_stock_snapshots (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    cashier_session_id UUID NOT NULL,
    snapshot_stage TEXT NOT NULL,
    product_id UUID NOT NULL,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    base_uom_id UUID NOT NULL,
    base_uom_name_snapshot TEXT NOT NULL,
    stock_qty_base NUMERIC(24,6) NOT NULL,
    captured_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT cashier_session_stock_snapshot_unique
        UNIQUE(cashier_session_id,snapshot_stage,product_id),
    CONSTRAINT cashier_session_stock_snapshot_stage_check
        CHECK (snapshot_stage IN ('OPENING','CLOSING')),
    CONSTRAINT cashier_session_stock_snapshot_qty_nonnegative
        CHECK (stock_qty_base >= 0),
    CONSTRAINT fk_cashier_session_stock_snapshot_session
        FOREIGN KEY(company_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cashier_session_stock_snapshot_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_cashier_session_stock_snapshot_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_cashier_session_stock_snapshot_session_stage
    ON public.cashier_session_stock_snapshots(
        company_id,cashier_session_id,snapshot_stage,product_name_snapshot
    );

CREATE TABLE public.cashier_session_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    cashier_session_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT cashier_session_audit_action_check
        CHECK (action IN ('OPEN','CLOSE')),
    CONSTRAINT fk_cashier_session_audit_session
        FOREIGN KEY(company_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_cashier_session_audit_session_created
    ON public.cashier_session_audit(
        company_id,cashier_session_id,created_at DESC
    );

CREATE FUNCTION public.private_cashier_session_visible(
    p_cashier_session_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.cashier_sessions cs
        WHERE cs.id = p_cashier_session_id
          AND public.private_request_company_matches(cs.company_id)
          AND (
              cs.cashier_id = auth.uid()
              OR public.private_user_has_any_company_role(
                  cs.company_id,
                  ARRAY[
                      'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
                  ]::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  cs.store_id,
                  ARRAY['STORE_MANAGER']::TEXT[]
              )
          )
    );
$$;

CREATE FUNCTION private.calculate_cashier_session_expected_cash(
    p_company_id UUID,
    p_cashier_session_id UUID
)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        cs.opening_cash_actual
        + COALESCE(sum(
            CASE WHEN sp.is_reversal THEN -sp.amount ELSE sp.amount END
        ) FILTER (
            WHERE (
                pm.method_type = 'CASH'
                OR (
                    sp.payment_method_id IS NULL
                    AND sp.payment_method::TEXT = 'Cash'
                )
            )
              AND sh.invoice_status::TEXT = 'GENERATED'
        ),0)
    FROM public.cashier_sessions cs
    LEFT JOIN public.sales_payments sp
      ON sp.company_id = cs.company_id
     AND sp.session_id = cs.id
    LEFT JOIN public.sales_headers sh
      ON sh.company_id = sp.company_id
     AND sh.id = sp.sales_id
    LEFT JOIN public.payment_methods pm
      ON pm.company_id = sp.company_id
     AND pm.id = sp.payment_method_id
    WHERE cs.company_id = p_company_id
      AND cs.id = p_cashier_session_id
    GROUP BY cs.opening_cash_actual;
$$;

CREATE FUNCTION public.open_cashier_session(
    p_pos_terminal_id UUID,
    p_sales_warehouse_id UUID,
    p_opening_cash_actual NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_store UUID;
    v_session_id UUID;
    v_existing public.cashier_sessions%ROWTYPE;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_code TEXT;
    v_snapshot_count BIGINT;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED';
    END IF;
    IF p_opening_cash_actual IS NULL OR p_opening_cash_actual < 0 THEN
        RAISE EXCEPTION 'INVALID_OPENING_CASH';
    END IF;

    SELECT pt.store_id INTO v_store
    FROM public.pos_terminals pt
    JOIN public.companies c
      ON c.id = pt.company_id
     AND c.status = 'ACTIVE'
    WHERE pt.company_id = v_company
      AND pt.id = p_pos_terminal_id
      AND pt.status = 'ACTIVE';
    IF v_store IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_POS_TERMINAL_NOT_FOUND';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.store_memberships sm
        WHERE sm.company_id = v_company
          AND sm.store_id = v_store
          AND sm.user_id = v_actor
          AND sm.role_code = 'CASHIER'
          AND sm.status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'ACTIVE_CASHIER_ASSIGNMENT_REQUIRED';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.warehouses w
        WHERE w.company_id = v_company
          AND w.id = p_sales_warehouse_id
          AND w.is_active
          AND w.is_sale_source
          AND (w.store_id = v_store OR w.store_id IS NULL)
    ) THEN
        RAISE EXCEPTION 'ACTIVE_SALES_WAREHOUSE_NOT_FOUND';
    END IF;

    SELECT * INTO v_existing
    FROM public.cashier_sessions cs
    WHERE cs.cashier_id = v_actor
      AND cs.status = 'OPEN'::public.session_status
    FOR UPDATE;

    IF FOUND THEN
        IF v_existing.company_id = v_company
           AND v_existing.pos_id = p_pos_terminal_id
           AND v_existing.sales_warehouse_id = p_sales_warehouse_id
           AND v_existing.opening_cash_actual = p_opening_cash_actual THEN
            RETURN jsonb_build_object(
                'cashierSessionId',v_existing.id,
                'sessionCode',v_existing.session_code,
                'masterVersion',v_existing.master_version,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'CASHIER_SESSION_ALREADY_OPEN';
    END IF;

    v_session_id := gen_random_uuid();
    v_code := 'SES-' || to_char(v_now,'YYYYMMDD') || '-'
        || lpad(nextval('private.cashier_session_code_seq')::TEXT,10,'0');

    BEGIN
        INSERT INTO public.cashier_sessions(
            id,session_code,cashier_id,opened_at,opening_balance,
            expected_cash,actual_cash,difference,status,company_id,store_id,
            pos_id,sales_warehouse_id,opening_cash_actual,master_version,
            updated_at
        ) VALUES (
            v_session_id,v_code,v_actor,v_now,p_opening_cash_actual,
            p_opening_cash_actual,0,0,'OPEN'::public.session_status,
            v_company,v_store,p_pos_terminal_id,p_sales_warehouse_id,
            p_opening_cash_actual,1,v_now
        );
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'CASHIER_SESSION_ALREADY_OPEN';
    END;

    INSERT INTO public.cashier_session_stock_snapshots(
        company_id,cashier_session_id,snapshot_stage,product_id,
        product_sku_snapshot,product_name_snapshot,base_uom_id,
        base_uom_name_snapshot,stock_qty_base,captured_at
    )
    SELECT
        v_company,v_session_id,'OPENING',p.id,p.sku,p.name,p.uom_id,u.name,
        COALESCE(ps.stock_qty,0),v_now
    FROM public.products p
    JOIN public.uoms u
      ON u.company_id = p.company_id
     AND u.id = p.uom_id
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = p.company_id
     AND ps.product_id = p.id
     AND ps.warehouse_id = p_sales_warehouse_id
    WHERE p.company_id = v_company
      AND p.is_active
      AND NOT p.is_bundle;
    GET DIAGNOSTICS v_snapshot_count = ROW_COUNT;

    UPDATE public.cashier_sessions
    SET opening_stock_snapshot_at = v_now
    WHERE id = v_session_id;

    INSERT INTO public.cashier_session_audit(
        company_id,cashier_session_id,action,actor_id,after_state
    ) VALUES (
        v_company,v_session_id,'OPEN',v_actor,
        jsonb_build_object(
            'status','OPEN','sessionCode',v_code,'storeId',v_store,
            'posTerminalId',p_pos_terminal_id,
            'salesWarehouseId',p_sales_warehouse_id,
            'openingCashActual',p_opening_cash_actual,
            'openingSnapshotProducts',v_snapshot_count,
            'masterVersion',1
        )
    );

    RETURN jsonb_build_object(
        'cashierSessionId',v_session_id,'sessionCode',v_code,
        'masterVersion',1,'openingSnapshotProducts',v_snapshot_count,
        'idempotentReplay',FALSE
    );
END;
$$;

CREATE FUNCTION public.close_cashier_session(
    p_cashier_session_id UUID,
    p_master_version BIGINT,
    p_closing_cash_actual NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_session public.cashier_sessions%ROWTYPE;
    v_before JSONB;
    v_now TIMESTAMPTZ := clock_timestamp();
    v_expected NUMERIC;
    v_snapshot_count BIGINT;
    v_new_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;
    IF v_company IS NULL THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED';
    END IF;
    IF p_closing_cash_actual IS NULL OR p_closing_cash_actual < 0 THEN
        RAISE EXCEPTION 'INVALID_CLOSING_CASH';
    END IF;

    SELECT * INTO v_session
    FROM public.cashier_sessions cs
    WHERE cs.company_id = v_company
      AND cs.id = p_cashier_session_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CASHIER_SESSION_NOT_FOUND';
    END IF;
    IF v_session.cashier_id IS DISTINCT FROM v_actor THEN
        RAISE EXCEPTION 'CASHIER_SESSION_ACTOR_MISMATCH';
    END IF;

    IF v_session.status = 'CLOSED'::public.session_status THEN
        IF v_session.closing_cash_actual = p_closing_cash_actual THEN
            RETURN jsonb_build_object(
                'cashierSessionId',v_session.id,
                'masterVersion',v_session.master_version,
                'expectedCash',v_session.expected_cash,
                'closingCashActual',v_session.closing_cash_actual,
                'difference',v_session.difference,
                'idempotentReplay',TRUE
            );
        END IF;
        RAISE EXCEPTION 'CASHIER_SESSION_ALREADY_CLOSED';
    END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_session.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;

    v_before := jsonb_build_object(
        'status',v_session.status::TEXT,
        'masterVersion',v_session.master_version
    );
    v_expected := private.calculate_cashier_session_expected_cash(
        v_company,v_session.id
    );
    IF v_expected IS NULL THEN
        RAISE EXCEPTION 'CASHIER_SESSION_EXPECTED_CASH_UNAVAILABLE';
    END IF;

    INSERT INTO public.cashier_session_stock_snapshots(
        company_id,cashier_session_id,snapshot_stage,product_id,
        product_sku_snapshot,product_name_snapshot,base_uom_id,
        base_uom_name_snapshot,stock_qty_base,captured_at
    )
    SELECT
        v_company,v_session.id,'CLOSING',p.id,p.sku,p.name,p.uom_id,u.name,
        COALESCE(ps.stock_qty,0),v_now
    FROM public.products p
    JOIN public.uoms u
      ON u.company_id = p.company_id
     AND u.id = p.uom_id
    LEFT JOIN public.product_stocks ps
      ON ps.company_id = p.company_id
     AND ps.product_id = p.id
     AND ps.warehouse_id = v_session.sales_warehouse_id
    WHERE p.company_id = v_company
      AND p.is_active
      AND NOT p.is_bundle;
    GET DIAGNOSTICS v_snapshot_count = ROW_COUNT;

    v_new_version := v_session.master_version + 1;
    UPDATE public.cashier_sessions
    SET
        closed_at = v_now,
        closing_cash_actual = p_closing_cash_actual,
        closing_stock_snapshot_at = v_now,
        expected_cash = v_expected,
        actual_cash = p_closing_cash_actual,
        difference = p_closing_cash_actual - v_expected,
        status = 'CLOSED'::public.session_status,
        master_version = v_new_version,
        updated_at = v_now
    WHERE id = v_session.id;

    INSERT INTO public.cashier_session_audit(
        company_id,cashier_session_id,action,actor_id,
        before_state,after_state
    ) VALUES (
        v_company,v_session.id,'CLOSE',v_actor,v_before,
        jsonb_build_object(
            'status','CLOSED','expectedCash',v_expected,
            'closingCashActual',p_closing_cash_actual,
            'difference',p_closing_cash_actual - v_expected,
            'closingSnapshotProducts',v_snapshot_count,
            'masterVersion',v_new_version
        )
    );

    RETURN jsonb_build_object(
        'cashierSessionId',v_session.id,'masterVersion',v_new_version,
        'expectedCash',v_expected,
        'closingCashActual',p_closing_cash_actual,
        'difference',p_closing_cash_actual - v_expected,
        'closingSnapshotProducts',v_snapshot_count,
        'idempotentReplay',FALSE
    );
END;
$$;

ALTER TABLE public.cashier_session_stock_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cashier_session_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Cashier Session stock snapshots readable by Session scope"
ON public.cashier_session_stock_snapshots
FOR SELECT TO authenticated
USING (public.private_cashier_session_visible(cashier_session_id));

CREATE POLICY "Cashier Session audit readable by Session scope"
ON public.cashier_session_audit
FOR SELECT TO authenticated
USING (public.private_cashier_session_visible(cashier_session_id));

REVOKE ALL ON public.cashier_session_stock_snapshots,
    public.cashier_session_audit
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cashier_session_stock_snapshots,
    public.cashier_session_audit
TO authenticated;
GRANT ALL ON public.cashier_session_stock_snapshots,
    public.cashier_session_audit
TO service_role;

REVOKE ALL ON FUNCTION public.private_cashier_session_visible(UUID)
FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION
    private.calculate_cashier_session_expected_cash(UUID,UUID)
FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.open_cashier_session(UUID,UUID,NUMERIC)
FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.private_cashier_session_visible(UUID)
TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION
    private.calculate_cashier_session_expected_cash(UUID,UUID)
TO service_role;
GRANT EXECUTE ON FUNCTION public.open_cashier_session(UUID,UUID,NUMERIC)
TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.close_cashier_session(UUID,BIGINT,NUMERIC)
TO authenticated, service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729040000',
    'g4_phase2_cashier_session_foundation',
    'POS-001 guarded one-open Session lifecycle, manual cash count, immutable opening/closing stock snapshots, versioning, idempotent retry, and audit'
);

NOTIFY pgrst, 'reload schema';

COMMIT;
