-- KGS POS G1 phase 4: canonical role vocabulary and active Company context.
-- Requirement: TEN-001, TEN-002
-- Dependency: 20260720150000_g1_phase3_transaction_tenant_consistency.sql
--
-- This migration does not replace the complete RLS matrix and does not change
-- business-document workflows. It creates the auditable server-side context
-- that future mutation policies/RPCs will require.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260720150000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 3 not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260720180000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260720180000';
    END IF;
END
$migration_guard$;

DO $membership_preflight$
DECLARE
    v_violations BIGINT;
BEGIN
    SELECT count(*) INTO v_violations
    FROM (
        SELECT id FROM public.company_memberships
        WHERE role_code NOT IN (
            'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING',
            'STORE_MANAGER','WAREHOUSE_ADMIN','CASHIER'
        ) OR status NOT IN ('ACTIVE','INACTIVE')
           OR (is_default_company AND status <> 'ACTIVE')
        UNION ALL
        SELECT id FROM public.store_memberships
        WHERE role_code NOT IN (
            'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING',
            'STORE_MANAGER','WAREHOUSE_ADMIN','CASHIER'
        ) OR status NOT IN ('ACTIVE','INACTIVE')
        UNION ALL
        SELECT user_id FROM public.company_memberships
        WHERE is_default_company
        GROUP BY user_id HAVING count(*) > 1
    ) violations;

    IF v_violations > 0 THEN
        RAISE EXCEPTION 'G1_PHASE4_MEMBERSHIP_PRECONDITION_FAILED: % violation(s)', v_violations;
    END IF;
END
$membership_preflight$;

ALTER TABLE public.company_memberships
    ADD CONSTRAINT company_memberships_role_code_check
    CHECK (role_code IN (
        'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING',
        'STORE_MANAGER','WAREHOUSE_ADMIN','CASHIER'
    )) NOT VALID;
ALTER TABLE public.company_memberships
    ADD CONSTRAINT company_memberships_status_check
    CHECK (status IN ('ACTIVE','INACTIVE')) NOT VALID;
ALTER TABLE public.company_memberships
    ADD CONSTRAINT company_memberships_default_active_check
    CHECK (NOT is_default_company OR status = 'ACTIVE') NOT VALID;

ALTER TABLE public.store_memberships
    ADD CONSTRAINT store_memberships_role_code_check
    CHECK (role_code IN (
        'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING',
        'STORE_MANAGER','WAREHOUSE_ADMIN','CASHIER'
    )) NOT VALID;
ALTER TABLE public.store_memberships
    ADD CONSTRAINT store_memberships_status_check
    CHECK (status IN ('ACTIVE','INACTIVE')) NOT VALID;

ALTER TABLE public.company_memberships VALIDATE CONSTRAINT company_memberships_role_code_check;
ALTER TABLE public.company_memberships VALIDATE CONSTRAINT company_memberships_status_check;
ALTER TABLE public.company_memberships VALIDATE CONSTRAINT company_memberships_default_active_check;
ALTER TABLE public.store_memberships VALIDATE CONSTRAINT store_memberships_role_code_check;
ALTER TABLE public.store_memberships VALIDATE CONSTRAINT store_memberships_status_check;

CREATE UNIQUE INDEX uq_company_memberships_one_default_per_user
    ON public.company_memberships (user_id)
    WHERE is_default_company;

CREATE TABLE public.user_active_company_contexts (
    user_id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    selection_source TEXT NOT NULL DEFAULT 'BACKOFFICE',
    selected_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT user_active_company_contexts_source_check
        CHECK (selection_source ~ '^[A-Z][A-Z0-9_]{1,31}$')
);

CREATE INDEX idx_user_active_company_contexts_company
    ON public.user_active_company_contexts (company_id, user_id);

CREATE TABLE public.user_active_company_context_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    old_company_id UUID REFERENCES public.companies(id) ON DELETE RESTRICT,
    new_company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    selection_source TEXT NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT user_active_company_context_audit_source_check
        CHECK (selection_source ~ '^[A-Z][A-Z0-9_]{1,31}$')
);

CREATE INDEX idx_user_active_company_context_audit_user_time
    ON public.user_active_company_context_audit (user_id, changed_at DESC);
