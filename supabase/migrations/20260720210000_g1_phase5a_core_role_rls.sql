-- KGS POS G1 phase 5A: canonical role helpers and core/master RLS.
-- Requirement: TEN-001, TEN-002
-- Dependency: 20260720180000_g1_phase4_active_company_context.sql
--
-- Scope is intentionally limited to identity, Company, membership, Store,
-- POS Terminal, and Warehouse. Product/transaction/stock/finance policies are
-- handled by later G1 phase 5 batches.

BEGIN;

DO $migration_guard$
BEGIN
    IF to_regclass('private.kgs_schema_migrations') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM private.kgs_schema_migrations
           WHERE version = '20260720180000'
       ) THEN
        RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G1 phase 4 not recorded';
    END IF;

    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260720210000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260720210000';
    END IF;
END
$migration_guard$;

DO $context_preflight$
DECLARE
    v_violations BIGINT;
BEGIN
    SELECT count(*) INTO v_violations
    FROM public.user_active_company_contexts c
    JOIN public.companies co ON co.id = c.company_id
    JOIN public.profiles p ON p.id = c.user_id
    LEFT JOIN public.company_memberships cm
      ON cm.company_id = c.company_id
     AND cm.user_id = c.user_id
     AND cm.status = 'ACTIVE'
    WHERE co.status <> 'ACTIVE'
       OR (p.role <> 'super_admin'::user_role AND cm.id IS NULL);

    IF v_violations > 0 THEN
        RAISE EXCEPTION 'G1_PHASE5A_CONTEXT_PRECONDITION_FAILED: % violation(s)', v_violations;
    END IF;
END
$context_preflight$;

-- Canonical helpers. Super Admin is represented explicitly in the new helper,
-- while get_user_role_in_company keeps its legacy COMPANY_OWNER mapping.
CREATE OR REPLACE FUNCTION public.private_user_company_role(
    p_user_id UUID,
    p_company_id UUID
)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT CASE
        WHEN public.private_is_super_admin(p_user_id) THEN 'SUPER_ADMIN'
        ELSE (
            SELECT cm.role_code
            FROM public.company_memberships cm
            WHERE cm.company_id = p_company_id
              AND cm.user_id = p_user_id
              AND cm.status = 'ACTIVE'
        )
    END;
$$;

