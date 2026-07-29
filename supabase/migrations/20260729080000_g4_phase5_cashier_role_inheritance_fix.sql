-- G4 phase 5 forward fix: align Cashier Session authorization with the
-- approved Company Admin / Super Admin role inheritance contract.
--
-- No table, data, Session, stock, or financial history is changed.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM private.kgs_schema_migrations
        WHERE version = '20260729070000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 atomic Sale runtime is missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM private.kgs_schema_migrations
        WHERE version = '20260729080000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729080000';
    END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION public.open_cashier_session(
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
    v_can_open BOOLEAN;
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

    SELECT
        public.private_is_super_admin(v_actor)
        OR EXISTS (
            SELECT 1
            FROM public.company_memberships cm
            WHERE cm.company_id = v_company
              AND cm.user_id = v_actor
              AND cm.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
              AND cm.status = 'ACTIVE'
        )
        OR EXISTS (
            SELECT 1
            FROM public.store_memberships sm
            WHERE sm.company_id = v_company
              AND sm.store_id = v_store
              AND sm.user_id = v_actor
              AND sm.role_code = 'CASHIER'
              AND sm.status = 'ACTIVE'
        )
    INTO v_can_open;

    IF NOT COALESCE(v_can_open,FALSE) THEN
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

REVOKE ALL ON FUNCTION public.open_cashier_session(UUID,UUID,NUMERIC)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_cashier_session(UUID,UUID,NUMERIC)
TO authenticated, service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729080000',
    'g4_phase5_cashier_role_inheritance_fix',
    'Forward-only authorization fix: exact Cashier Store assignment remains required for Cashier users while active Company Owner/Admin and Super Admin inherit Cashier Session opening authority'
);

COMMIT;
