-- KGS POS G4 phase 11: Offline Stock Allowance foundation.
-- Requirement: POS-004
-- Dependency: online Sale and Payment-Leg identity through 20260729150000.
--
-- This migration creates server-side policy, reservation, audit, and
-- submission-envelope foundations. It does NOT open PWA offline checkout,
-- submission ingest, sync posting, offline Payment verification, or Finance
-- posting.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260729150000'
       ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G4 Payment-Leg identity missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260729180000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260729180000';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.company_features
        WHERE feature_code = 'offline_pos_enabled'
          AND is_enabled
    ) THEN
        RAISE EXCEPTION
            'G4_PHASE11_STATE_CHANGED: disable Offline POS entitlement before foundation rollout';
    END IF;
    IF to_regclass('public.pos_offline_allowance_policies') IS NOT NULL
       OR to_regclass('public.pos_offline_stock_allowances') IS NOT NULL
       OR to_regclass('public.pos_offline_stock_allowance_audit') IS NOT NULL
       OR to_regclass('public.pos_offline_sale_submissions') IS NOT NULL
       OR to_regclass('public.pos_offline_sale_submission_events') IS NOT NULL
    THEN
        RAISE EXCEPTION 'G4_PHASE11_CANONICAL_TABLE_ALREADY_EXISTS';
    END IF;
END
$migration_guard$;

-- -------------------------------------------------------------------------
-- 1. Company default, Store override, and Terminal eligibility policy
-- -------------------------------------------------------------------------

CREATE TABLE public.pos_offline_allowance_policies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    scope_type TEXT NOT NULL,
    store_id UUID,
    terminal_id UUID,
    allocation_percent NUMERIC(9,6),
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_offline_policy_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT pos_offline_policy_scope_check CHECK (
        scope_type IN ('COMPANY','STORE','TERMINAL')
    ),
    CONSTRAINT pos_offline_policy_shape_check CHECK (
        (
            scope_type = 'COMPANY'
            AND store_id IS NULL
            AND terminal_id IS NULL
            AND allocation_percent IS NOT NULL
        )
        OR (
            scope_type = 'STORE'
            AND store_id IS NOT NULL
            AND terminal_id IS NULL
            AND allocation_percent IS NOT NULL
        )
        OR (
            scope_type = 'TERMINAL'
            AND store_id IS NOT NULL
            AND terminal_id IS NOT NULL
            AND allocation_percent IS NULL
        )
    ),
    CONSTRAINT pos_offline_policy_percent_check CHECK (
        allocation_percent IS NULL
        OR allocation_percent > 0 AND allocation_percent <= 1
    ),
    CONSTRAINT pos_offline_policy_version_positive CHECK (
        master_version > 0
    ),
    CONSTRAINT fk_pos_offline_policy_company_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_policy_company_store_terminal
        FOREIGN KEY(company_id,store_id,terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id)
        ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_pos_offline_policy_company_default
    ON public.pos_offline_allowance_policies(company_id)
    WHERE scope_type = 'COMPANY';
CREATE UNIQUE INDEX uq_pos_offline_policy_store_override
    ON public.pos_offline_allowance_policies(company_id,store_id)
    WHERE scope_type = 'STORE';
CREATE UNIQUE INDEX uq_pos_offline_policy_terminal_eligibility
    ON public.pos_offline_allowance_policies(company_id,terminal_id)
    WHERE scope_type = 'TERMINAL';
CREATE INDEX idx_pos_offline_policy_company_scope_enabled
    ON public.pos_offline_allowance_policies(
        company_id,scope_type,is_enabled
    );

-- Default is 20%. Terminal eligibility is never provisioned automatically.
INSERT INTO public.pos_offline_allowance_policies(
    company_id,scope_type,allocation_percent,is_enabled
)
SELECT c.id,'COMPANY',0.200000,TRUE
FROM public.companies c
WHERE c.status = 'ACTIVE';

-- -------------------------------------------------------------------------
-- 2. Allowance reservation and shared append-only audit
-- -------------------------------------------------------------------------

