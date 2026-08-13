-- PRD-1 phase 3: guarded existing-user assignment to another Company.
-- UUID remains backend identity; browser never receives a cross-tenant user list.

BEGIN;

DO $migration_guard$
BEGIN
    IF (
        SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20260811150000'
    )<>1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: SLD-R4 dependency missing';
    END IF;
    IF EXISTS(
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260812100000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: PRD phase 3 already applied';
    END IF;
    IF to_regclass('public.user_company_assignment_audit') IS NOT NULL
       OR to_regprocedure(
            'public.assign_existing_user_to_company(uuid,uuid,text,uuid)'
          ) IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: PRD phase 3 object collision';
    END IF;
END
$migration_guard$;

CREATE TABLE public.user_company_assignment_audit(
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    target_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    action TEXT NOT NULL,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT user_company_assignment_audit_action_check
        CHECK(action IN ('ASSIGN','UPDATE_ASSIGNMENT','EXACT_RETRY')),
    CONSTRAINT user_company_assignment_audit_state_check CHECK(
        (before_state IS NULL OR jsonb_typeof(before_state)='object')
        AND jsonb_typeof(after_state)='object'
    )
);

CREATE INDEX idx_user_company_assignment_audit_company_created
    ON public.user_company_assignment_audit(company_id,created_at DESC);

ALTER TABLE public.user_company_assignment_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_company_assignment_audit_super_admin_read
ON public.user_company_assignment_audit FOR SELECT TO authenticated
USING(public.private_is_super_admin(auth.uid()));

CREATE FUNCTION private.trg_prd_guard_assignment_audit_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'USER_COMPANY_ASSIGNMENT_AUDIT_IMMUTABLE';
END;
$$;

CREATE TRIGGER trg_prd_guard_assignment_audit_history
BEFORE UPDATE OR DELETE ON public.user_company_assignment_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_prd_guard_assignment_audit_history();

CREATE FUNCTION public.assign_existing_user_to_company(
    p_company_id UUID,
    p_target_user_id UUID,
    p_role_code TEXT,
    p_store_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_role TEXT:=upper(btrim(COALESCE(p_role_code,'')));
    v_company_membership public.company_memberships%ROWTYPE;
    v_store_membership public.store_memberships%ROWTYPE;
    v_before JSONB;
    v_after JSONB;
    v_action TEXT;
    v_exact BOOLEAN:=FALSE;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_is_super_admin(v_actor) THEN
        RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED';
    END IF;
    IF p_target_user_id IS NULL OR NOT EXISTS(
        SELECT 1 FROM public.profiles profile
        JOIN auth.users auth_user ON auth_user.id=profile.id
        WHERE profile.id=p_target_user_id
    ) THEN RAISE EXCEPTION 'TARGET_USER_NOT_FOUND'; END IF;
    IF NOT EXISTS(
        SELECT 1 FROM public.companies company
        WHERE company.id=p_company_id AND company.status='ACTIVE'
    ) THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
    IF v_role NOT IN(
        'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING',
        'STORE_MANAGER','WAREHOUSE_ADMIN','CASHIER'
    ) THEN RAISE EXCEPTION 'ROLE_NOT_ALLOWED'; END IF;
    IF v_role='CASHIER' AND p_store_id IS NULL THEN
        RAISE EXCEPTION 'CASHIER_STORE_ASSIGNMENT_REQUIRED';
    END IF;
    IF p_store_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM public.stores store
        WHERE store.company_id=p_company_id AND store.id=p_store_id
          AND store.status='ACTIVE'
    ) THEN RAISE EXCEPTION 'STORE_NOT_IN_COMPANY'; END IF;

    SELECT membership.* INTO v_company_membership
    FROM public.company_memberships membership
    WHERE membership.company_id=p_company_id
      AND membership.user_id=p_target_user_id
    FOR UPDATE;

    SELECT membership.* INTO v_store_membership
    FROM public.store_memberships membership
    WHERE membership.company_id=p_company_id
      AND membership.user_id=p_target_user_id
      AND membership.status='ACTIVE'
    ORDER BY membership.created_at,membership.id
    LIMIT 1 FOR UPDATE;

    v_before:=jsonb_build_object(
        'companyRole',v_company_membership.role_code,
        'companyStatus',v_company_membership.status,
        'storeId',v_store_membership.store_id,
        'storeRole',v_store_membership.role_code,
        'storeStatus',v_store_membership.status
    );

    v_exact:=v_company_membership.id IS NOT NULL
        AND v_company_membership.status='ACTIVE'
        AND v_company_membership.role_code=v_role
        AND (
            (p_store_id IS NULL AND v_store_membership.id IS NULL)
            OR (
                p_store_id IS NOT NULL
                AND v_store_membership.store_id=p_store_id
                AND v_store_membership.role_code=v_role
                AND v_store_membership.status='ACTIVE'
            )
        );

    IF NOT v_exact THEN
        INSERT INTO public.company_memberships(
            company_id,user_id,role_code,status,is_default_company
        ) VALUES(p_company_id,p_target_user_id,v_role,'ACTIVE',FALSE)
        ON CONFLICT(company_id,user_id) DO UPDATE SET
            role_code=EXCLUDED.role_code,
            status='ACTIVE';

        UPDATE public.store_memberships
        SET status='INACTIVE'
        WHERE company_id=p_company_id AND user_id=p_target_user_id
          AND status='ACTIVE'
          AND (p_store_id IS NULL OR store_id<>p_store_id);

        IF p_store_id IS NOT NULL THEN
            INSERT INTO public.store_memberships(
                company_id,store_id,user_id,role_code,status
            ) VALUES(p_company_id,p_store_id,p_target_user_id,v_role,'ACTIVE')
            ON CONFLICT(company_id,store_id,user_id) DO UPDATE SET
                role_code=EXCLUDED.role_code,
                status='ACTIVE';
        END IF;
    END IF;

    SELECT membership.* INTO v_company_membership
    FROM public.company_memberships membership
    WHERE membership.company_id=p_company_id
      AND membership.user_id=p_target_user_id;
    SELECT membership.* INTO v_store_membership
    FROM public.store_memberships membership
    WHERE membership.company_id=p_company_id
      AND membership.user_id=p_target_user_id
      AND membership.status='ACTIVE'
    ORDER BY membership.created_at,membership.id LIMIT 1;

    v_after:=jsonb_build_object(
        'companyRole',v_company_membership.role_code,
        'companyStatus',v_company_membership.status,
        'storeId',v_store_membership.store_id,
        'storeRole',v_store_membership.role_code,
        'storeStatus',v_store_membership.status
    );
    v_action:=CASE
        WHEN v_exact THEN 'EXACT_RETRY'
        WHEN v_before->>'companyRole' IS NULL THEN 'ASSIGN'
        ELSE 'UPDATE_ASSIGNMENT'
    END;

    INSERT INTO public.user_company_assignment_audit(
        company_id,target_user_id,actor_id,action,before_state,after_state
    ) VALUES(
        p_company_id,p_target_user_id,v_actor,v_action,
        CASE WHEN v_action='ASSIGN' THEN NULL ELSE v_before END,v_after
    );

    RETURN jsonb_build_object(
        'success',TRUE,'action',v_action,'companyId',p_company_id,
        'roleCode',v_role,'storeAssigned',p_store_id IS NOT NULL
    );
END;
$$;

REVOKE ALL ON TABLE public.user_company_assignment_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.user_company_assignment_audit TO authenticated;

REVOKE ALL ON FUNCTION public.assign_existing_user_to_company(
    UUID,UUID,TEXT,UUID
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.assign_existing_user_to_company(
    UUID,UUID,TEXT,UUID
) TO authenticated,service_role;

REVOKE ALL ON FUNCTION private.trg_prd_guard_assignment_audit_history()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_prd_guard_assignment_audit_history()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260812100000','prd_phase3_existing_user_company_assignment',
    'Super-Admin-only exact existing-user assignment to an active Company with optional tenant-valid Store role, immutable audit, exact retry, and no browser cross-tenant directory'
);

COMMIT;
