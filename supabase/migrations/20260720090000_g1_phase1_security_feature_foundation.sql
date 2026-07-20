-- KGS POS G1 phase 1: tenant nullability, feature entitlement, and ACL foundation.
--
-- Requirement: TEN-001, TEN-002, TEN-003
-- Gate: G1 (phase 1 of multiple forward migrations)
-- Live prerequisite: G0 fingerprint captured on 2026-07-20.
--
-- This migration intentionally does NOT:
-- - add the cross-table composite tenant foreign keys (G1 phase 2);
-- - replace the complete role/RLS matrix (G1 phase 2/3);
-- - enable any optional feature;
-- - change checkout, stock, purchase, or finance business behavior.
--
-- Forward-fix / rollback posture:
-- - Optional features remain disabled unless a Super Admin explicitly enables them.
-- - Feature tables can remain present during an operational rollback.
-- - Do not drop audit rows after use. Correct mistakes with another forward mutation.
-- - If a legacy integration genuinely needs a revoked privilege, grant only the exact
--   object/action in a new reviewed migration; never restore broad ALL privileges.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Project-owned migration ledger for SQL Editor deployments
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO service_role;

CREATE TABLE IF NOT EXISTS private.kgs_schema_migrations (
    version TEXT PRIMARY KEY,
    migration_name TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    applied_by TEXT NOT NULL DEFAULT current_user,
    notes TEXT
);

REVOKE ALL ON private.kgs_schema_migrations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON private.kgs_schema_migrations TO service_role;

DO $migration_guard$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM private.kgs_schema_migrations
        WHERE version = '20260720090000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260720090000';
    END IF;
END
$migration_guard$;

-- ---------------------------------------------------------------------------
-- 1. Tenant NOT NULL contract for rows proven clean by G0
-- ---------------------------------------------------------------------------

DO $tenant_preflight$
DECLARE
    r RECORD;
    v_null_rows BIGINT;
BEGIN
    FOR r IN
        SELECT table_name
        FROM (VALUES
            ('product_batches'),
            ('product_uom_conversions'),
            ('sales_fifo_allocations'),
            ('stock_adjustments'),
            ('stock_movements'),
            ('stock_opname_details'),
            ('stock_opnames'),
            ('uoms')
        ) expected(table_name)
    LOOP
        IF to_regclass(format('public.%I', r.table_name)) IS NULL THEN
            RAISE EXCEPTION 'G1_PRECONDITION_FAILED: missing table public.%', r.table_name;
        END IF;

        EXECUTE format(
            'SELECT count(*) FROM public.%I WHERE company_id IS NULL',
            r.table_name
        ) INTO v_null_rows;

        IF v_null_rows > 0 THEN
            RAISE EXCEPTION
                'G1_PRECONDITION_FAILED: public.% has % NULL company_id row(s)',
                r.table_name,
                v_null_rows;
        END IF;
    END LOOP;
END
$tenant_preflight$;

ALTER TABLE public.product_batches
    ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.product_uom_conversions
    ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.sales_fifo_allocations
    ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.stock_adjustments
    ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.stock_movements
    ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.stock_opname_details
    ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.stock_opnames
    ALTER COLUMN company_id SET NOT NULL;
ALTER TABLE public.uoms
    ALTER COLUMN company_id SET NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Platform feature catalog and per-company entitlement
-- ---------------------------------------------------------------------------

CREATE TABLE public.platform_features (
    feature_code TEXT PRIMARY KEY,
    feature_name TEXT NOT NULL,
    module_code TEXT NOT NULL,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT platform_features_code_format_check
        CHECK (feature_code ~ '^[a-z][a-z0-9_]{2,63}$'),
    CONSTRAINT platform_features_module_code_format_check
        CHECK (module_code ~ '^[A-Z][A-Z0-9_]{1,31}$')
);

CREATE TABLE public.company_features (
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE CASCADE,
    feature_code TEXT NOT NULL
        REFERENCES public.platform_features(feature_code),
    is_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (company_id, feature_code),
    CONSTRAINT company_features_config_object_check
        CHECK (jsonb_typeof(config) = 'object')
);

CREATE INDEX idx_company_features_enabled
    ON public.company_features (company_id, feature_code)
    WHERE is_enabled;

CREATE TABLE public.company_feature_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    feature_code TEXT NOT NULL
        REFERENCES public.platform_features(feature_code),
    operation TEXT NOT NULL,
    old_enabled BOOLEAN,
    new_enabled BOOLEAN,
    old_config JSONB,
    new_config JSONB,
    changed_by UUID REFERENCES public.profiles(id),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT company_feature_audit_operation_check
        CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE'))
);

