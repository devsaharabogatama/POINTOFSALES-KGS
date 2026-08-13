-- PRD-1: explicit per-Company user access lifecycle before authenticated UAT.
-- Role/Store edits and access revocation are tenant-scoped, audited, and atomic.

BEGIN;

DO $migration_guard$
BEGIN
    IF (SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20260813130000')<>1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: ACP-6G dependency missing';
    END IF;
    IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
              WHERE version='20260813140000') THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: PRD Company access lifecycle already applied';
    END IF;
    IF to_regprocedure(
        'public.save_user_company_access(uuid,uuid,text,uuid)'
       ) IS NOT NULL
       OR to_regprocedure(
        'public.deactivate_user_company_access(uuid,uuid)'
       ) IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Company access lifecycle routine collision';
    END IF;
END
$migration_guard$;

ALTER TABLE public.user_company_assignment_audit
    DROP CONSTRAINT user_company_assignment_audit_action_check;
ALTER TABLE public.user_company_assignment_audit
    ADD CONSTRAINT user_company_assignment_audit_action_check CHECK(
        action IN(
            'ASSIGN','REACTIVATE','UPDATE_ASSIGNMENT','DEACTIVATE','EXACT_RETRY'
        )
    );

CREATE FUNCTION private.prd_can_manage_company_access(
    p_actor UUID,p_company_id UUID,p_target_user_id UUID
) RETURNS BOOLEAN
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE v_actor_role TEXT;v_target_role TEXT;
BEGIN
    IF p_actor IS NULL OR p_actor=p_target_user_id THEN RETURN FALSE; END IF;
    IF public.private_is_super_admin(p_actor) THEN RETURN TRUE; END IF;
    IF public.private_active_company_id() IS DISTINCT FROM p_company_id THEN
        RETURN FALSE;
    END IF;
    SELECT role_code INTO v_actor_role FROM public.company_memberships
    WHERE company_id=p_company_id AND user_id=p_actor AND status='ACTIVE';
    SELECT role_code INTO v_target_role FROM public.company_memberships
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND status='ACTIVE';
    RETURN CASE
      WHEN v_actor_role='COMPANY_OWNER' THEN
        v_target_role IS NOT NULL AND v_target_role<>'COMPANY_OWNER'
      WHEN v_actor_role='COMPANY_ADMIN' THEN
        v_target_role IS NOT NULL
        AND v_target_role NOT IN('COMPANY_OWNER','COMPANY_ADMIN')
      ELSE FALSE END;
END;
$$;

