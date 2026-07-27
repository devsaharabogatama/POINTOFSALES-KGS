-- KGS POS G2 phase 14: canonical Payment Method master foundation.
--
-- This migration does not cut over checkout, calculate payment totals, post
-- settlement, reconcile providers, or create Finance journals. Legacy
-- sales_payments.payment_method remains available until the G4 payment resolver.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722100000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: reusable Customer Pricelist correction missing';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260722120000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260722120000';
    END IF;
    IF to_regclass('public.payment_methods') IS NOT NULL
       OR to_regclass('public.payment_method_store_assignments') IS NOT NULL
       OR to_regclass('public.payment_method_master_audit') IS NOT NULL THEN
        RAISE EXCEPTION 'G2_PHASE14_CANONICAL_TABLE_ALREADY_EXISTS';
    END IF;
    IF EXISTS (SELECT 1 FROM public.sales_payments) THEN
        RAISE EXCEPTION
            'G2_PHASE14_STATE_CHANGED: Sales Payment history appeared; rerun preflight and design explicit snapshot backfill';
    END IF;
END
$migration_guard$;

CREATE TABLE public.payment_methods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    payment_method_code TEXT NOT NULL,
    payment_method_name TEXT NOT NULL,
    method_type TEXT NOT NULL,
    settlement_route TEXT NOT NULL,
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    available_all_stores BOOLEAN NOT NULL DEFAULT TRUE,
    proof_mode TEXT NOT NULL DEFAULT 'OPTIONAL',
    fee_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    fee_bearer TEXT,
    fee_type TEXT,
    fee_percent NUMERIC(9,6),
    fee_fixed_amount NUMERIC(20,4),
    clearing_account_function TEXT,
    bank_account_function TEXT,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    effective_to TIMESTAMPTZ,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_system_method BOOLEAN NOT NULL DEFAULT FALSE,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID REFERENCES public.profiles(id),
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT payment_methods_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT payment_methods_code_not_blank
        CHECK (btrim(payment_method_code) <> ''),
    CONSTRAINT payment_methods_name_not_blank
        CHECK (btrim(payment_method_name) <> ''),
    CONSTRAINT payment_methods_type_check CHECK (
        method_type IN (
            'CASH','TRANSFER','QRIS','CARD','E_WALLET','TEMPO','CUSTOM',
            'CUSTOMER_BALANCE','KETUL_OFFSET'
        )
    ),
    CONSTRAINT payment_methods_settlement_route_check CHECK (
        settlement_route IN (
            'CASH_DRAWER','DIRECT_BANK','CLEARING','RECEIVABLE',
            'INTERNAL_LIABILITY'
        )
    ),
    CONSTRAINT payment_methods_proof_mode_check
        CHECK (proof_mode IN ('OPTIONAL','REQUIRED')),
    CONSTRAINT payment_methods_period_check CHECK (
        effective_to IS NULL OR effective_to >= effective_from
    ),
    CONSTRAINT payment_methods_default_active_check
        CHECK (NOT is_default OR is_active),
    CONSTRAINT payment_methods_version_positive CHECK (master_version > 0),
    CONSTRAINT payment_methods_internal_contract_check CHECK (
        (method_type IN ('CUSTOMER_BALANCE','KETUL_OFFSET')
         AND is_system_method AND settlement_route = 'INTERNAL_LIABILITY')
        OR
        (method_type NOT IN ('CUSTOMER_BALANCE','KETUL_OFFSET')
         AND NOT is_system_method
         AND settlement_route <> 'INTERNAL_LIABILITY')
    ),
    CONSTRAINT payment_methods_route_type_check CHECK (
        (method_type = 'CASH' AND settlement_route = 'CASH_DRAWER')
        OR (method_type = 'TEMPO' AND settlement_route = 'RECEIVABLE')
        OR (method_type IN ('TRANSFER','QRIS','CARD','E_WALLET')
            AND settlement_route IN ('DIRECT_BANK','CLEARING'))
        OR (method_type = 'CUSTOM'
            AND settlement_route IN (
                'CASH_DRAWER','DIRECT_BANK','CLEARING','RECEIVABLE'
            ))
        OR (method_type IN ('CUSTOMER_BALANCE','KETUL_OFFSET')
            AND settlement_route = 'INTERNAL_LIABILITY')
    ),
    CONSTRAINT payment_methods_account_function_check CHECK (
        (settlement_route = 'DIRECT_BANK'
         AND bank_account_function IS NOT NULL
         AND btrim(bank_account_function) <> '')
        OR (settlement_route = 'CLEARING'
            AND clearing_account_function IS NOT NULL
            AND btrim(clearing_account_function) <> '')
        OR settlement_route IN (
            'CASH_DRAWER','RECEIVABLE','INTERNAL_LIABILITY'
        )
    ),
    CONSTRAINT payment_methods_fee_check CHECK (
        (
            NOT fee_enabled
            AND fee_bearer IS NULL
            AND fee_type IS NULL
            AND fee_percent IS NULL
            AND fee_fixed_amount IS NULL
        )
        OR
        (
            fee_enabled
            AND settlement_route IN ('DIRECT_BANK','CLEARING')
            AND fee_bearer IN ('COMPANY','CUSTOMER')
            AND (
                (fee_type = 'PERCENT'
                 AND fee_percent BETWEEN 0 AND 100
                 AND fee_fixed_amount IS NULL)
                OR (fee_type = 'FIXED'
                    AND fee_percent IS NULL
                    AND fee_fixed_amount >= 0)
                OR (fee_type = 'PERCENT_PLUS_FIXED'
                    AND fee_percent BETWEEN 0 AND 100
                    AND fee_fixed_amount >= 0)
            )
        )
    )
);