CREATE INDEX idx_company_feature_audit_company_time
    ON public.company_feature_audit (company_id, changed_at DESC);

-- Catalog only. No Company entitlement is enabled by this seed.
INSERT INTO public.platform_features (
    feature_code,
    feature_name,
    module_code,
    description
) VALUES
    ('customer_balance_enabled', 'Customer Balance', 'SALES',
     'Customer overpayment balance workflow; Super Admin entitlement required.'),
    ('ketul_enabled', 'Ketul Operations', 'POS',
     'Optional Ketul intake, stock, vendor sale, and settlement workflow.'),
    ('offline_pos_enabled', 'POS Offline Mode', 'POS',
     'Controlled offline sale and synchronization workflow.'),
    ('tempo_enabled', 'POS Tempo', 'POS',
     'Pro forma, installment, and customer collection workflow.'),
    ('tax_purchase_enabled', 'Purchase Tax', 'PURCHASE',
     'Tax calculation and accounting for Purchase documents.'),
    ('tax_sales_enabled', 'Sales Tax', 'SALES',
     'Tax calculation and accounting for Sales documents.');

-- ---------------------------------------------------------------------------
-- 3. Feature audit and server-side guard functions
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trg_company_features_touch()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    IF auth.uid() IS NOT NULL THEN
        NEW.updated_by := auth.uid();
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_company_features_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.company_feature_audit (
            company_id, feature_code, operation,
            old_enabled, new_enabled, old_config, new_config, changed_by
        ) VALUES (
            NEW.company_id, NEW.feature_code, TG_OP,
            NULL, NEW.is_enabled, NULL, NEW.config, auth.uid()
        );
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO public.company_feature_audit (
            company_id, feature_code, operation,
            old_enabled, new_enabled, old_config, new_config, changed_by
        ) VALUES (
            NEW.company_id, NEW.feature_code, TG_OP,
            OLD.is_enabled, NEW.is_enabled, OLD.config, NEW.config, auth.uid()
        );
        RETURN NEW;
    END IF;

    INSERT INTO public.company_feature_audit (
        company_id, feature_code, operation,
        old_enabled, new_enabled, old_config, new_config, changed_by
    ) VALUES (
        OLD.company_id, OLD.feature_code, TG_OP,
        OLD.is_enabled, NULL, OLD.config, NULL, auth.uid()
    );
    RETURN OLD;
END;
$$;

CREATE TRIGGER company_features_touch_updated_at
BEFORE UPDATE ON public.company_features
FOR EACH ROW
EXECUTE FUNCTION public.trg_company_features_touch();

CREATE TRIGGER company_features_write_audit
AFTER INSERT OR UPDATE OR DELETE ON public.company_features
FOR EACH ROW
EXECUTE FUNCTION public.trg_company_features_audit();

CREATE OR REPLACE FUNCTION public.private_company_feature_enabled(
    p_company_id UUID,
    p_feature_code TEXT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.company_features cf
        JOIN public.platform_features pf
          ON pf.feature_code = cf.feature_code
        WHERE cf.company_id = p_company_id
          AND cf.feature_code = lower(trim(p_feature_code))
          AND cf.is_enabled
          AND pf.is_active
    );
$$;

CREATE OR REPLACE FUNCTION public.set_company_feature(
    p_company_id UUID,
    p_feature_code TEXT,
    p_enabled BOOLEAN,
    p_config JSONB DEFAULT '{}'::jsonb
)
RETURNS public.company_features
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_feature_code TEXT := lower(trim(p_feature_code));
    v_result public.company_features;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;

    IF NOT public.private_is_super_admin(auth.uid()) THEN
        RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.companies WHERE id = p_company_id
    ) THEN
        RAISE EXCEPTION 'COMPANY_NOT_FOUND';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.platform_features
        WHERE feature_code = v_feature_code
          AND is_active
    ) THEN
        RAISE EXCEPTION 'ACTIVE_FEATURE_NOT_FOUND';
    END IF;

    IF p_config IS NULL OR jsonb_typeof(p_config) <> 'object' THEN
        RAISE EXCEPTION 'FEATURE_CONFIG_MUST_BE_OBJECT';
    END IF;

    INSERT INTO public.company_features (
        company_id,
        feature_code,
        is_enabled,
        config,
        updated_by
    ) VALUES (
        p_company_id,
        v_feature_code,
        p_enabled,
        p_config,
        auth.uid()
    )
    ON CONFLICT (company_id, feature_code) DO UPDATE SET
        is_enabled = EXCLUDED.is_enabled,
        config = EXCLUDED.config,
        updated_by = auth.uid()
    RETURNING * INTO v_result;

    RETURN v_result;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. RLS and explicit object privileges