CREATE FUNCTION public.save_user_company_access(
    p_company_id UUID,p_target_user_id UUID,p_role_code TEXT,
    p_store_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_role TEXT:=upper(btrim(COALESCE(p_role_code,'')));
    v_actor_role TEXT;
    v_membership public.company_memberships%ROWTYPE;
    v_store public.store_memberships%ROWTYPE;
    v_before JSONB;v_after JSONB;v_action TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF p_company_id IS NULL OR p_target_user_id IS NULL THEN
        RAISE EXCEPTION 'COMPANY_ACCESS_INPUT_INVALID';
    END IF;
    IF v_role NOT IN(
        'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING',
        'STORE_MANAGER','WAREHOUSE_ADMIN','CASHIER'
    ) THEN RAISE EXCEPTION 'ROLE_NOT_ALLOWED'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.companies company
                  WHERE company.id=p_company_id AND company.status='ACTIVE') THEN
        RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND';
    END IF;
    IF NOT EXISTS(SELECT 1 FROM public.profiles profile
                  WHERE profile.id=p_target_user_id) THEN
        RAISE EXCEPTION 'TARGET_USER_NOT_FOUND';
    END IF;
    IF NOT private.prd_can_manage_company_access(
        v_actor,p_company_id,p_target_user_id
    ) THEN RAISE EXCEPTION 'PERMISSION_TARGET_ACCESS_DENIED'; END IF;

    IF NOT public.private_is_super_admin(v_actor) THEN
        SELECT role_code INTO v_actor_role FROM public.company_memberships
        WHERE company_id=p_company_id AND user_id=v_actor AND status='ACTIVE';
        IF v_role='COMPANY_OWNER'
           OR (v_actor_role='COMPANY_ADMIN' AND v_role='COMPANY_ADMIN') THEN
            RAISE EXCEPTION 'ROLE_HIERARCHY_DENIED';
        END IF;
    END IF;
    IF v_role='CASHIER' AND p_store_id IS NULL THEN
        RAISE EXCEPTION 'CASHIER_STORE_ASSIGNMENT_REQUIRED';
    END IF;
    IF p_store_id IS NOT NULL AND NOT EXISTS(
        SELECT 1 FROM public.stores store
        WHERE store.id=p_store_id AND store.company_id=p_company_id
          AND store.status='ACTIVE'
    ) THEN RAISE EXCEPTION 'STORE_NOT_IN_COMPANY'; END IF;

    SELECT * INTO v_membership FROM public.company_memberships
    WHERE company_id=p_company_id AND user_id=p_target_user_id FOR UPDATE;
    IF v_membership.id IS NOT NULL
       AND v_membership.status='ACTIVE'
       AND v_membership.role_code='COMPANY_OWNER'
       AND v_role<>'COMPANY_OWNER'
       AND (SELECT count(*) FROM public.company_memberships owner_membership
            WHERE owner_membership.company_id=p_company_id
              AND owner_membership.status='ACTIVE'
              AND owner_membership.role_code='COMPANY_OWNER')<=1 THEN
        RAISE EXCEPTION 'LAST_COMPANY_OWNER_ACCESS_PROTECTED';
    END IF;
    SELECT * INTO v_store FROM public.store_memberships
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND status='ACTIVE' ORDER BY created_at,id LIMIT 1 FOR UPDATE;

    v_before:=CASE WHEN v_membership.id IS NULL THEN NULL ELSE jsonb_build_object(
        'companyRole',v_membership.role_code,'companyStatus',v_membership.status,
        'isDefaultCompany',v_membership.is_default_company,
        'storeId',v_store.store_id,'storeRole',v_store.role_code,
        'storeStatus',v_store.status) END;

    IF v_membership.id IS NOT NULL AND v_membership.status='ACTIVE'
       AND v_membership.role_code=v_role
       AND ((p_store_id IS NULL AND v_store.id IS NULL)
         OR (p_store_id IS NOT NULL AND v_store.store_id=p_store_id
             AND v_store.role_code=v_role)) THEN
        RETURN jsonb_build_object(
          'success',TRUE,'action','EXACT_RETRY','companyId',p_company_id,
          'roleCode',v_role,'storeId',p_store_id);
    END IF;

    INSERT INTO public.company_memberships(
        company_id,user_id,role_code,status,is_default_company
    ) VALUES(p_company_id,p_target_user_id,v_role,'ACTIVE',FALSE)
    ON CONFLICT(company_id,user_id) DO UPDATE SET
        role_code=EXCLUDED.role_code,status='ACTIVE';

    UPDATE public.store_memberships SET status='INACTIVE'
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND status='ACTIVE' AND (p_store_id IS NULL OR store_id<>p_store_id);
    IF p_store_id IS NOT NULL THEN
        INSERT INTO public.store_memberships(
            company_id,store_id,user_id,role_code,status
        ) VALUES(p_company_id,p_store_id,p_target_user_id,v_role,'ACTIVE')
        ON CONFLICT(company_id,store_id,user_id) DO UPDATE SET
            role_code=EXCLUDED.role_code,status='ACTIVE';
    END IF;

    SELECT * INTO v_membership FROM public.company_memberships
    WHERE company_id=p_company_id AND user_id=p_target_user_id;
    SELECT * INTO v_store FROM public.store_memberships
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND status='ACTIVE' ORDER BY created_at,id LIMIT 1;
    v_after:=jsonb_build_object(
        'companyRole',v_membership.role_code,'companyStatus',v_membership.status,
        'isDefaultCompany',v_membership.is_default_company,
        'storeId',v_store.store_id,'storeRole',v_store.role_code,
        'storeStatus',v_store.status);
    v_action:=CASE
      WHEN v_before IS NULL THEN 'ASSIGN'
      WHEN v_before->>'companyStatus'='INACTIVE' THEN 'REACTIVATE'
      ELSE 'UPDATE_ASSIGNMENT' END;
    INSERT INTO public.user_company_assignment_audit(
        company_id,target_user_id,actor_id,action,before_state,after_state
    ) VALUES(p_company_id,p_target_user_id,v_actor,v_action,v_before,v_after);
    RETURN jsonb_build_object(
      'success',TRUE,'action',v_action,'companyId',p_company_id,
      'roleCode',v_role,'storeId',p_store_id);