CREATE UNIQUE INDEX uq_payment_methods_company_normalized_code
    ON public.payment_methods(
        company_id,
        upper(regexp_replace(btrim(payment_method_code),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_payment_methods_company_normalized_name
    ON public.payment_methods(
        company_id,
        lower(regexp_replace(btrim(payment_method_name),'\s+',' ','g'))
    );
CREATE UNIQUE INDEX uq_payment_methods_one_active_default
    ON public.payment_methods(company_id)
    WHERE is_default AND is_active;
CREATE INDEX idx_payment_methods_company_active_type
    ON public.payment_methods(company_id,is_active,method_type);

CREATE TABLE public.payment_method_store_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    payment_method_id UUID NOT NULL,
    store_id UUID NOT NULL,
    created_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT payment_method_store_assignment_unique
        UNIQUE(company_id,payment_method_id,store_id),
    CONSTRAINT fk_payment_method_store_method
        FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_payment_method_store_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_payment_method_store_store
    ON public.payment_method_store_assignments(company_id,store_id);

CREATE TABLE public.payment_method_master_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    payment_method_id UUID NOT NULL,
    action TEXT NOT NULL CHECK(action IN ('CREATE','UPDATE')),
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_payment_method_audit_method
        FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT
);

CREATE INDEX idx_payment_method_audit_method_created
    ON public.payment_method_master_audit(
        company_id,payment_method_id,created_at DESC
    );

ALTER TABLE public.sales_payments
    ADD COLUMN payment_method_id UUID,
    ADD COLUMN payment_method_code_snapshot TEXT,
    ADD COLUMN payment_method_name_snapshot TEXT,
    ADD COLUMN payment_method_type_snapshot TEXT,
    ADD COLUMN settlement_route_snapshot TEXT,
    ADD COLUMN fee_bearer_snapshot TEXT,
    ADD COLUMN fee_type_snapshot TEXT,
    ADD COLUMN fee_percent_snapshot NUMERIC(9,6),
    ADD COLUMN fee_fixed_amount_snapshot NUMERIC(20,4),
    ADD COLUMN configured_fee_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD COLUMN customer_surcharge_amount NUMERIC(20,4) NOT NULL DEFAULT 0,
    ADD CONSTRAINT fk_sales_payments_company_payment_method
        FOREIGN KEY(company_id,payment_method_id)
        REFERENCES public.payment_methods(company_id,id) ON DELETE RESTRICT,
    ADD CONSTRAINT sales_payment_fee_snapshot_nonnegative CHECK (
        configured_fee_amount >= 0
        AND customer_surcharge_amount >= 0
        AND (fee_percent_snapshot IS NULL
             OR fee_percent_snapshot BETWEEN 0 AND 100)
        AND (fee_fixed_amount_snapshot IS NULL
             OR fee_fixed_amount_snapshot >= 0)
    );

CREATE INDEX idx_sales_payments_company_payment_method
    ON public.sales_payments(company_id,payment_method_id)
    WHERE payment_method_id IS NOT NULL;

CREATE TRIGGER g2_touch_payment_methods
BEFORE INSERT OR UPDATE ON public.payment_methods
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_touch_master();

CREATE FUNCTION private.trg_g2_guard_payment_method_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.payment_method_code IS DISTINCT FROM OLD.payment_method_code
       AND EXISTS (
           SELECT 1 FROM public.sales_payments sp
           WHERE sp.company_id = OLD.company_id
             AND sp.payment_method_id = OLD.id
       ) THEN
        RAISE EXCEPTION 'PAYMENT_METHOD_CODE_LOCKED_BY_HISTORY';
    END IF;
    IF OLD.is_system_method AND (
        NEW.company_id IS DISTINCT FROM OLD.company_id
        OR NEW.method_type IS DISTINCT FROM OLD.method_type
        OR NEW.settlement_route IS DISTINCT FROM OLD.settlement_route
        OR NOT NEW.is_system_method
    ) THEN
        RAISE EXCEPTION 'SYSTEM_PAYMENT_METHOD_CONTRACT_LOCKED';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g2_require_default_payment_method()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_company_id UUID;
BEGIN
    FOR v_company_id IN
        SELECT DISTINCT affected.company_id
        FROM (
            SELECT CASE WHEN TG_OP <> 'INSERT' THEN OLD.company_id END
                AS company_id
            UNION ALL
            SELECT CASE WHEN TG_OP <> 'DELETE' THEN NEW.company_id END
        ) affected
        WHERE affected.company_id IS NOT NULL
    LOOP
        IF EXISTS (
            SELECT 1 FROM public.companies c
            WHERE c.id = v_company_id AND c.status = 'ACTIVE'
        ) AND (
            SELECT count(*) FROM public.payment_methods pm
            WHERE pm.company_id = v_company_id
              AND pm.is_default
              AND pm.is_active
        ) <> 1 THEN
            RAISE EXCEPTION
                'ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_PAYMENT_METHOD';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE FUNCTION private.trg_g2_guard_company_activation_payment_method()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.status = 'ACTIVE' AND (
        SELECT count(*) FROM public.payment_methods pm
        WHERE pm.company_id = NEW.id
          AND pm.is_default
          AND pm.is_active
    ) <> 1 THEN
        RAISE EXCEPTION
            'ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_PAYMENT_METHOD';
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_guard_payment_method_history()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.trg_g2_require_default_payment_method()
FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION
    private.trg_g2_guard_company_activation_payment_method()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g2_guard_payment_method_history(),
    private.trg_g2_require_default_payment_method(),
    private.trg_g2_guard_company_activation_payment_method()
TO service_role;

CREATE TRIGGER g2_guard_payment_method_history
BEFORE UPDATE ON public.payment_methods
FOR EACH ROW EXECUTE FUNCTION private.trg_g2_guard_payment_method_history();

CREATE CONSTRAINT TRIGGER g2_require_default_payment_method
AFTER INSERT OR UPDATE OR DELETE ON public.payment_methods
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g2_require_default_payment_method();

CREATE TRIGGER g2_guard_company_activation_payment_method
AFTER UPDATE OF status ON public.companies
FOR EACH ROW
WHEN (NEW.status = 'ACTIVE')
EXECUTE FUNCTION
    private.trg_g2_guard_company_activation_payment_method();

CREATE FUNCTION private.trg_g2_provision_default_payment_method()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    INSERT INTO public.payment_methods(
        company_id,payment_method_code,payment_method_name,method_type,
        settlement_route,is_default,available_all_stores,proof_mode,
        fee_enabled,is_active
    ) VALUES (
        NEW.id,'CASH','Tunai','CASH','CASH_DRAWER',TRUE,TRUE,'OPTIONAL',
        FALSE,TRUE
    );
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g2_provision_default_payment_method()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g2_provision_default_payment_method()
TO service_role;

CREATE TRIGGER g2_provision_default_payment_method
AFTER INSERT ON public.companies
FOR EACH ROW EXECUTE FUNCTION
    private.trg_g2_provision_default_payment_method();

INSERT INTO public.payment_methods(
    company_id,payment_method_code,payment_method_name,method_type,
    settlement_route,is_default,available_all_stores,proof_mode,
    fee_enabled,is_active
)
SELECT c.id,'CASH','Tunai','CASH','CASH_DRAWER',TRUE,TRUE,'OPTIONAL',FALSE,TRUE
FROM public.companies c
WHERE c.status = 'ACTIVE';

-- Flush the deferred exact-one-default events before later ALTER TABLE RLS.
-- PostgreSQL rejects ALTER TABLE while a deferred trigger event for that table
-- is still pending, even though both operations are in the same transaction.
SET CONSTRAINTS g2_require_default_payment_method IMMEDIATE;
SET CONSTRAINTS g2_require_default_payment_method DEFERRED;

CREATE FUNCTION public.save_payment_method(
    p_payment_method_id UUID,
    p_master_version BIGINT,
    p_payment_method_code TEXT,
    p_payment_method_name TEXT,
    p_method_type TEXT,
    p_settlement_route TEXT,
    p_is_default BOOLEAN,
    p_available_all_stores BOOLEAN,
    p_store_ids UUID[],
    p_proof_mode TEXT,
    p_fee_enabled BOOLEAN,
    p_fee_bearer TEXT,
    p_fee_type TEXT,
    p_fee_percent NUMERIC,
    p_fee_fixed_amount NUMERIC,
    p_clearing_account_function TEXT,
    p_bank_account_function TEXT,
    p_effective_from TIMESTAMPTZ,
    p_effective_to TIMESTAMPTZ,
    p_is_active BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_id UUID;
    v_version BIGINT;
    v_before JSONB;
    v_after JSONB;
    v_old RECORD;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    ) THEN RAISE EXCEPTION 'PAYMENT_METHOD_MANAGER_REQUIRED'; END IF;
    IF btrim(COALESCE(p_payment_method_code,'')) = ''
       OR btrim(COALESCE(p_payment_method_name,'')) = '' THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD_IDENTITY';
    END IF;
    IF upper(COALESCE(p_method_type,'')) IN (
        'CUSTOMER_BALANCE','KETUL_OFFSET'
    ) OR upper(COALESCE(p_settlement_route,'')) = 'INTERNAL_LIABILITY' THEN
        RAISE EXCEPTION 'INTERNAL_PAYMENT_METHOD_REQUIRES_MODULE_WORKFLOW';
    END IF;
    IF p_effective_from IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_METHOD_EFFECTIVE_FROM_REQUIRED';
    END IF;
    IF p_effective_to IS NOT NULL AND p_effective_to < p_effective_from THEN
        RAISE EXCEPTION 'INVALID_PAYMENT_METHOD_PERIOD';
    END IF;
    IF COALESCE(p_is_default,FALSE) AND NOT COALESCE(p_is_active,TRUE) THEN
        RAISE EXCEPTION 'DEFAULT_PAYMENT_METHOD_MUST_BE_ACTIVE';
    END IF;
    IF NOT COALESCE(p_available_all_stores,TRUE) THEN
        IF COALESCE(cardinality(p_store_ids),0) = 0 THEN
            RAISE EXCEPTION 'PAYMENT_METHOD_STORE_REQUIRED';
        END IF;
        IF EXISTS (
            SELECT 1 FROM unnest(p_store_ids) s(id)
            LEFT JOIN public.stores st
              ON st.company_id = v_company
             AND st.id = s.id
             AND st.status = 'ACTIVE'
            WHERE st.id IS NULL
        ) THEN RAISE EXCEPTION 'ACTIVE_STORE_NOT_FOUND'; END IF;
    END IF;

    IF COALESCE(p_is_default,FALSE) AND COALESCE(p_is_active,TRUE) THEN
        FOR v_old IN
            SELECT pm.id,to_jsonb(pm) AS before_state
            FROM public.payment_methods pm
            WHERE pm.company_id = v_company
              AND pm.id IS DISTINCT FROM p_payment_method_id
              AND pm.is_default
              AND pm.is_active
            FOR UPDATE
        LOOP
            UPDATE public.payment_methods
            SET is_default = FALSE,updated_by = v_actor
            WHERE company_id = v_company AND id = v_old.id;
            SELECT to_jsonb(pm) INTO v_after
            FROM public.payment_methods pm
            WHERE pm.company_id = v_company AND pm.id = v_old.id;
            INSERT INTO public.payment_method_master_audit(
                company_id,payment_method_id,action,actor_id,
                before_state,after_state
            ) VALUES (
                v_company,v_old.id,'UPDATE',v_actor,
                v_old.before_state,v_after
            );
        END LOOP;
    END IF;

    IF p_payment_method_id IS NULL THEN
        IF p_master_version IS NOT NULL THEN
            RAISE EXCEPTION 'MASTER_VERSION_NOT_ALLOWED_ON_CREATE';
        END IF;
        INSERT INTO public.payment_methods(
            company_id,payment_method_code,payment_method_name,method_type,
            settlement_route,is_default,available_all_stores,proof_mode,
            fee_enabled,fee_bearer,fee_type,fee_percent,fee_fixed_amount,
            clearing_account_function,bank_account_function,effective_from,
            effective_to,is_active,created_by,updated_by
        ) VALUES (
            v_company,upper(btrim(p_payment_method_code)),
            btrim(p_payment_method_name),upper(p_method_type),
            upper(p_settlement_route),COALESCE(p_is_default,FALSE),
            COALESCE(p_available_all_stores,TRUE),upper(p_proof_mode),
            COALESCE(p_fee_enabled,FALSE),
            CASE WHEN COALESCE(p_fee_enabled,FALSE)
                 THEN upper(p_fee_bearer) END,
            CASE WHEN COALESCE(p_fee_enabled,FALSE)
                 THEN upper(p_fee_type) END,
            CASE WHEN COALESCE(p_fee_enabled,FALSE)
                 THEN p_fee_percent END,
            CASE WHEN COALESCE(p_fee_enabled,FALSE)
                 THEN p_fee_fixed_amount END,
            NULLIF(btrim(p_clearing_account_function),''),
            NULLIF(btrim(p_bank_account_function),''),p_effective_from,
            p_effective_to,COALESCE(p_is_active,TRUE),v_actor,v_actor
        ) RETURNING id,master_version INTO v_id,v_version;
    ELSE
        SELECT to_jsonb(pm),pm.master_version INTO v_before,v_version
        FROM public.payment_methods pm
        WHERE pm.company_id = v_company AND pm.id = p_payment_method_id
        FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_METHOD_NOT_FOUND'; END IF;
        IF p_master_version IS NULL OR p_master_version <> v_version THEN
            RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
        END IF;
        UPDATE public.payment_methods SET
            payment_method_code = upper(btrim(p_payment_method_code)),
            payment_method_name = btrim(p_payment_method_name),
            method_type = upper(p_method_type),
            settlement_route = upper(p_settlement_route),
            is_default = COALESCE(p_is_default,FALSE),
            available_all_stores = COALESCE(p_available_all_stores,TRUE),
            proof_mode = upper(p_proof_mode),
            fee_enabled = COALESCE(p_fee_enabled,FALSE),
            fee_bearer = CASE WHEN COALESCE(p_fee_enabled,FALSE)
                              THEN upper(p_fee_bearer) END,
            fee_type = CASE WHEN COALESCE(p_fee_enabled,FALSE)
                            THEN upper(p_fee_type) END,
            fee_percent = CASE WHEN COALESCE(p_fee_enabled,FALSE)
                               THEN p_fee_percent END,
            fee_fixed_amount = CASE WHEN COALESCE(p_fee_enabled,FALSE)
                                    THEN p_fee_fixed_amount END,
            clearing_account_function =
                NULLIF(btrim(p_clearing_account_function),''),
            bank_account_function =
                NULLIF(btrim(p_bank_account_function),''),
            effective_from = p_effective_from,effective_to = p_effective_to,
            is_active = COALESCE(p_is_active,TRUE),updated_by = v_actor
        WHERE company_id = v_company AND id = p_payment_method_id
        RETURNING id,master_version INTO v_id,v_version;
        DELETE FROM public.payment_method_store_assignments
        WHERE company_id = v_company AND payment_method_id = v_id;
    END IF;

    IF NOT COALESCE(p_available_all_stores,TRUE) THEN
        INSERT INTO public.payment_method_store_assignments(
            company_id,payment_method_id,store_id,created_by
        )
        SELECT v_company,v_id,s.id,v_actor
        FROM unnest(p_store_ids) s(id);
    END IF;

    SELECT to_jsonb(pm) INTO v_after FROM public.payment_methods pm
    WHERE pm.company_id = v_company AND pm.id = v_id;
    INSERT INTO public.payment_method_master_audit(
        company_id,payment_method_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_id,
        CASE WHEN p_payment_method_id IS NULL THEN 'CREATE' ELSE 'UPDATE' END,
        v_actor,v_before,v_after
    );
    RETURN jsonb_build_object(
        'paymentMethodId',v_id,'masterVersion',v_version
    );
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'DUPLICATE_OR_DEFAULT_PAYMENT_METHOD_CONFLICT';
END;
$$;

ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_method_store_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_method_master_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Company users read Payment Methods"
ON public.payment_methods FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);

CREATE POLICY "Company users read Payment Method Store assignments"
ON public.payment_method_store_assignments FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_company_access(company_id)
);

CREATE POLICY "Payment Method managers read audit"
ON public.payment_method_master_audit FOR SELECT TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
    )
);

REVOKE ALL ON public.payment_methods,
    public.payment_method_store_assignments,
    public.payment_method_master_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.payment_methods,
    public.payment_method_store_assignments,
    public.payment_method_master_audit
TO authenticated;
GRANT ALL ON public.payment_methods,
    public.payment_method_store_assignments,
    public.payment_method_master_audit
TO service_role;

REVOKE ALL ON FUNCTION public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
    TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_payment_method(
    UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,BOOLEAN,UUID[],TEXT,BOOLEAN,
    TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TIMESTAMPTZ,TIMESTAMPTZ,BOOLEAN
) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260722120000',
    'g2_phase14_payment_method_foundation',
    'Canonical tenant-scoped Payment Method master, Store assignment, fee configuration, version/audit, Cash default provisioning, guarded RPC, and nullable Sales Payment snapshots without checkout cutover'
);

NOTIFY pgrst,'reload schema';
COMMIT;