CREATE INDEX idx_user_active_company_context_audit_company_time
    ON public.user_active_company_context_audit (new_company_id, changed_at DESC);

-- Backfill only unambiguous normal-user defaults. Super Admin and users without
-- an active default must explicitly select a Company through the RPC.
INSERT INTO public.user_active_company_contexts (
    user_id, company_id, selection_source
)
SELECT cm.user_id, cm.company_id, 'MIGRATION_DEFAULT'
FROM public.company_memberships cm
JOIN public.profiles p ON p.id = cm.user_id
WHERE cm.status = 'ACTIVE'
  AND cm.is_default_company
  AND p.role <> 'super_admin'::user_role
ON CONFLICT (user_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.private_active_company_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT c.company_id
    FROM public.user_active_company_contexts c
    WHERE c.user_id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.private_request_company_matches(
    p_company_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p_company_id IS NOT NULL
       AND p_company_id = public.private_active_company_id();
$$;

CREATE OR REPLACE FUNCTION public.set_active_company_context(
    p_company_id UUID,
    p_selection_source TEXT DEFAULT 'BACKOFFICE'
)
RETURNS public.user_active_company_contexts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_source TEXT := upper(trim(COALESCE(p_selection_source, '')));
    v_old_company_id UUID;
    v_result public.user_active_company_contexts;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
    END IF;

    IF v_source !~ '^[A-Z][A-Z0-9_]{1,31}$' THEN
        RAISE EXCEPTION 'INVALID_CONTEXT_SOURCE';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.companies
        WHERE id = p_company_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND';
    END IF;

    IF NOT public.private_user_has_company_access(p_company_id) THEN
        RAISE EXCEPTION 'COMPANY_ACCESS_DENIED';
    END IF;

    -- Serialize repeated selections for the same actor and keep audit order.
    PERFORM 1 FROM public.profiles WHERE id = v_user_id FOR UPDATE;

    SELECT company_id INTO v_old_company_id
    FROM public.user_active_company_contexts
    WHERE user_id = v_user_id;

    IF v_old_company_id IS NOT DISTINCT FROM p_company_id THEN
        SELECT * INTO v_result
        FROM public.user_active_company_contexts
        WHERE user_id = v_user_id;
        RETURN v_result;
    END IF;

    INSERT INTO public.user_active_company_contexts (
        user_id, company_id, selection_source, selected_at, updated_at
    ) VALUES (
        v_user_id, p_company_id, v_source, clock_timestamp(), clock_timestamp()
    )
    ON CONFLICT (user_id) DO UPDATE SET
        company_id = EXCLUDED.company_id,
        selection_source = EXCLUDED.selection_source,
        selected_at = EXCLUDED.selected_at,
        updated_at = EXCLUDED.updated_at
    RETURNING * INTO v_result;

    INSERT INTO public.user_active_company_context_audit (
        user_id, old_company_id, new_company_id, selection_source
    ) VALUES (
        v_user_id, v_old_company_id, p_company_id, v_source
    );

    RETURN v_result;
END;
$$;

ALTER TABLE public.user_active_company_contexts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_active_company_context_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users read own active Company context"
ON public.user_active_company_contexts
FOR SELECT TO authenticated
USING (user_id = auth.uid());

CREATE POLICY "Users read own Company context audit"
ON public.user_active_company_context_audit
FOR SELECT TO authenticated
USING (user_id = auth.uid() OR public.private_is_super_admin(auth.uid()));

REVOKE ALL ON public.user_active_company_contexts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.user_active_company_context_audit FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.user_active_company_contexts TO authenticated;
GRANT SELECT ON public.user_active_company_context_audit TO authenticated;
GRANT ALL ON public.user_active_company_contexts TO service_role;
GRANT ALL ON public.user_active_company_context_audit TO service_role;

REVOKE ALL ON FUNCTION public.private_active_company_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.private_request_company_matches(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_active_company_context(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.private_active_company_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.private_request_company_matches(UUID) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_active_company_context(UUID, TEXT) TO authenticated, service_role;

INSERT INTO private.kgs_schema_migrations (version, migration_name, notes)
VALUES (
    '20260720180000',
    'g1_phase4_active_company_context',
    'TEN-001/TEN-002 canonical membership vocabulary and auditable active Company context'
);

COMMIT;