CREATE TABLE public.pos_offline_stock_allowances (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    policy_id UUID NOT NULL,
    store_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    terminal_id UUID NOT NULL,
    cashier_session_id UUID NOT NULL,
    cashier_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    product_id UUID NOT NULL,
    base_uom_id UUID NOT NULL,
    allocated_base_qty NUMERIC(24,6) NOT NULL,
    consumed_base_qty NUMERIC(24,6) NOT NULL DEFAULT 0,
    allocation_percent_snapshot NUMERIC(9,6) NOT NULL,
    stock_qty_snapshot NUMERIC(24,6) NOT NULL,
    unreserved_qty_snapshot NUMERIC(24,6) NOT NULL,
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    released_at TIMESTAMPTZ,
    released_by UUID REFERENCES public.profiles(id),
    release_reason TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_offline_allowance_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT pos_offline_allowance_status_check CHECK (
        status IN ('ACTIVE','CONSUMED','RELEASED','REVOKED')
    ),
    CONSTRAINT pos_offline_allowance_quantity_check CHECK (
        allocated_base_qty > 0
        AND consumed_base_qty >= 0
        AND consumed_base_qty <= allocated_base_qty
        AND stock_qty_snapshot >= allocated_base_qty
        AND unreserved_qty_snapshot >= allocated_base_qty
    ),
    CONSTRAINT pos_offline_allowance_percent_check CHECK (
        allocation_percent_snapshot > 0
        AND allocation_percent_snapshot <= 1
    ),
    CONSTRAINT pos_offline_allowance_terminal_state_check CHECK (
        (status = 'ACTIVE' AND released_at IS NULL
         AND released_by IS NULL AND release_reason IS NULL)
        OR
        (status = 'CONSUMED' AND consumed_base_qty = allocated_base_qty
         AND released_at IS NULL AND released_by IS NULL
         AND release_reason IS NULL)
        OR
        (status IN ('RELEASED','REVOKED')
         AND released_at IS NOT NULL
         AND released_by IS NOT NULL
         AND btrim(release_reason) <> '')
    ),
    CONSTRAINT pos_offline_allowance_version_positive CHECK (
        master_version > 0
    ),
    CONSTRAINT fk_pos_offline_allowance_policy
        FOREIGN KEY(company_id,policy_id)
        REFERENCES public.pos_offline_allowance_policies(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_allowance_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_allowance_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_allowance_terminal
        FOREIGN KEY(company_id,store_id,terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_allowance_session
        FOREIGN KEY(company_id,store_id,terminal_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,pos_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_allowance_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_allowance_base_uom
        FOREIGN KEY(company_id,base_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE UNIQUE INDEX uq_pos_offline_allowance_active_session_product
    ON public.pos_offline_stock_allowances(
        company_id,cashier_session_id,product_id
    )
    WHERE status = 'ACTIVE';
CREATE INDEX idx_pos_offline_allowance_reservation
    ON public.pos_offline_stock_allowances(
        company_id,warehouse_id,product_id,status
    );
CREATE INDEX idx_pos_offline_allowance_terminal_session
    ON public.pos_offline_stock_allowances(
        company_id,terminal_id,cashier_session_id,status
    );

CREATE TABLE public.pos_offline_stock_allowance_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    policy_id UUID,
    allowance_id UUID,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_offline_allowance_audit_target_check CHECK (
        (policy_id IS NOT NULL AND allowance_id IS NULL)
        OR (policy_id IS NULL AND allowance_id IS NOT NULL)
    ),
    CONSTRAINT pos_offline_allowance_audit_action_check CHECK (
        action IN (
            'POLICY_CREATE','POLICY_UPDATE','ISSUE','RELEASE',
            'FORCE_REVOKE','CONSUME'
        )
    ),
    CONSTRAINT fk_pos_offline_allowance_audit_policy
        FOREIGN KEY(company_id,policy_id)
        REFERENCES public.pos_offline_allowance_policies(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_allowance_audit_allowance
        FOREIGN KEY(company_id,allowance_id)
        REFERENCES public.pos_offline_stock_allowances(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_pos_offline_allowance_audit_policy_created
    ON public.pos_offline_stock_allowance_audit(
        company_id,policy_id,created_at DESC
    ) WHERE policy_id IS NOT NULL;
CREATE INDEX idx_pos_offline_allowance_audit_allowance_created
    ON public.pos_offline_stock_allowance_audit(
        company_id,allowance_id,created_at DESC
    ) WHERE allowance_id IS NOT NULL;

-- -------------------------------------------------------------------------
-- 3. Server-only offline submission envelope; ingest/post remains closed
-- -------------------------------------------------------------------------

CREATE TABLE public.pos_offline_sale_submissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    client_transaction_id UUID NOT NULL,
    posting_idempotency_key UUID NOT NULL,
    store_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    terminal_id UUID NOT NULL,
    cashier_session_id UUID NOT NULL,
    cashier_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    local_master_version BIGINT NOT NULL,
    local_transaction_at TIMESTAMPTZ NOT NULL,
    payload_snapshot JSONB NOT NULL,
    payload_hash TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'QUEUED',
    sales_id UUID,
    acknowledgement JSONB,
    error_code TEXT,
    error_message TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    processed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_offline_submission_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT pos_offline_submission_client_unique
        UNIQUE(company_id,client_transaction_id),
    CONSTRAINT pos_offline_submission_posting_key_unique
        UNIQUE(company_id,posting_idempotency_key),
    CONSTRAINT pos_offline_submission_status_check CHECK (
        status IN (
            'QUEUED','SYNCING','NEEDS_CONFIRMATION',
            'POSTED','FAILED','INVALIDATED'
        )
    ),
    CONSTRAINT pos_offline_submission_version_positive CHECK (
        local_master_version > 0
    ),
    CONSTRAINT pos_offline_submission_payload_check CHECK (
        jsonb_typeof(payload_snapshot) = 'object'
        AND payload_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT pos_offline_submission_result_check CHECK (
        (
            status IN ('QUEUED','SYNCING')
            AND sales_id IS NULL
            AND acknowledgement IS NULL
            AND processed_at IS NULL
        )
        OR (
            status = 'POSTED'
            AND sales_id IS NOT NULL
            AND acknowledgement IS NOT NULL
            AND processed_at IS NOT NULL
            AND error_code IS NULL
        )
        OR (
            status IN ('NEEDS_CONFIRMATION','FAILED','INVALIDATED')
            AND sales_id IS NULL
            AND processed_at IS NOT NULL
            AND btrim(error_code) <> ''
        )
    ),
    CONSTRAINT fk_pos_offline_submission_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_submission_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_submission_terminal
        FOREIGN KEY(company_id,store_id,terminal_id)
        REFERENCES public.pos_terminals(company_id,store_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_submission_session
        FOREIGN KEY(company_id,store_id,terminal_id,cashier_session_id)
        REFERENCES public.cashier_sessions(company_id,store_id,pos_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_pos_offline_submission_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_pos_offline_submission_terminal_status
    ON public.pos_offline_sale_submissions(
        company_id,terminal_id,status,received_at
    );
CREATE INDEX idx_pos_offline_submission_session_status
    ON public.pos_offline_sale_submissions(
        company_id,cashier_session_id,status,received_at
    );

CREATE TABLE public.pos_offline_sale_submission_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    submission_id UUID NOT NULL,
    event_type TEXT NOT NULL,
    actor_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT pos_offline_submission_event_type_check CHECK (
        event_type IN (
            'RECEIVED','SYNC_STARTED','NEEDS_CONFIRMATION',
            'POSTED','FAILED','INVALIDATED','RETRY'
        )
    ),
    CONSTRAINT fk_pos_offline_submission_event_submission
        FOREIGN KEY(company_id,submission_id)
        REFERENCES public.pos_offline_sale_submissions(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_pos_offline_submission_event_created
    ON public.pos_offline_sale_submission_events(
        company_id,submission_id,created_at
    );

-- -------------------------------------------------------------------------
-- 4. Versioning, reservation guard, and Session close guard
-- -------------------------------------------------------------------------

CREATE TRIGGER g4_touch_pos_offline_allowance_policies
BEFORE INSERT OR UPDATE ON public.pos_offline_allowance_policies
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE TRIGGER g4_touch_pos_offline_stock_allowances
BEFORE INSERT OR UPDATE ON public.pos_offline_stock_allowances
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE FUNCTION private.trg_g4_guard_offline_reserved_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_reserved NUMERIC(24,6);
BEGIN
    IF TG_OP = 'UPDATE'
       AND NEW.stock_qty IS NOT DISTINCT FROM OLD.stock_qty THEN
        RETURN NEW;
    END IF;

    SELECT COALESCE(sum(
        osa.allocated_base_qty - osa.consumed_base_qty
    ),0)
    INTO v_reserved
    FROM public.pos_offline_stock_allowances osa
    WHERE osa.company_id = OLD.company_id
      AND osa.warehouse_id = OLD.warehouse_id
      AND osa.product_id = OLD.product_id
      AND osa.status = 'ACTIVE';

    IF TG_OP = 'DELETE' AND v_reserved > 0 THEN
        RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.stock_qty < v_reserved THEN
        RAISE EXCEPTION 'STOCK_RESERVED_FOR_OFFLINE_ALLOWANCE';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g4_guard_offline_reserved_stock
BEFORE UPDATE OF stock_qty ON public.product_stocks
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_guard_offline_reserved_stock();
CREATE TRIGGER g4_guard_offline_reserved_stock_delete
BEFORE DELETE ON public.product_stocks
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_guard_offline_reserved_stock();

CREATE FUNCTION private.trg_g4_guard_offline_session_close()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF OLD.status = 'OPEN'::public.session_status
       AND NEW.status = 'CLOSED'::public.session_status THEN
        IF EXISTS (
            SELECT 1
            FROM public.pos_offline_stock_allowances osa
            WHERE osa.company_id = OLD.company_id
              AND osa.cashier_session_id = OLD.id
              AND osa.status = 'ACTIVE'
              AND osa.allocated_base_qty > osa.consumed_base_qty
        ) THEN
            RAISE EXCEPTION 'OFFLINE_ALLOWANCE_RELEASE_REQUIRED';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM public.pos_offline_sale_submissions oss
            WHERE oss.company_id = OLD.company_id
              AND oss.cashier_session_id = OLD.id
              AND oss.status IN (
                  'QUEUED','SYNCING','NEEDS_CONFIRMATION','FAILED'
              )
        ) THEN
            RAISE EXCEPTION 'OFFLINE_QUEUE_RESOLUTION_REQUIRED';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER g4_guard_offline_session_close
BEFORE UPDATE OF status ON public.cashier_sessions
FOR EACH ROW EXECUTE FUNCTION private.trg_g4_guard_offline_session_close();

CREATE FUNCTION private.trg_g4_reject_offline_history_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'OFFLINE_HISTORY_MUTATION_FORBIDDEN';
END;
$$;

CREATE TRIGGER g4_guard_offline_policy_delete
BEFORE DELETE ON public.pos_offline_allowance_policies
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();
CREATE TRIGGER g4_guard_offline_allowance_delete
BEFORE DELETE ON public.pos_offline_stock_allowances
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();
CREATE TRIGGER g4_guard_offline_allowance_audit_immutable
BEFORE UPDATE OR DELETE ON public.pos_offline_stock_allowance_audit
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();
CREATE TRIGGER g4_guard_offline_submission_delete
BEFORE DELETE ON public.pos_offline_sale_submissions
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();
CREATE TRIGGER g4_guard_offline_submission_event_immutable
BEFORE UPDATE OR DELETE ON public.pos_offline_sale_submission_events
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g4_reject_offline_history_mutation();

-- -------------------------------------------------------------------------
-- 5. Guarded policy, issue, and release RPCs
-- -------------------------------------------------------------------------

CREATE FUNCTION public.save_pos_offline_allowance_policy(
    p_policy_id UUID,
    p_master_version BIGINT,
    p_scope_type TEXT,
    p_store_id UUID,
    p_terminal_id UUID,
    p_allocation_percent NUMERIC,
    p_is_enabled BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_scope TEXT := upper(btrim(COALESCE(p_scope_type,'')));
    v_existing public.pos_offline_allowance_policies%ROWTYPE;
    v_policy_id UUID;
    v_result_version BIGINT;
    v_before JSONB;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF v_scope NOT IN ('COMPANY','STORE','TERMINAL') THEN
        RAISE EXCEPTION 'OFFLINE_POLICY_SCOPE_INVALID';
    END IF;

    IF v_scope = 'COMPANY' THEN
        IF NOT public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        ) THEN
            RAISE EXCEPTION 'OFFLINE_COMPANY_POLICY_MANAGER_REQUIRED';
        END IF;
        IF p_store_id IS NOT NULL OR p_terminal_id IS NOT NULL THEN
            RAISE EXCEPTION 'OFFLINE_COMPANY_POLICY_SCOPE_INVALID';
        END IF;
    ELSE
        IF p_store_id IS NULL THEN
            RAISE EXCEPTION 'OFFLINE_POLICY_STORE_REQUIRED';
        END IF;
        IF NOT (
            public.private_user_has_any_company_role(
                v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
            )
            OR public.private_user_has_any_store_role(
                p_store_id,ARRAY['STORE_MANAGER']::TEXT[]
            )
        ) THEN
            RAISE EXCEPTION 'OFFLINE_STORE_POLICY_MANAGER_REQUIRED';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.stores s
            WHERE s.company_id = v_company
              AND s.id = p_store_id
              AND s.status = 'ACTIVE'
        ) THEN
            RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND';
        END IF;
    END IF;

    IF v_scope = 'TERMINAL' THEN
        IF p_terminal_id IS NULL OR p_allocation_percent IS NOT NULL THEN
            RAISE EXCEPTION 'OFFLINE_TERMINAL_POLICY_SHAPE_INVALID';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.pos_terminals pt
            WHERE pt.company_id = v_company
              AND pt.store_id = p_store_id
              AND pt.id = p_terminal_id
              AND pt.status = 'ACTIVE'
        ) THEN
            RAISE EXCEPTION 'ACTIVE_POS_TERMINAL_NOT_FOUND';
        END IF;
    ELSE
        IF p_terminal_id IS NOT NULL
           OR p_allocation_percent IS NULL
           OR p_allocation_percent <= 0
           OR p_allocation_percent > 1 THEN
            RAISE EXCEPTION 'OFFLINE_POLICY_PERCENT_INVALID';
        END IF;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_company::TEXT || ':OFFLINE_POLICY:' || v_scope || ':' ||
        COALESCE(p_store_id::TEXT,'-') || ':' ||
        COALESCE(p_terminal_id::TEXT,'-'),0
    ));

    IF p_policy_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.pos_offline_allowance_policies(
            company_id,scope_type,store_id,terminal_id,
            allocation_percent,is_enabled,created_by,updated_by
        ) VALUES (
            v_company,v_scope,p_store_id,p_terminal_id,
            p_allocation_percent,COALESCE(p_is_enabled,TRUE),
            v_actor,v_actor
        )
        RETURNING id,master_version INTO v_policy_id,v_result_version;
        SELECT to_jsonb(p) INTO v_after
        FROM public.pos_offline_allowance_policies p
        WHERE p.company_id = v_company AND p.id = v_policy_id;
        INSERT INTO public.pos_offline_stock_allowance_audit(
            company_id,policy_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_company,v_policy_id,'POLICY_CREATE',v_actor,NULL,v_after
        );
    ELSE
        SELECT * INTO v_existing
        FROM public.pos_offline_allowance_policies p
        WHERE p.company_id = v_company AND p.id = p_policy_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'OFFLINE_POLICY_NOT_FOUND'; END IF;
        IF p_master_version IS NULL
           OR p_master_version <> v_existing.master_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        IF v_existing.scope_type IS DISTINCT FROM v_scope
           OR v_existing.store_id IS DISTINCT FROM p_store_id
           OR v_existing.terminal_id IS DISTINCT FROM p_terminal_id THEN
            RAISE EXCEPTION 'OFFLINE_POLICY_IDENTITY_IMMUTABLE';
        END IF;
        v_before := to_jsonb(v_existing);
        UPDATE public.pos_offline_allowance_policies SET
            allocation_percent = p_allocation_percent,
            is_enabled = COALESCE(p_is_enabled,TRUE),
            updated_by = v_actor
        WHERE company_id = v_company AND id = p_policy_id
        RETURNING id,master_version INTO v_policy_id,v_result_version;
        SELECT to_jsonb(p) INTO v_after
        FROM public.pos_offline_allowance_policies p
        WHERE p.company_id = v_company AND p.id = v_policy_id;
        INSERT INTO public.pos_offline_stock_allowance_audit(
            company_id,policy_id,action,actor_id,before_state,after_state
        ) VALUES (
            v_company,v_policy_id,'POLICY_UPDATE',v_actor,v_before,v_after
        );
    END IF;

    RETURN jsonb_build_object(
        'policyId',v_policy_id,'masterVersion',v_result_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'OFFLINE_POLICY_SCOPE_ALREADY_EXISTS';
END;
$$;

CREATE FUNCTION public.issue_pos_offline_stock_allowance(
    p_cashier_session_id UUID,
    p_product_id UUID
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
    v_terminal_policy public.pos_offline_allowance_policies%ROWTYPE;
    v_percent NUMERIC(9,6);
    v_allow_decimal BOOLEAN;
    v_precision INTEGER;
    v_base_uom UUID;
    v_stock NUMERIC(24,6);
    v_reserved NUMERIC(24,6);
    v_available NUMERIC(24,6);
    v_allocation NUMERIC(24,6);
    v_allowance_id UUID;
    v_version BIGINT;
    v_after JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.company_features cf
        WHERE cf.company_id = v_company
          AND cf.feature_code = 'offline_pos_enabled'
          AND cf.is_enabled
    ) THEN
        RAISE EXCEPTION 'OFFLINE_POS_FEATURE_DISABLED';
    END IF;

    SELECT * INTO v_session
    FROM public.cashier_sessions cs
    WHERE cs.company_id = v_company
      AND cs.id = p_cashier_session_id
      AND cs.status = 'OPEN'::public.session_status
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_CASHIER_SESSION_REQUIRED'; END IF;
    IF NOT (
        v_session.cashier_id = v_actor
        OR public.private_user_has_any_company_role(
            v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
            v_session.store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    ) THEN
        RAISE EXCEPTION 'OFFLINE_ALLOWANCE_SESSION_ACCESS_DENIED';
    END IF;

    SELECT * INTO v_terminal_policy
    FROM public.pos_offline_allowance_policies p
    WHERE p.company_id = v_company
      AND p.scope_type = 'TERMINAL'
      AND p.store_id = v_session.store_id
      AND p.terminal_id = v_session.pos_id
      AND p.is_enabled;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OFFLINE_TERMINAL_NOT_ENABLED';
    END IF;

    SELECT p.allocation_percent INTO v_percent
    FROM public.pos_offline_allowance_policies p
    WHERE p.company_id = v_company
      AND p.scope_type = 'COMPANY'
      AND p.is_enabled;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OFFLINE_COMPANY_POLICY_NOT_ENABLED';
    END IF;
    SELECT p.allocation_percent INTO v_allocation
    FROM public.pos_offline_allowance_policies p
    WHERE p.company_id = v_company
      AND p.scope_type = 'STORE'
      AND p.store_id = v_session.store_id
      AND p.is_enabled;
    IF FOUND THEN v_percent := v_allocation; END IF;

    SELECT p.uom_id,u.allow_decimal,u.decimal_precision
    INTO v_base_uom,v_allow_decimal,v_precision
    FROM public.products p
    JOIN public.product_uoms pu
      ON pu.company_id = p.company_id
     AND pu.product_id = p.id
     AND pu.uom_id = p.uom_id
     AND pu.factor_to_base = 1
     AND pu.is_active
    JOIN public.uoms u
      ON u.company_id = p.company_id
     AND u.id = p.uom_id
     AND u.is_active
    WHERE p.company_id = v_company
      AND p.id = p_product_id
      AND p.is_active
      AND NOT p.is_bundle;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        v_company::TEXT || ':OFFLINE_ALLOWANCE:' ||
        v_session.sales_warehouse_id::TEXT || ':' || p_product_id::TEXT,0
    ));

    SELECT osa.id,osa.master_version
    INTO v_allowance_id,v_version
    FROM public.pos_offline_stock_allowances osa
    WHERE osa.company_id = v_company
      AND osa.cashier_session_id = p_cashier_session_id
      AND osa.product_id = p_product_id
      AND osa.status = 'ACTIVE'
    FOR UPDATE;
    IF FOUND THEN
        RETURN jsonb_build_object(
            'allowanceId',v_allowance_id,'masterVersion',v_version,
            'replayed',TRUE
        );
    END IF;

    SELECT ps.stock_qty INTO v_stock
    FROM public.product_stocks ps
    WHERE ps.company_id = v_company
      AND ps.warehouse_id = v_session.sales_warehouse_id
      AND ps.product_id = p_product_id
    FOR UPDATE;
    IF NOT FOUND OR v_stock <= 0 THEN
        RAISE EXCEPTION 'OFFLINE_ALLOWANCE_STOCK_UNAVAILABLE';
    END IF;

    SELECT COALESCE(sum(
        osa.allocated_base_qty - osa.consumed_base_qty
    ),0)
    INTO v_reserved
    FROM public.pos_offline_stock_allowances osa
    WHERE osa.company_id = v_company
      AND osa.warehouse_id = v_session.sales_warehouse_id
      AND osa.product_id = p_product_id
      AND osa.status = 'ACTIVE';
    v_available := v_stock - v_reserved;
    IF v_available <= 0 THEN
        RAISE EXCEPTION 'OFFLINE_ALLOWANCE_STOCK_UNAVAILABLE';
    END IF;

    IF v_allow_decimal THEN
        v_allocation := trunc(v_available * v_percent,v_precision);
    ELSE
        v_allocation := trunc(v_available * v_percent);
        IF v_allocation = 0 AND v_available >= 1 THEN
            v_allocation := 1;
        END IF;
    END IF;
    IF v_allocation <= 0 OR v_allocation > v_available THEN
        RAISE EXCEPTION 'OFFLINE_ALLOWANCE_QUANTITY_UNAVAILABLE';
    END IF;

    INSERT INTO public.pos_offline_stock_allowances(
        company_id,policy_id,store_id,warehouse_id,terminal_id,
        cashier_session_id,cashier_id,product_id,base_uom_id,
        allocated_base_qty,allocation_percent_snapshot,
        stock_qty_snapshot,unreserved_qty_snapshot,created_by,updated_by
    ) VALUES (
        v_company,v_terminal_policy.id,v_session.store_id,
        v_session.sales_warehouse_id,v_session.pos_id,v_session.id,
        v_session.cashier_id,p_product_id,v_base_uom,v_allocation,
        v_percent,v_stock,v_available,v_actor,v_actor
    )
    RETURNING id,master_version INTO v_allowance_id,v_version;

    SELECT to_jsonb(a) INTO v_after
    FROM public.pos_offline_stock_allowances a
    WHERE a.company_id = v_company AND a.id = v_allowance_id;
    INSERT INTO public.pos_offline_stock_allowance_audit(
        company_id,allowance_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_allowance_id,'ISSUE',v_actor,NULL,v_after
    );

    RETURN jsonb_build_object(
        'allowanceId',v_allowance_id,'masterVersion',v_version,
        'allocatedBaseQty',v_allocation,
        'remainingBaseQty',v_allocation,'baseUomId',v_base_uom,
        'stockQtySnapshot',v_stock,
        'unreservedQtySnapshot',v_available,'replayed',FALSE
    );
END;
$$;

CREATE FUNCTION public.release_pos_offline_stock_allowance(
    p_allowance_id UUID,
    p_master_version BIGINT,
    p_force BOOLEAN DEFAULT FALSE,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_allowance public.pos_offline_stock_allowances%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_action TEXT;
    v_status TEXT;
    v_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;

    SELECT * INTO v_allowance
    FROM public.pos_offline_stock_allowances a
    WHERE a.company_id = v_company AND a.id = p_allowance_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'OFFLINE_ALLOWANCE_NOT_FOUND'; END IF;
    IF v_allowance.status <> 'ACTIVE' THEN
        RETURN jsonb_build_object(
            'allowanceId',v_allowance.id,'status',v_allowance.status,
            'masterVersion',v_allowance.master_version,'replayed',TRUE
        );
    END IF;
    IF p_master_version IS NULL
       OR p_master_version <> v_allowance.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions s
        WHERE s.company_id = v_company
          AND s.cashier_session_id = v_allowance.cashier_session_id
          AND s.status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION')
    ) AND NOT COALESCE(p_force,FALSE) THEN
        RAISE EXCEPTION 'OFFLINE_QUEUE_RESOLUTION_REQUIRED';
    END IF;

    IF COALESCE(p_force,FALSE) THEN
        IF NOT (
            public.private_user_has_any_company_role(
                v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
            )
            OR public.private_user_has_any_store_role(
                v_allowance.store_id,ARRAY['STORE_MANAGER']::TEXT[]
            )
        ) THEN
            RAISE EXCEPTION 'OFFLINE_ALLOWANCE_FORCE_REVOKE_FORBIDDEN';
        END IF;
        IF NULLIF(btrim(p_reason),'') IS NULL THEN
            RAISE EXCEPTION 'OFFLINE_ALLOWANCE_REVOKE_REASON_REQUIRED';
        END IF;
        v_action := 'FORCE_REVOKE';
        v_status := 'REVOKED';
    ELSE
        IF v_allowance.cashier_id <> v_actor THEN
            RAISE EXCEPTION 'OFFLINE_ALLOWANCE_RELEASE_FORBIDDEN';
        END IF;
        IF v_allowance.consumed_base_qty <> 0 THEN
            RAISE EXCEPTION 'CONSUMED_OFFLINE_ALLOWANCE_CANNOT_RELEASE';
        END IF;
        v_action := 'RELEASE';
        v_status := 'RELEASED';
    END IF;

    v_before := to_jsonb(v_allowance);
    UPDATE public.pos_offline_stock_allowances SET
        status = v_status,
        released_at = clock_timestamp(),
        released_by = v_actor,
        release_reason = COALESCE(
            NULLIF(btrim(p_reason),''),
            'Released by Cashier before Session close'
        ),
        updated_by = v_actor
    WHERE company_id = v_company AND id = p_allowance_id
    RETURNING master_version INTO v_version;

    IF v_status = 'REVOKED' THEN
        UPDATE public.pos_offline_sale_submissions SET
            status = 'INVALIDATED',
            error_code = 'OFFLINE_ALLOWANCE_REVOKED',
            error_message = 'Allowance was force revoked after physical review',
            processed_at = clock_timestamp(),
            updated_at = clock_timestamp()
        WHERE company_id = v_company
          AND cashier_session_id = v_allowance.cashier_session_id
          AND status IN ('QUEUED','SYNCING','NEEDS_CONFIRMATION');
    END IF;

    SELECT to_jsonb(a) INTO v_after
    FROM public.pos_offline_stock_allowances a
    WHERE a.company_id = v_company AND a.id = p_allowance_id;
    INSERT INTO public.pos_offline_stock_allowance_audit(
        company_id,allowance_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,p_allowance_id,v_action,v_actor,v_before,v_after
    );

    RETURN jsonb_build_object(
        'allowanceId',p_allowance_id,'status',v_status,
        'masterVersion',v_version,'replayed',FALSE
    );
END;
$$;

-- -------------------------------------------------------------------------
-- 6. RLS and exact grants
-- -------------------------------------------------------------------------

ALTER TABLE public.pos_offline_allowance_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_offline_stock_allowances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_offline_stock_allowance_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_offline_sale_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_offline_sale_submission_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Offline policy managers read active Company policies"
ON public.pos_offline_allowance_policies FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        public.private_user_has_any_company_role(
            company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR (
            store_id IS NOT NULL
            AND public.private_user_has_any_store_role(
                store_id,ARRAY['STORE_MANAGER']::TEXT[]
            )
        )
    )
);

CREATE POLICY "POS operators read scoped Offline allowances"
ON public.pos_offline_stock_allowances FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        cashier_id = auth.uid()
        OR public.private_user_has_any_company_role(
            company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
            store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    )
);

CREATE POLICY "Offline managers read allowance audit"
ON public.pos_offline_stock_allowance_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        public.private_user_has_any_company_role(
            company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR EXISTS (
            SELECT 1 FROM public.pos_offline_stock_allowances a
            WHERE a.company_id =
                    pos_offline_stock_allowance_audit.company_id
              AND a.id = pos_offline_stock_allowance_audit.allowance_id
              AND public.private_user_has_any_store_role(
                  a.store_id,ARRAY['STORE_MANAGER']::TEXT[]
              )
        )
        OR EXISTS (
            SELECT 1 FROM public.pos_offline_allowance_policies p
            WHERE p.company_id =
                    pos_offline_stock_allowance_audit.company_id
              AND p.id = pos_offline_stock_allowance_audit.policy_id
              AND p.store_id IS NOT NULL
              AND public.private_user_has_any_store_role(
                  p.store_id,ARRAY['STORE_MANAGER']::TEXT[]
              )
        )
    )
);

CREATE POLICY "POS operators read scoped Offline submissions"
ON public.pos_offline_sale_submissions FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND (
        cashier_id = auth.uid()
        OR public.private_user_has_any_company_role(
            company_id,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
        )
        OR public.private_user_has_any_store_role(
            store_id,ARRAY['STORE_MANAGER']::TEXT[]
        )
    )
);

CREATE POLICY "POS operators read scoped Offline submission events"
ON public.pos_offline_sale_submission_events FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND EXISTS (
        SELECT 1 FROM public.pos_offline_sale_submissions s
        WHERE s.company_id = pos_offline_sale_submission_events.company_id
          AND s.id = pos_offline_sale_submission_events.submission_id
          AND (
              s.cashier_id = auth.uid()
              OR public.private_user_has_any_company_role(
                  s.company_id,
                  ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
              )
              OR public.private_user_has_any_store_role(
                  s.store_id,ARRAY['STORE_MANAGER']::TEXT[]
              )
          )
    )
);

REVOKE ALL ON
    public.pos_offline_allowance_policies,
    public.pos_offline_stock_allowances,
    public.pos_offline_stock_allowance_audit,
    public.pos_offline_sale_submissions,
    public.pos_offline_sale_submission_events
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON
    public.pos_offline_allowance_policies,
    public.pos_offline_stock_allowances,
    public.pos_offline_sale_submissions,
    public.pos_offline_sale_submission_events
TO authenticated;
GRANT SELECT ON public.pos_offline_stock_allowance_audit
TO authenticated;
GRANT ALL ON
    public.pos_offline_allowance_policies,
    public.pos_offline_stock_allowances,
    public.pos_offline_stock_allowance_audit,
    public.pos_offline_sale_submissions,
    public.pos_offline_sale_submission_events
TO service_role;

REVOKE ALL ON FUNCTION
    private.trg_g4_guard_offline_reserved_stock(),
    private.trg_g4_guard_offline_session_close(),
    private.trg_g4_reject_offline_history_mutation()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g4_guard_offline_reserved_stock(),
    private.trg_g4_guard_offline_session_close(),
    private.trg_g4_reject_offline_history_mutation()
TO service_role;

REVOKE ALL ON FUNCTION public.save_pos_offline_allowance_policy(
    UUID,BIGINT,TEXT,UUID,UUID,NUMERIC,BOOLEAN
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.issue_pos_offline_stock_allowance(
    UUID,UUID
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.release_pos_offline_stock_allowance(
    UUID,BIGINT,BOOLEAN,TEXT
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_pos_offline_allowance_policy(
    UUID,BIGINT,TEXT,UUID,UUID,NUMERIC,BOOLEAN
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.issue_pos_offline_stock_allowance(
    UUID,UUID
) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.release_pos_offline_stock_allowance(
    UUID,BIGINT,BOOLEAN,TEXT
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260729180000',
    'g4_phase11_offline_stock_allowance_foundation',
    'POS-004 Company/Store/Terminal policy, Session/Product allowance reservation, stock/session guards, audit, and server-only submission envelope; sync remains closed'
);

COMMIT;