-- ---------------------------------------------------------------------------

ALTER TABLE public.platform_features ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_features ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_feature_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Platform features readable by authenticated users"
ON public.platform_features
FOR SELECT TO authenticated
USING (TRUE);

CREATE POLICY "Platform features mutable by super admin"
ON public.platform_features
FOR ALL TO authenticated
USING (public.private_is_super_admin(auth.uid()))
WITH CHECK (public.private_is_super_admin(auth.uid()));

CREATE POLICY "Company features readable in accessible companies"
ON public.company_features
FOR SELECT TO authenticated
USING (public.private_user_has_company_access(company_id));

CREATE POLICY "Company features mutable by super admin"
ON public.company_features
FOR ALL TO authenticated
USING (public.private_is_super_admin(auth.uid()))
WITH CHECK (public.private_is_super_admin(auth.uid()));

CREATE POLICY "Company feature audit readable by authorized users"
ON public.company_feature_audit
FOR SELECT TO authenticated
USING (
    public.private_is_super_admin(auth.uid())
    OR public.get_user_role_in_company(company_id)
       IN ('COMPANY_OWNER', 'COMPANY_ADMIN')
);

REVOKE ALL ON public.platform_features FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.company_features FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.company_feature_audit FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.platform_features TO authenticated;
GRANT SELECT ON public.company_features TO authenticated;
GRANT SELECT ON public.company_feature_audit TO authenticated;
GRANT ALL ON public.platform_features TO service_role;
GRANT ALL ON public.company_features TO service_role;
GRANT ALL ON public.company_feature_audit TO service_role;

-- RLS helpers need authenticated EXECUTE, but never PUBLIC/anon EXECUTE.
REVOKE ALL ON FUNCTION public.private_company_feature_enabled(UUID, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.private_company_feature_enabled(UUID, TEXT)
    TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.set_company_feature(UUID, TEXT, BOOLEAN, JSONB)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_company_feature(UUID, TEXT, BOOLEAN, JSONB)
    TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.trg_company_features_touch()
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.trg_company_features_audit()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.trg_company_features_touch() TO service_role;
GRANT EXECUTE ON FUNCTION public.trg_company_features_audit() TO service_role;

-- Existing helper functions are used by authenticated RLS policies.
REVOKE EXECUTE ON FUNCTION public.private_is_super_admin(UUID)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.private_user_has_company_access(UUID)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.private_user_has_store_access(UUID)
    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.get_user_role_in_company(UUID)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.private_is_super_admin(UUID)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.private_user_has_company_access(UUID)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.private_user_has_store_access(UUID)
    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_role_in_company(UUID)
    TO authenticated, service_role;

-- Trigger functions do not need API execute privileges.
REVOKE EXECUTE ON FUNCTION public.handle_new_user()
    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_cash_advances_to_financial_events()
    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_bank_deposits_to_financial_events()
    FROM PUBLIC, anon, authenticated;

-- Legacy worker/transfer are not approved authenticated RPC surfaces.
ALTER FUNCTION public.process_financial_events_queue()
    SET search_path = public, pg_temp;
ALTER FUNCTION public.transfer_product_stock(UUID, UUID, UUID, NUMERIC)
    SET search_path = public, pg_temp;
REVOKE EXECUTE ON FUNCTION public.process_financial_events_queue()
    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.transfer_product_stock(UUID, UUID, UUID, NUMERIC)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_financial_events_queue()
    TO service_role;
GRANT EXECUTE ON FUNCTION public.transfer_product_stock(UUID, UUID, UUID, NUMERIC)
    TO service_role;

-- RLS never protects TRUNCATE. These table privileges are not needed by the
-- browser/API role and were proven broadly granted by the G0 fingerprint.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE TRUNCATE, REFERENCES, TRIGGER
    ON ALL TABLES IN SCHEMA public FROM authenticated;

-- Harden defaults for future objects created by the canonical migration owner.
-- Every future migration must explicitly grant the minimum authenticated access.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    REVOKE ALL ON SEQUENCES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT ALL ON SEQUENCES TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Record successful completion
-- ---------------------------------------------------------------------------

INSERT INTO private.kgs_schema_migrations (
    version,
    migration_name,
    notes
) VALUES (
    '20260720090000',
    'g1_phase1_security_feature_foundation',
    'TEN-001/TEN-002/TEN-003 phase 1; G0 fingerprint 2026-07-20'
);

COMMIT;