END;
$$;

CREATE FUNCTION public.deactivate_user_company_access(
    p_company_id UUID,p_target_user_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_membership public.company_memberships%ROWTYPE;
    v_store_ids JSONB;v_before JSONB;v_replacement_company UUID;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF p_company_id IS NULL OR p_target_user_id IS NULL THEN
        RAISE EXCEPTION 'COMPANY_ACCESS_INPUT_INVALID';
    END IF;
    IF NOT private.prd_can_manage_company_access(
        v_actor,p_company_id,p_target_user_id
    ) THEN RAISE EXCEPTION 'PERMISSION_TARGET_ACCESS_DENIED'; END IF;
    SELECT * INTO v_membership FROM public.company_memberships
    WHERE company_id=p_company_id AND user_id=p_target_user_id FOR UPDATE;
    IF v_membership.id IS NULL OR v_membership.status<>'ACTIVE' THEN
        RETURN jsonb_build_object(
          'success',TRUE,'action','EXACT_RETRY','companyId',p_company_id);
    END IF;
    IF v_membership.role_code='COMPANY_OWNER'
       AND (SELECT count(*) FROM public.company_memberships owner_membership
            WHERE owner_membership.company_id=p_company_id
              AND owner_membership.status='ACTIVE'
              AND owner_membership.role_code='COMPANY_OWNER')<=1 THEN
        RAISE EXCEPTION 'LAST_COMPANY_OWNER_ACCESS_PROTECTED';
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'storeId',membership.store_id,'roleCode',membership.role_code
    ) ORDER BY membership.created_at),'[]'::JSONB) INTO v_store_ids
    FROM public.store_memberships membership
    WHERE membership.company_id=p_company_id
      AND membership.user_id=p_target_user_id AND membership.status='ACTIVE';
    v_before:=jsonb_build_object(
      'companyRole',v_membership.role_code,'companyStatus',v_membership.status,
      'isDefaultCompany',v_membership.is_default_company,'stores',v_store_ids);

    UPDATE public.store_memberships SET status='INACTIVE'
    WHERE company_id=p_company_id AND user_id=p_target_user_id
      AND status='ACTIVE';
    UPDATE public.company_memberships
    SET status='INACTIVE',is_default_company=FALSE
    WHERE id=v_membership.id;
    INSERT INTO public.user_company_permission_audit(
      company_id,target_user_id,permission_key,actor_id,action,
      before_state,after_state
    )
    SELECT permission_override.company_id,permission_override.user_id,
      permission_override.permission_key,
      v_actor,'RESET_OVERRIDE',
      jsonb_build_object(
        'restrictionPreset',permission_override.restriction_preset,
        'masterVersion',permission_override.master_version),
      jsonb_build_object(
        'restrictionPreset','IKUTI_ROLE','reason','COMPANY_ACCESS_DEACTIVATED')
    FROM public.user_company_permission_overrides permission_override
    WHERE permission_override.company_id=p_company_id
      AND permission_override.user_id=p_target_user_id;
    DELETE FROM public.user_company_permission_overrides permission_override
    WHERE permission_override.company_id=p_company_id
      AND permission_override.user_id=p_target_user_id;

    SELECT company_id INTO v_replacement_company
    FROM public.company_memberships replacement
    WHERE replacement.user_id=p_target_user_id AND replacement.status='ACTIVE'
    ORDER BY replacement.is_default_company DESC,replacement.created_at,
             replacement.company_id LIMIT 1;
    IF v_membership.is_default_company AND v_replacement_company IS NOT NULL THEN
        UPDATE public.company_memberships SET is_default_company=TRUE
        WHERE company_id=v_replacement_company AND user_id=p_target_user_id;
    END IF;
    IF EXISTS(SELECT 1 FROM public.user_active_company_contexts context
              WHERE context.user_id=p_target_user_id
                AND context.company_id=p_company_id) THEN
        IF v_replacement_company IS NULL THEN
            DELETE FROM public.user_active_company_contexts
            WHERE user_id=p_target_user_id;
        ELSE
            UPDATE public.user_active_company_contexts SET
              company_id=v_replacement_company,
              selection_source='ACCESS_REVOKED',
              selected_at=clock_timestamp(),updated_at=clock_timestamp()
            WHERE user_id=p_target_user_id;
            INSERT INTO public.user_active_company_context_audit(
              user_id,old_company_id,new_company_id,selection_source
            ) VALUES(
              p_target_user_id,p_company_id,v_replacement_company,'ACCESS_REVOKED'
            );
        END IF;
    END IF;
    INSERT INTO public.user_company_assignment_audit(
      company_id,target_user_id,actor_id,action,before_state,after_state
    ) VALUES(
      p_company_id,p_target_user_id,v_actor,'DEACTIVATE',v_before,
      jsonb_build_object(
        'companyRole',v_membership.role_code,'companyStatus','INACTIVE',
        'isDefaultCompany',FALSE,'stores','[]'::JSONB,
        'replacementCompanyId',v_replacement_company)
    );
    RETURN jsonb_build_object(
      'success',TRUE,'action','DEACTIVATE','companyId',p_company_id,
      'replacementCompanyId',v_replacement_company);