CREATE OR REPLACE FUNCTION public.private_user_has_company_access(
    p_company_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT auth.uid() IS NOT NULL
       AND public.private_user_company_role(auth.uid(), p_company_id) IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.get_user_role_in_company(
    p_company_id UUID
)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT CASE public.private_user_company_role(auth.uid(), p_company_id)
        WHEN 'SUPER_ADMIN' THEN 'COMPANY_OWNER'
        ELSE public.private_user_company_role(auth.uid(), p_company_id)
    END;
$$;

CREATE OR REPLACE FUNCTION public.private_user_has_any_company_role(
    p_company_id UUID,
    p_roles TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT CASE
        WHEN public.private_is_super_admin(auth.uid()) THEN TRUE
        ELSE public.private_user_company_role(auth.uid(), p_company_id) = ANY(p_roles)
    END;
$$;

CREATE OR REPLACE FUNCTION public.private_user_has_any_store_role(
    p_store_id UUID,
    p_roles TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_is_super_admin(auth.uid())
        OR EXISTS (
            SELECT 1
            FROM public.stores s
            JOIN public.company_memberships cm ON cm.company_id = s.company_id
            WHERE s.id = p_store_id
              AND cm.user_id = auth.uid()
              AND cm.status = 'ACTIVE'
              AND cm.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
        )
        OR EXISTS (
            SELECT 1
            FROM public.store_memberships sm
            WHERE sm.store_id = p_store_id
              AND sm.user_id = auth.uid()
              AND sm.status = 'ACTIVE'
              AND sm.role_code = ANY(p_roles)
        );
$$;

CREATE OR REPLACE FUNCTION public.private_user_has_store_access(
    p_store_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_is_super_admin(auth.uid())
        OR EXISTS (
            SELECT 1
            FROM public.stores s
            JOIN public.company_memberships cm ON cm.company_id = s.company_id
            WHERE s.id = p_store_id
              AND cm.user_id = auth.uid()
              AND cm.status = 'ACTIVE'
              AND cm.role_code IN (
                  'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
              )
        )
        OR EXISTS (
            SELECT 1
            FROM public.store_memberships sm
            WHERE sm.store_id = p_store_id
              AND sm.user_id = auth.uid()
              AND sm.status = 'ACTIVE'
        );
$$;

CREATE OR REPLACE FUNCTION public.private_user_has_any_company_or_store_role(
    p_company_id UUID,
    p_roles TEXT[]
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_is_super_admin(auth.uid())
        OR EXISTS (
            SELECT 1
            FROM public.company_memberships cm
            WHERE cm.company_id = p_company_id
              AND cm.user_id = auth.uid()
              AND cm.status = 'ACTIVE'
              AND cm.role_code = ANY(p_roles)
        )
        OR EXISTS (
            SELECT 1
            FROM public.store_memberships sm
            WHERE sm.company_id = p_company_id
              AND sm.user_id = auth.uid()
              AND sm.status = 'ACTIVE'
              AND sm.role_code = ANY(p_roles)
        );
$$;

CREATE OR REPLACE FUNCTION public.private_profile_visible(
    p_profile_id UUID
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT p_profile_id = auth.uid()
        OR public.private_is_super_admin(auth.uid())
        OR EXISTS (
            SELECT 1
            FROM public.company_memberships mine
            JOIN public.company_memberships theirs
              ON theirs.company_id = mine.company_id
             AND theirs.user_id = p_profile_id
             AND theirs.status = 'ACTIVE'
            WHERE mine.user_id = auth.uid()
              AND mine.status = 'ACTIVE'
              AND mine.role_code IN ('COMPANY_OWNER','COMPANY_ADMIN')
        );
$$;

-- Replace all policies only on this migration's narrow table scope.
DO $drop_core_policies$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT tablename, policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = ANY(ARRAY[
              'profiles','companies','company_memberships','stores',
              'store_memberships','pos_terminals','warehouses'
          ])
    LOOP
        EXECUTE format('DROP POLICY %I ON public.%I', r.policyname, r.tablename);
    END LOOP;
END
$drop_core_policies$;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pos_terminals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Profiles readable by self or Company administrators"
ON public.profiles FOR SELECT TO authenticated
USING (public.private_profile_visible(id));

CREATE POLICY "Companies readable by active members"
ON public.companies FOR SELECT TO authenticated
USING (public.private_user_has_company_access(id));

CREATE POLICY "Company memberships readable by authorized users"
ON public.company_memberships FOR SELECT TO authenticated
USING (
    user_id = auth.uid()
    OR public.private_is_super_admin(auth.uid())
    OR public.private_user_has_any_company_role(
        company_id, ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);

CREATE POLICY "Store memberships readable by authorized users"
ON public.store_memberships FOR SELECT TO authenticated
USING (
    user_id = auth.uid()
    OR public.private_is_super_admin(auth.uid())
    OR public.private_user_has_any_company_role(
        company_id, ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);

CREATE POLICY "Stores readable in accessible Companies"
ON public.stores FOR SELECT TO authenticated
USING (public.private_user_has_store_access(id));
CREATE POLICY "Stores insertable by Company administrators"
ON public.stores FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_role(
        company_id, ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Stores updateable by Company administrators"
ON public.stores FOR UPDATE TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_role(
        company_id, ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
)
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_role(
        company_id, ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    )
);

CREATE POLICY "POS terminals readable in accessible Companies"
ON public.pos_terminals FOR SELECT TO authenticated
USING (public.private_user_has_store_access(store_id));
CREATE POLICY "POS terminals insertable by authorized managers"
ON public.pos_terminals FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_store_role(
        store_id, ARRAY['STORE_MANAGER']::TEXT[]
    )
);
CREATE POLICY "POS terminals updateable by authorized managers"
ON public.pos_terminals FOR UPDATE TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_store_role(
        store_id, ARRAY['STORE_MANAGER']::TEXT[]
    )
)
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_store_role(
        store_id, ARRAY['STORE_MANAGER']::TEXT[]
    )
);

CREATE POLICY "Warehouses readable in accessible Companies"
ON public.warehouses FOR SELECT TO authenticated
USING (public.private_user_has_company_access(company_id));
CREATE POLICY "Warehouses insertable by authorized inventory managers"
ON public.warehouses FOR INSERT TO authenticated
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);
CREATE POLICY "Warehouses updateable by authorized inventory managers"
ON public.warehouses FOR UPDATE TO authenticated
USING (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
)
WITH CHECK (
    public.private_request_company_matches(company_id)
    AND public.private_user_has_any_company_or_store_role(
        company_id,
        ARRAY['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN']::TEXT[]
    )
);

-- Exact browser privileges. Identity/membership writes remain server workflow.
REVOKE ALL ON public.profiles, public.companies,
    public.company_memberships, public.store_memberships,
    public.stores, public.pos_terminals, public.warehouses
FROM PUBLIC, anon, authenticated;

GRANT SELECT ON public.profiles, public.companies,
    public.company_memberships, public.store_memberships,
    public.stores, public.pos_terminals, public.warehouses
TO authenticated;
GRANT INSERT, UPDATE ON public.stores, public.pos_terminals, public.warehouses
TO authenticated;

GRANT ALL ON public.profiles, public.companies,
    public.company_memberships, public.store_memberships,
    public.stores, public.pos_terminals, public.warehouses
TO service_role;

DO $helper_grants$
DECLARE
    v_signature TEXT;
BEGIN
    FOREACH v_signature IN ARRAY ARRAY[
        'public.private_user_company_role(uuid,uuid)',
        'public.private_user_has_company_access(uuid)',
        'public.get_user_role_in_company(uuid)',
        'public.private_user_has_any_company_role(uuid,text[])',
        'public.private_user_has_any_store_role(uuid,text[])',
        'public.private_user_has_store_access(uuid)',
        'public.private_user_has_any_company_or_store_role(uuid,text[])',
        'public.private_profile_visible(uuid)'
    ]
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', v_signature);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', v_signature);
    END LOOP;
END
$helper_grants$;

INSERT INTO private.kgs_schema_migrations (version, migration_name, notes)
VALUES (
    '20260720210000',
    'g1_phase5a_core_role_rls',
    'TEN-001/TEN-002 canonical helpers and core identity/Company/Store/POS/Warehouse RLS'
);

COMMIT;