END;
$$;

-- Preserve the existing public signature while routing every assignment and
-- update through the canonical lifecycle guard.
CREATE OR REPLACE FUNCTION public.assign_existing_user_to_company(
    p_company_id UUID,p_target_user_id UUID,p_role_code TEXT,
    p_store_id UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp
AS $$
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_is_super_admin(auth.uid()) THEN
        RAISE EXCEPTION 'SUPER_ADMIN_REQUIRED';
    END IF;
    RETURN public.save_user_company_access(
      p_company_id,p_target_user_id,p_role_code,p_store_id);
END;
$$;

REVOKE ALL ON FUNCTION private.prd_can_manage_company_access(UUID,UUID,UUID),
  public.save_user_company_access(UUID,UUID,TEXT,UUID),
  public.deactivate_user_company_access(UUID,UUID)
FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION private.prd_can_manage_company_access(UUID,UUID,UUID)
FROM authenticated;
GRANT EXECUTE ON FUNCTION private.prd_can_manage_company_access(UUID,UUID,UUID)
TO service_role;
GRANT EXECUTE ON FUNCTION public.save_user_company_access(UUID,UUID,TEXT,UUID),
  public.deactivate_user_company_access(UUID,UUID),
  public.assign_existing_user_to_company(UUID,UUID,TEXT,UUID)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
  '20260813140000','prd_company_access_lifecycle',
  'Explicit tenant-selected role and Store editing, guarded audited Company access deactivation, last-owner protection, override cleanup, and active/default context repair'
);

NOTIFY pgrst,'reload schema';
COMMIT;
